using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Devices.Radios;
using Windows.Foundation;
using Windows.Security.Cryptography;

if (args is ["--self-test"]) return Probe.SelfTest();
var rfcomm = args is ["--rfcomm", ..];
if (ProbeOptions.Parse(rfcomm ? args[1..] : args) is not { } options)
{
    Console.Error.WriteLine("Usage: MyKvmBleProbe [--rfcomm | --rate 60] [--trace PATH] or MyKvmBleProbe --self-test");
    return 1;
}
return await Probe.RunAsync(options, rfcomm);

enum Kind : byte { Start = 1, Begin, Motion, Probe, Ack, End, Result }

readonly record struct Frame(Kind Kind, ushort Rate = 0, uint Sequence = 0, int X = 0, int Y = 0)
{
    public byte[] Encode()
    {
        var bytes = new byte[16];
        bytes[0] = 1;
        bytes[1] = (byte)Kind;
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(2), Rate);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), Sequence);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(8), X);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(12), Y);
        return bytes;
    }

    public static Frame Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != 16 || bytes[0] != 1 || bytes[1] is < (byte)Kind.Start or > (byte)Kind.Result)
            throw new InvalidDataException("Invalid BLE probe frame.");
        return new Frame((Kind)bytes[1], BinaryPrimitives.ReadUInt16LittleEndian(bytes[2..]),
            BinaryPrimitives.ReadUInt32LittleEndian(bytes[4..]), BinaryPrimitives.ReadInt32LittleEndian(bytes[8..]),
            BinaryPrimitives.ReadInt32LittleEndian(bytes[12..]));
    }
}

sealed record ProbeOptions(ushort Rate, string? TracePath)
{
    internal ushort[] Rates => Rate == 60 ? [60] : [60, 125];
    internal Frame Start => new(Kind.Start, Rate);

    internal static ProbeOptions? Parse(string[] arguments)
    {
        ushort rate = 0;
        string? trace = null;
        for (int i = 0; i < arguments.Length; i += 2)
        {
            if (i + 1 >= arguments.Length) return null;
            var value = arguments[i + 1];
            switch (arguments[i])
            {
                case "--rate" when rate == 0 && value == "60":
                    rate = 60;
                    break;
                case "--trace" when trace is null && value.Length > 0 && !value.StartsWith("--", StringComparison.Ordinal):
                    trace = value;
                    break;
                default:
                    return null;
            }
        }
        return new ProbeOptions(rate, trace);
    }
}

readonly record struct Timing(uint Sequence, double ElapsedMs, double? IntervalMs)
{
    internal string CsvRow(ushort rate)
    {
        var interval = IntervalMs?.ToString("F3", CultureInfo.InvariantCulture) ?? "";
        return FormattableString.Invariant($"{rate},{Sequence},{ElapsedMs:F3},{interval}\n");
    }
}

sealed class Cadence
{
    private long? first, previous;
    internal List<Timing> Samples { get; } = [];

    internal void Record(uint sequence, long timestamp)
    {
        first ??= timestamp;
        var elapsed = Stopwatch.GetElapsedTime(first.Value, timestamp).TotalMilliseconds;
        var interval = previous is long last ? Stopwatch.GetElapsedTime(last, timestamp).TotalMilliseconds : (double?)null;
        Samples.Add(new Timing(sequence, elapsed, interval));
        previous = timestamp;
    }
}

sealed class RfcommEndpoint(uint channel) : EndPoint
{
    // The Windows SDK packs SOCKADDR_BTH to one byte. Only the family and channel are needed to bind.
    internal const AddressFamily Family = (AddressFamily)32;
    internal const ProtocolType Protocol = (ProtocolType)3;
    private const int ChannelOffset = 26;
    private const int Size = 30;
    internal uint Channel { get; } = channel;
    public override AddressFamily AddressFamily => Family;

    public override SocketAddress Serialize()
    {
        var address = new SocketAddress(Family, Size);
        BinaryPrimitives.WriteUInt32LittleEndian(address.Buffer.Span[ChannelOffset..], Channel);
        return address;
    }

    public override EndPoint Create(SocketAddress address)
    {
        if (address.Family != Family || address.Size < Size)
            throw new ArgumentException("Invalid SOCKADDR_BTH endpoint.", nameof(address));
        return new RfcommEndpoint(BinaryPrimitives.ReadUInt32LittleEndian(address.Buffer.Span[ChannelOffset..]));
    }
}

static class Probe
{
    private static readonly Guid ServiceId = new("E836E781-4D37-4C08-9084-6134A78AB001");
    private static readonly Guid NotifyId = new("E836E781-4D37-4C08-9084-6134A78AB002");
    private static readonly Guid WriteId = new("E836E781-4D37-4C08-9084-6134A78AB003");
    private const int PhaseSeconds = 60;

    internal static async Task<int> RunAsync(ProbeOptions options, bool rfcomm)
    {
        using var stop = new CancellationTokenSource();
        ConsoleCancelEventHandler cancel = (_, args) => { args.Cancel = true; stop.Cancel(); };
        Console.CancelKeyPress += cancel;
        try
        {
            if (rfcomm) await MeasureRfcommAsync(options.TracePath, stop.Token);
            else await MeasureAsync(options, stop.Token);
            return 0;
        }
        catch (UnauthorizedAccessException error)
        {
            Console.Error.WriteLine($"BLOCKED: Windows Bluetooth access was denied. {error.Message}");
            return 1;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Windows probe cancelled or timed out.");
            return 1;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 1;
        }
        finally
        {
            Console.CancelKeyPress -= cancel;
        }
    }

    private static async Task MeasureRfcommAsync(string? tracePath, CancellationToken stop)
    {
        using var setup = CancellationTokenSource.CreateLinkedTokenSource(stop);
        setup.CancelAfter(TimeSpan.FromSeconds(10));
        var adapter = await BluetoothAdapter.GetDefaultAsync().AsTask(setup.Token);
        if (adapter is null || !adapter.IsClassicSupported)
            throw new InvalidOperationException("BLOCKED: Windows has no Bluetooth Classic adapter.");
        var radio = await adapter.GetRadioAsync().AsTask(setup.Token);
        if (radio is null || radio.State != RadioState.On)
            throw new InvalidOperationException($"BLOCKED: Windows Bluetooth radio state is {radio?.State.ToString() ?? "unavailable"}.");
        if (adapter.BluetoothAddress == 0)
            throw new InvalidOperationException("BLOCKED: Windows could not read its Bluetooth Classic address.");

        using var listener = new Socket(RfcommEndpoint.Family, SocketType.Stream, RfcommEndpoint.Protocol);
        listener.Bind(new RfcommEndpoint(uint.MaxValue)); // BT_PORT_ANY
        listener.Listen(1);
        if (listener.LocalEndPoint is not RfcommEndpoint { Channel: >= 1 and <= 30 } endpoint)
            throw new InvalidOperationException("Windows could not allocate an RFCOMM channel.");
        Console.WriteLine($"RFCOMM ready. Windows Bluetooth address {adapter.BluetoothAddress:X12}, channel {endpoint.Channel}. Waiting up to 5 minutes.");
        var started = Stopwatch.GetTimestamp();
        using var connection = await Task.Run(listener.Accept).WaitAsync(TimeSpan.FromMinutes(5), stop);
        using var stream = new NetworkStream(connection);
        Console.WriteLine($"RFCOMM connected after {Stopwatch.GetElapsedTime(started).TotalSeconds:F1} s.");

        using var run = CancellationTokenSource.CreateLinkedTokenSource(stop);
        run.CancelAfter(TimeSpan.FromSeconds(80));
        var frames = Channel.CreateBounded<(Frame Frame, long Timestamp)>(256);
        var receive = ReadRfcommFramesAsync(stream, frames.Writer, run.Token);
        Task Write(Frame frame, CancellationToken token) => stream.WriteAsync(frame.Encode(), token).AsTask();
        var trace = CreateTrace(tracePath);
        try
        {
            await Write(new Frame(Kind.Start, 60), run.Token);
            await MeasurePhaseAsync(60, frames.Reader, Write, trace, run.Token);
        }
        finally
        {
            run.Cancel();
            stream.Close();
            connection.Close();
            await receive;
        }
        await SaveTraceAsync(tracePath, trace, stop);
        Console.WriteLine("RFCOMM measurement complete. Read the RTT and PASS/FAIL results on the Mac.");
    }

    private static async Task ReadRfcommFramesAsync(NetworkStream stream,
        ChannelWriter<(Frame Frame, long Timestamp)> frames, CancellationToken stop)
    {
        var bytes = new byte[16];
        try
        {
            while (!stop.IsCancellationRequested)
            {
                await stream.ReadExactlyAsync(bytes, stop);
                var timestamp = Stopwatch.GetTimestamp();
                if (!frames.TryWrite((Frame.Decode(bytes), timestamp)))
                    throw new IOException("The Windows RFCOMM frame buffer overflowed.");
            }
            frames.TryComplete();
        }
        catch (Exception error)
        {
            frames.TryComplete(error);
        }
    }

    private static async Task MeasureAsync(ProbeOptions options, CancellationToken stop)
    {
        using var connection = CancellationTokenSource.CreateLinkedTokenSource(stop);
        connection.CancelAfter(TimeSpan.FromSeconds(45));
        var setup = connection.Token;
        var adapter = await BluetoothAdapter.GetDefaultAsync().AsTask(setup);
        if (adapter is null || !adapter.IsLowEnergySupported)
            throw new InvalidOperationException("BLOCKED: No Windows Bluetooth LE adapter is available.");
        var radio = await adapter.GetRadioAsync().AsTask(setup);
        if (radio is null || radio.State != RadioState.On)
            throw new InvalidOperationException($"BLOCKED: Windows Bluetooth radio state is {radio?.State.ToString() ?? "unavailable"}.");

        Console.WriteLine("Scanning for the Mac BLE probe (20-second limit)…");
        var started = Stopwatch.GetTimestamp();
        var advertisement = await FindMacAsync(setup);
        using var device = await BluetoothLEDevice.FromBluetoothAddressAsync(advertisement.BluetoothAddress,
            advertisement.BluetoothAddressType).AsTask(setup)
            ?? throw new InvalidOperationException("Windows could not open the advertised BLE device.");
        if (device.DeviceAccessInformation.CurrentStatus is DeviceAccessStatus.DeniedByUser or DeviceAccessStatus.DeniedBySystem)
            throw new UnauthorizedAccessException("The current device access policy blocks this device.");
        var services = await device.GetGattServicesForUuidAsync(ServiceId, BluetoothCacheMode.Uncached).AsTask(setup);
        CheckStatus(services.Status, "service discovery");
        using var service = services.Services.Single();
        var characteristics = await service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached).AsTask(setup);
        CheckStatus(characteristics.Status, "characteristic discovery");
        var notifications = characteristics.Characteristics.Single(value => value.Uuid == NotifyId);
        var writes = characteristics.Characteristics.Single(value => value.Uuid == WriteId);

        var frames = Channel.CreateBounded<(Frame Frame, long Timestamp)>(256);
        TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs> receive = (_, args) =>
        {
            var timestamp = Stopwatch.GetTimestamp();
            try
            {
                CryptographicBuffer.CopyToByteArray(args.CharacteristicValue, out var bytes);
                if (!frames.Writer.TryWrite((Frame.Decode(bytes), timestamp)))
                    frames.Writer.TryComplete(new IOException("The Windows notification buffer overflowed."));
            }
            catch (Exception error)
            {
                frames.Writer.TryComplete(error);
            }
        };
        TypedEventHandler<BluetoothLEDevice, object> disconnected = (sender, _) =>
        {
            if (sender.ConnectionStatus == BluetoothConnectionStatus.Disconnected)
                frames.Writer.TryComplete(new IOException("Mac disconnected before the run completed."));
        };
        notifications.ValueChanged += receive;
        try
        {
            var subscribed = await notifications.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify).AsTask(setup);
            CheckStatus(subscribed, "notification subscription");
            device.ConnectionStatusChanged += disconnected;
            await WriteAsync(writes, options.Start, setup);
            Console.WriteLine($"Connected and ready {Stopwatch.GetElapsedTime(started).TotalSeconds:F1} s after starting the scan.");

            using var run = CancellationTokenSource.CreateLinkedTokenSource(stop);
            var rates = options.Rates;
            run.CancelAfter(TimeSpan.FromSeconds(rates.Length == 1 ? 80 : 145));
            var trace = CreateTrace(options.TracePath);
            foreach (var rate in rates)
                await MeasurePhaseAsync(rate, frames.Reader, (frame, token) => WriteAsync(writes, frame, token), trace, run.Token);
            await SaveTraceAsync(options.TracePath, trace, stop);
            Console.WriteLine("Measurement complete. Read the RTT and PASS/FAIL results on the Mac.");
        }
        finally
        {
            notifications.ValueChanged -= receive;
            device.ConnectionStatusChanged -= disconnected;
            // Disposing the service/device closes this session without requesting a pairing or changing the radio.
        }
    }

    private static async Task<BluetoothLEAdvertisementReceivedEventArgs> FindMacAsync(CancellationToken stop)
    {
        var found = new TaskCompletionSource<BluetoothLEAdvertisementReceivedEventArgs>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        watcher.AdvertisementFilter.Advertisement.ServiceUuids.Add(ServiceId);
        watcher.Received += (_, args) => found.TrySetResult(args);
        watcher.Stopped += (_, args) =>
        {
            if (args.Error == BluetoothError.DisabledByPolicy)
                found.TrySetException(new UnauthorizedAccessException("Bluetooth scanning is disabled by Windows policy."));
            else if (args.Error != BluetoothError.Success)
                found.TrySetException(new IOException($"Windows BLE scanning stopped: {args.Error}."));
        };
        watcher.Start();
        try
        {
            return await found.Task.WaitAsync(TimeSpan.FromSeconds(20), stop);
        }
        catch (TimeoutException)
        {
            throw new TimeoutException("No Mac BLE probe was found within 20 seconds. Keep its window open during scanning.");
        }
        finally
        {
            watcher.Stop();
        }
    }

    private static async Task MeasurePhaseAsync(ushort rate, ChannelReader<(Frame Frame, long Timestamp)> frames,
        Func<Frame, CancellationToken, Task> write, StringBuilder? trace, CancellationToken stop)
    {
        var expected = (uint)(rate * PhaseSeconds);
        var (begin, _) = await ReadAsync(frames, stop);
        if (begin.Kind != Kind.Begin || begin.Rate != rate || begin.Sequence != expected)
            throw new InvalidDataException($"Expected the {rate} Hz phase to begin.");
        Console.WriteLine($"Receiving {rate} Hz for {PhaseSeconds} seconds.");

        var cadence = new Cadence();
        uint lastSequence = 0;
        while (true)
        {
            var (frame, timestamp) = await ReadAsync(frames, stop);
            if (frame.Rate != rate)
                throw new InvalidDataException($"Unexpected {frame.Rate} Hz frame during the {rate} Hz phase.");
            if (frame.Kind == Kind.End && frame.Sequence == expected)
                break;
            if (frame.Kind is not (Kind.Motion or Kind.Probe) || frame.Sequence <= lastSequence || frame.Sequence > expected)
                throw new InvalidDataException($"Unexpected frame or sequence at {rate} Hz.");

            cadence.Record(frame.Sequence, timestamp);
            lastSequence = frame.Sequence;
            if (frame.Kind == Kind.Probe)
                await write(new Frame(Kind.Ack, rate, frame.Sequence), stop);
        }

        var received = (uint)cadence.Samples.Count;
        await write(new Frame(Kind.Result, rate, received), stop);
        var intervals = cadence.Samples.Skip(1).Select(sample => sample.IntervalMs!.Value).Order().ToArray();
        Console.WriteLine($"{rate} Hz: {received}/{expected} delivered ({(double)received / expected:P2}), " +
            $"receive interval median {Milliseconds(Percentile(intervals, 0.5))}, " +
            $"P95 {Milliseconds(Percentile(intervals, 0.95))}.");
        if (trace is not null)
            foreach (var sample in cadence.Samples)
                trace.Append(sample.CsvRow(rate));
    }

    private static StringBuilder? CreateTrace(string? path) =>
        path is null ? null : new StringBuilder("rate_hz,sequence,elapsed_ms,interval_ms\n");

    private static async Task SaveTraceAsync(string? path, StringBuilder? trace, CancellationToken stop)
    {
        if (path is null || trace is null) return;
        try { await File.WriteAllTextAsync(path, trace.ToString(), stop); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new IOException($"Could not write the Windows trace to {path}: {error.Message}", error);
        }
        Console.WriteLine($"Windows trace: {Path.GetFullPath(path)}");
    }

    private static async Task<(Frame Frame, long Timestamp)> ReadAsync(
        ChannelReader<(Frame Frame, long Timestamp)> frames, CancellationToken stop)
    {
        try
        {
            return await frames.ReadAsync(stop).AsTask().WaitAsync(TimeSpan.FromSeconds(10), stop);
        }
        catch (ChannelClosedException error) when (error.InnerException is not null)
        {
            throw new IOException(error.InnerException.Message, error.InnerException);
        }
        catch (TimeoutException)
        {
            throw new TimeoutException("No BLE frames arrived for 10 seconds. The run is incomplete.");
        }
    }

    private static async Task WriteAsync(GattCharacteristic characteristic, Frame frame, CancellationToken stop)
    {
        using var write = CancellationTokenSource.CreateLinkedTokenSource(stop);
        write.CancelAfter(TimeSpan.FromSeconds(5));
        var payload = CryptographicBuffer.CreateFromByteArray(frame.Encode());
        var result = await characteristic.WriteValueWithResultAsync(payload, GattWriteOption.WriteWithResponse)
            .AsTask(write.Token);
        CheckStatus(result.Status, $"{frame.Kind} write");
    }

    private static void CheckStatus(GattCommunicationStatus status, string operation)
    {
        if (status == GattCommunicationStatus.AccessDenied)
            throw new UnauthorizedAccessException($"Access denied during {operation}.");
        if (status != GattCommunicationStatus.Success)
            throw new IOException($"BLE {operation} failed: {status}.");
    }

    private static string Milliseconds(double? value) => value is double ms ? $"{ms:F2} ms" : "n/a";

    private static double? Percentile(IReadOnlyList<double> sorted, double fraction)
    {
        if (sorted.Count == 0) return null;
        var index = (sorted.Count - 1) * fraction;
        var lower = (int)index;
        return sorted[lower] + (sorted[(int)Math.Ceiling(index)] - sorted[lower]) * (index - lower);
    }

    internal static int SelfTest()
    {
        var sample = new Frame(Kind.Probe, 125, 0x12345678, -2, 7);
        byte[] golden = [1, 4, 125, 0, 120, 86, 52, 18, 254, 255, 255, 255, 7, 0, 0, 0];
        var cadence = new Cadence();
        cadence.Record(1, 0);
        cadence.Record(4, Stopwatch.Frequency / 16);
        var single = ProbeOptions.Parse(["--rate", "60", "--trace", "receive.csv"]);
        var defaults = ProbeOptions.Parse([]);
        if (!sample.Encode().SequenceEqual(golden) || Frame.Decode(golden) != sample ||
            !RejectsFrame(golden.AsSpan(0, 15)) || Percentile([], 0.95) is not null ||
            Percentile([10, 20, 30], 0.5) != 20 || Percentile([10, 20, 30], 0.95) != 29 ||
            single?.Start != new Frame(Kind.Start, 60) || single.Rates is not [60] || single.TracePath != "receive.csv" ||
            defaults?.Start != new Frame(Kind.Start) || defaults.Rates is not [60, 125] ||
            ProbeOptions.Parse(["--rate", "125"]) is not null ||
            !cadence.Samples.Select(row => row.CsvRow(60)).SequenceEqual(["60,1,0.000,\n", "60,4,62.500,62.500\n"]))
            return 1;
        golden[0] = 2;
        if (!RejectsFrame(golden)) return 1;
        Console.WriteLine("Windows wire format and metric self-test passed.");
        return 0;
    }

    private static bool RejectsFrame(ReadOnlySpan<byte> bytes)
    {
        try { Frame.Decode(bytes); return false; }
        catch (InvalidDataException) { return true; }
    }
}
