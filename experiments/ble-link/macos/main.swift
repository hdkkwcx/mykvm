import AppKit
import CoreBluetooth
import Foundation
import IOBluetooth

private let serviceID = CBUUID(string: "E836E781-4D37-4C08-9084-6134A78AB001")
private let notifyID = CBUUID(string: "E836E781-4D37-4C08-9084-6134A78AB002")
private let writeID = CBUUID(string: "E836E781-4D37-4C08-9084-6134A78AB003")
private let phaseSeconds = 60
private let advertisingMinutes = 5
private let traceHeader = "rate_hz,sequence,elapsed_ms,interval_ms\n"

private enum Kind: UInt8 { case start = 1, begin, motion, probe, ack, end, result }

private struct Frame: Equatable {
    static let size = 16
    let kind: Kind
    var rate: UInt16 = 0
    var sequence: UInt32 = 0
    var x: Int32 = 0
    var y: Int32 = 0

    func encode() -> Data {
        var data = Data([1, kind.rawValue])
        func append<T: FixedWidthInteger>(_ number: T) {
            var littleEndian = number.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(rate)
        append(sequence)
        append(x)
        append(y)
        return data
    }

    init(kind: Kind, rate: UInt16 = 0, sequence: UInt32 = 0, x: Int32 = 0, y: Int32 = 0) {
        self.kind = kind
        self.rate = rate
        self.sequence = sequence
        self.x = x
        self.y = y
    }

    init?(_ data: Data) {
        guard data.count == Self.size else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 1, let kind = Kind(rawValue: bytes[1]) else { return nil }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        self.init(kind: kind, rate: UInt16(bytes[2]) | UInt16(bytes[3]) << 8,
                  sequence: word(4), x: Int32(bitPattern: word(8)), y: Int32(bitPattern: word(12)))
    }
}

private func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let index = Double(sorted.count - 1) * fraction
    let lower = Int(index)
    return sorted[lower] + (sorted[Int(ceil(index))] - sorted[lower]) * (index - Double(lower))
}

private func requestedRates(_ frame: Frame) -> [UInt16]? {
    guard frame.kind == .start, frame.sequence == 0, frame.x == 0, frame.y == 0 else { return nil }
    switch frame.rate {
    case 0: return [60, 125]
    case 60: return [60]
    default: return nil
    }
}

private struct Timing {
    let sequence: UInt32
    let elapsedMs: Double
    let intervalMs: Double?

    func csvRow(rate: UInt16) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let elapsed = String(format: "%.3f", locale: locale, elapsedMs)
        let interval = intervalMs.map { String(format: "%.3f", locale: locale, $0) } ?? ""
        return "\(rate),\(sequence),\(elapsed),\(interval)\n"
    }
}

private struct Cadence {
    private var first: Double?
    private var previous: Double?
    private(set) var samples: [Timing] = []

    mutating func record(sequence: UInt32, at time: Double) {
        let origin = first ?? time
        samples.append(Timing(sequence: sequence, elapsedMs: (time - origin) * 1000,
                              intervalMs: previous.map { (time - $0) * 1000 }))
        first = origin
        previous = time
    }
}

private final class Phase {
    let rate: UInt16
    var expected: Int { Int(rate) * phaseSeconds }
    var started: Double?
    var endSent: Double?
    var lastSlot = 0
    var attempted = 0
    var cadence = Cadence()
    var accepted: Int { cadence.samples.count }
    var lastProbeSecond = -1
    var probesSent = 0
    var pendingProbes: [UInt32: Double] = [:]
    var roundTrips: [Double] = []
    var lastReply: Double?

    init(rate: UInt16) { self.rate = rate }
}

private struct RfcommTarget {
    let address: String
    let channel: UInt8

    init?(_ address: String, _ channel: String) {
        let hex = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let digits = Array(hex)
        guard digits.count == 12, let number = UInt64(hex, radix: 16), number > 0,
              let port = UInt8(channel), (1...30).contains(port) else { return nil }
        self.address = stride(from: 0, to: digits.count, by: 2)
            .map { String(digits[$0...($0 + 1)]) }.joined(separator: ":")
        self.channel = port
    }
}

private final class RfcommLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let queue: DispatchQueue
    private let onOpen: () -> Void
    private let onFrame: (Frame) -> Void
    private let onFailure: (String) -> Void
    private var channel: IOBluetoothRFCOMMChannel?
    private var buffer = Data()
    private var pending = 0

    init(queue: DispatchQueue, onOpen: @escaping () -> Void, onFrame: @escaping (Frame) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.queue = queue
        self.onOpen = onOpen
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func connect(_ target: RfcommTarget) {
        // Start the legacy IOBluetooth open from the application's run loop.
        DispatchQueue.main.async {
            guard let device = IOBluetoothDevice(addressString: target.address) else {
                self.queue.async { self.onFailure("Mac could not initialize the remote Bluetooth device.") }
                return
            }
            // Creating the device starts the Classic Bluetooth coordinator asynchronously.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
                self.open(device, channelID: target.channel)
            }
        }
    }

    private func open(_ device: IOBluetoothDevice, channelID: UInt8) {
        var opening: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opening, withChannelID: channelID, delegate: self)
        guard status == kIOReturnSuccess, let opening else {
            queue.async { self.onFailure("RFCOMM open could not start (\(Self.describe(status))).") }
            return
        }
        // Keep the channel alive while IOBluetooth establishes the baseband link.
        queue.async {
            if self.channel == nil { self.channel = opening }
        }
    }

    func send(_ data: Data) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let channel, pending < 8 else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        data.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: data.count)
        let status = channel.writeAsync(storage, length: UInt16(data.count), refcon: storage)
        if status != kIOReturnSuccess {
            storage.deallocate()
            if status != kIOReturnNoResources && status != kIOReturnBusy && status != kIOReturnNoSpace {
                onFailure("RFCOMM write failed (\(Self.describe(status))).")
            }
            return false
        }
        pending += 1
        return true
    }

    func close() {
        if let channel {
            _ = channel.setDelegate(nil)
            _ = channel.close()
        }
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        queue.async {
            guard status == kIOReturnSuccess, let channel else {
                self.onFailure("RFCOMM connection failed (\(Self.describe(status))).")
                return
            }
            self.channel = channel
            self.onOpen()
        }
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        guard let data, length > 0 else { return }
        let bytes = Data(bytes: data, count: length)
        queue.async {
            self.buffer.append(bytes)
            while self.buffer.count >= Frame.size {
                guard let frame = Frame(Data(self.buffer.prefix(Frame.size))) else {
                    self.onFailure("Invalid RFCOMM control frame.")
                    return
                }
                self.buffer.removeFirst(Frame.size)
                self.onFrame(frame)
            }
        }
    }

    func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn) {
        guard let refcon else { return }
        let address = UInt(bitPattern: refcon)
        queue.async {
            UnsafeMutableRawPointer(bitPattern: address)?.deallocate()
            self.pending -= 1
            if status != kIOReturnSuccess {
                self.onFailure("RFCOMM write completion failed (\(Self.describe(status))).")
            }
        }
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        queue.async {
            self.channel = nil
            self.onFailure("RFCOMM channel closed before the run completed.")
        }
    }

    private static func describe(_ status: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: status))
    }
}

private final class Probe: NSObject, CBPeripheralManagerDelegate {
    private let queue = DispatchQueue(label: "org.mykvm.experiments.ble-link.probe", qos: .userInitiated)
    private let requestingAuthorization: Bool
    private let rfcommTarget: RfcommTarget?
    private var rfcomm: RfcommLink?
    private let traceURL: URL?
    private let statusChanged: (String) -> Void
    private var trace = traceHeader
    private var manager: CBPeripheralManager?
    private lazy var notify = CBMutableCharacteristic(type: notifyID, properties: [.notify],
                                                      value: nil, permissions: [])
    private var central: CBCentral?
    private var timer: DispatchSourceTimer?
    private var phase: Phase?
    private var rates: [UInt16] = []
    private var rateIndex = 0
    private var passed60Hz = false
    private var notificationReady = true
    private var published = false
    private var deadline = 0.0
    private var advertisedAt: Double?
    private var finishing = false

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    init(requestingAuthorization: Bool, rfcommTarget: RfcommTarget?, traceURL: URL?,
         statusChanged: @escaping (String) -> Void) {
        self.requestingAuthorization = requestingAuthorization
        self.rfcommTarget = rfcommTarget
        self.traceURL = traceURL
        self.statusChanged = statusChanged
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func cancel() {
        queue.async {
            if !self.finishing { self.fail("Mac probe window closed before the run completed.") }
        }
    }

    private func startOnQueue() {
        deadline = now + (requestingAuthorization ? 180 : 10)
        if requestingAuthorization {
            report("Waiting for you to confirm the macOS Bluetooth prompt for MyKVM BLE Probe.")
        }
        if let rfcommTarget, !requestingAuthorization {
            startRfcomm(rfcommTarget)
        } else {
            manager = CBPeripheralManager(delegate: self, queue: queue, options: [
                CBPeripheralManagerOptionShowPowerAlertKey: false,
            ])
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func startRfcomm(_ target: RfcommTarget) {
        deadline = now + 180
        report("Opening Classic Bluetooth RFCOMM channel \(target.channel) on Windows…")
        let link = RfcommLink(queue: queue, onOpen: { [weak self] in
            self?.rfcommOpened()
        }, onFrame: { [weak self] frame in
            self?.handle(frame) { accepted in
                if !accepted { self?.fail("Unexpected RFCOMM control frame.") }
            }
        }, onFailure: { [weak self] error in
            if let self, !self.finishing { self.fail(error) }
        })
        rfcomm = link
        link.connect(target)
    }

    private func rfcommOpened() {
        deadline = now + 10
        report("Classic Bluetooth RFCOMM channel opened. Waiting for Windows to start the measurement.")
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            guard CBManager.authorization == .allowedAlways, !published else { return }
            published = true
            if let rfcommTarget {
                startRfcomm(rfcommTarget)
                return
            }
            deadline = now + 10
            let service = CBMutableService(type: serviceID, primary: true)
            let receive = CBMutableCharacteristic(type: writeID, properties: [.write],
                                                  value: nil, permissions: [.writeable])
            service.characteristics = [notify, receive]
            peripheral.add(service)
        case .poweredOff: fail("BLOCKED: Mac Bluetooth is off.")
        case .unauthorized:
            if requestingAuthorization, CBManager.authorization == .notDetermined { return }
            fail("BLOCKED: Mac Bluetooth access was denied or restricted.")
        case .unsupported: fail("BLOCKED: Mac Bluetooth LE peripheral mode is unavailable.")
        case .unknown, .resetting: break
        @unknown default: fail("BLOCKED: Unknown Mac Bluetooth state.")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { fail("Cannot publish the BLE service: \(error)") }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { fail("Cannot advertise the BLE service: \(error)") }
        advertisedAt = now
        deadline = now + Double(advertisingMinutes * 60)
        report("Advertising. Start the Windows probe within \(advertisingMinutes) minutes.")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central candidate: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == notifyID, central == nil else { return }
        guard candidate.maximumUpdateValueLength >= Frame.size else {
            fail("BLE notification payload limit is smaller than \(Frame.size) bytes.")
        }
        central = candidate
        peripheral.stopAdvertising()
        deadline = now + 5
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central candidate: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == notifyID, candidate.identifier == central?.identifier, !finishing {
            fail("Windows unsubscribed or disconnected before the run completed.")
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        notificationReady = true
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let request = requests.first else { return }
        guard requests.count == 1, request.characteristic.uuid == writeID, request.offset == 0,
              request.central.identifier == central?.identifier,
              let value = request.value, let frame = Frame(value) else {
            peripheral.respond(to: request, withResult: .unlikelyError)
            return
        }
        handle(frame) { accepted in
            peripheral.respond(to: request, withResult: accepted ? .success : .unlikelyError)
        }
    }

    private func handle(_ frame: Frame, respond: (Bool) -> Void) {
        guard frame.x == 0, frame.y == 0 else {
            respond(false)
            return
        }
        if phase == nil, let requested = requestedRates(frame) {
            rates = requested
            respond(true)
            if let advertisedAt { report(String(format: "Windows ready %.1f s after advertising.", now - advertisedAt)) }
            startPhase()
        } else if let phase, frame.rate == phase.rate {
            switch frame.kind {
            case .ack:
                if let sent = phase.pendingProbes.removeValue(forKey: frame.sequence) {
                    let received = now
                    phase.roundTrips.append((received - sent) * 1000)
                    phase.lastReply = received
                }
                respond(true)
            case .result where phase.endSent != nil && frame.sequence <= UInt32(phase.accepted):
                respond(true)
                finishPhase(phase, received: Int(frame.sequence))
            default:
                respond(false)
            }
        } else {
            respond(false)
        }
    }

    private func startPhase() {
        phase = Phase(rate: rates[rateIndex])
        deadline = now + 5
    }

    private func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finishing else { return }
        let current = now
        guard let phase else {
            if current >= deadline {
                if requestingAuthorization, CBManager.authorization == .notDetermined {
                    fail("Timed out waiting for Bluetooth authorization.")
                }
                if rfcommTarget != nil { fail("Timed out waiting for the RFCOMM connection or Windows start message.") }
                fail("Timed out waiting for the BLE service or Windows start message.")
            }
            return
        }
        guard let started = phase.started else {
            if send(Frame(kind: .begin, rate: phase.rate, sequence: UInt32(phase.expected))) != nil {
                phase.started = now
                report("Measuring \(phase.rate) Hz for \(phaseSeconds) seconds.")
            } else if current >= deadline { fail("Timed out sending the phase start.") }
            return
        }
        let elapsed = current - started
        if elapsed < Double(phaseSeconds) {
            if current - (phase.lastReply ?? started) >= 10 {
                fail("No probe replies from Windows for 10 seconds. The run is incomplete.")
            }
            sendMotion(phase, elapsed: elapsed)
        } else if let endSent = phase.endSent {
            if current - endSent >= 5 { fail("Timed out waiting for the Windows result at \(phase.rate) Hz.") }
        } else if elapsed >= Double(phaseSeconds) + 0.75 {
            if send(Frame(kind: .end, rate: phase.rate, sequence: UInt32(phase.expected))) != nil {
                phase.endSent = now
            } else if elapsed >= Double(phaseSeconds) + 5 { fail("Timed out sending the phase end.") }
        }
    }

    private func sendMotion(_ phase: Phase, elapsed: Double) {
        // Offer at most one sample per timer tick. Missed slots are counted, never replayed in a burst.
        let slot = Int(elapsed * Double(phase.rate)) + 1
        guard slot > phase.lastSlot else { return }
        phase.lastSlot = slot
        phase.attempted += 1
        let second = (slot - 1) / Int(phase.rate)
        let isProbe = second != phase.lastProbeSecond
        let sequence = UInt32(slot)
        let frame = Frame(kind: isProbe ? .probe : .motion, rate: phase.rate, sequence: sequence,
                          x: Int32(slot % 31 - 15), y: Int32(slot % 17 - 8))
        guard let submitted = send(frame) else { return }
        phase.cadence.record(sequence: sequence, at: submitted)
        if isProbe {
            phase.lastProbeSecond = second
            phase.probesSent += 1
            phase.pendingProbes[sequence] = submitted
        }
    }

    private func send(_ frame: Frame) -> Double? {
        dispatchPrecondition(condition: .onQueue(queue))
        if let rfcomm {
            let payload = frame.encode()
            let submitted = now
            return rfcomm.send(payload) ? submitted : nil
        }
        guard notificationReady, let manager, let central else { return nil }
        let payload = frame.encode()
        let submitted = now
        notificationReady = manager.updateValue(payload, for: notify, onSubscribedCentrals: [central])
        return notificationReady ? submitted : nil
    }

    private func finishPhase(_ phase: Phase, received: Int) {
        let sorted = phase.roundTrips.sorted()
        let intervals = phase.cadence.samples.compactMap(\.intervalMs).sorted()
        let median = percentile(sorted, 0.5)
        let p95 = percentile(sorted, 0.95)
        let delivery = Double(received) / Double(phase.expected)
        let passed = delivery >= 0.99 && (p95 ?? .infinity) <= 50
        func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.2f ms", $0) } ?? "n/a" }
        report(String(format: "%d Hz: %d/%d delivered (%.2f%%), %d scheduler misses, %d queue drops",
                      Int(phase.rate), received, phase.expected, delivery * 100,
                      phase.expected - phase.attempted, phase.attempted - phase.accepted))
        report("Mac submission interval: median \(milliseconds(percentile(intervals, 0.5))), " +
               "P95 \(milliseconds(percentile(intervals, 0.95))) (\(phase.accepted) submitted).")
        report("RTT: median \(milliseconds(median)), P95 \(milliseconds(p95)), " +
               "\(sorted.count)/\(phase.probesSent) replies (60 planned). \(passed ? "PASS" : "FAIL")")
        if traceURL != nil {
            trace += phase.cadence.samples.map { $0.csvRow(rate: phase.rate) }.joined()
        }
        if phase.rate == 60 { passed60Hz = passed }
        rateIndex += 1
        if rateIndex < rates.count {
            startPhase()
        } else {
            finishing = true
            // Give the final reply time to reach Windows before closing the transport.
            queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                self.complete()
            }
        }
    }

    private func report(_ message: String) {
        statusChanged(message)
        print(message)
        fflush(stdout)
    }

    private func fail(_ message: String) -> Never {
        report(message)
        stop(1)
    }

    private func stop(_ code: Int32) -> Never {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel()
        rfcomm?.close()
        if let manager, manager.state == .poweredOn {
            manager.stopAdvertising()
            manager.removeAllServices()
        }
        exit(code)
    }

    private func complete() -> Never {
        if let traceURL {
            do {
                try Data(trace.utf8).write(to: traceURL, options: .atomic)
                report("Mac trace: \(traceURL.path)")
            } catch {
                fail("Could not write the Mac trace to \(traceURL.path): \(error.localizedDescription)")
            }
        }
        stop(passed60Hz ? 0 : 2)
    }
}

private final class ProbeApp: NSObject, NSApplicationDelegate {
    private let requestingAuthorization: Bool
    private let rfcommTarget: RfcommTarget?
    private let traceURL: URL?
    private var window: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "Starting Bluetooth test…")
    private lazy var probe = Probe(requestingAuthorization: requestingAuthorization, rfcommTarget: rfcommTarget,
                                   traceURL: traceURL) { [weak self] message in
        DispatchQueue.main.async { self?.status.stringValue = message }
    }

    init(requestingAuthorization: Bool, rfcommTarget: RfcommTarget?, traceURL: URL?) {
        self.requestingAuthorization = requestingAuthorization
        self.rfcommTarget = rfcommTarget
        self.traceURL = traceURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 140),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = rfcommTarget == nil ? "MyKVM BLE Probe" : "MyKVM RFCOMM Probe"
        window.isReleasedWhenClosed = false
        status.frame = NSRect(x: 20, y: 20, width: 440, height: 100)
        window.contentView?.addSubview(status)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        probe.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        probe.cancel()
        return .terminateCancel
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--self-test"] {
    let sample = Frame(kind: .probe, rate: 125, sequence: 0x12345678, x: -2, y: 7)
    let golden = Data([1, 4, 125, 0, 120, 86, 52, 18, 254, 255, 255, 255, 7, 0, 0, 0])
    var cadence = Cadence()
    cadence.record(sequence: 1, at: 1)
    cadence.record(sequence: 4, at: 1.0625)
    guard sample.encode() == golden, Frame(golden) == sample, Frame(golden.dropLast()) == nil,
          Frame(Data([2]) + golden.dropFirst()) == nil, percentile([], 0.95) == nil,
          percentile([10, 20, 30], 0.5) == 20, percentile([10, 20, 30], 0.95) == 29,
          requestedRates(Frame(kind: .start)) == [60, 125],
          requestedRates(Frame(kind: .start, rate: 60)) == [60],
          requestedRates(Frame(kind: .start, rate: 125)) == nil,
          cadence.samples.map({ $0.csvRow(rate: 60) }) == ["60,1,0.000,\n", "60,4,62.500,62.500\n"] else {
        print("Mac wire format or metric self-test failed.")
        exit(1)
    }
    print("Mac wire format and metric self-test passed.")
    exit(0)
}

private var options = ArraySlice(arguments)
private var allowRequest = false
private var traceURL: URL?
private var rfcommTarget: RfcommTarget?
while let option = options.popFirst() {
    switch option {
    case "--request-bluetooth" where !allowRequest:
        allowRequest = true
    case "--trace" where traceURL == nil:
        guard let path = options.popFirst(), !path.isEmpty, !path.hasPrefix("--") else {
            print("--trace requires a CSV path.")
            exit(1)
        }
        traceURL = URL(fileURLWithPath: path)
    case "--rfcomm" where rfcommTarget == nil:
        guard let address = options.popFirst(), let channel = options.popFirst(),
              let target = RfcommTarget(address, channel) else {
            print("--rfcomm requires a Bluetooth address and an RFCOMM channel (1–30).")
            exit(1)
        }
        rfcommTarget = target
    default:
        print("Usage: MyKvmBleProbe [--request-bluetooth] [--rfcomm ADDRESS CHANNEL] [--trace PATH] or MyKvmBleProbe --self-test")
        exit(1)
    }
}
let authorization = CBManager.authorization
let requestingAuthorization = allowRequest && authorization == .notDetermined
guard authorization == .allowedAlways || requestingAuthorization else {
    let reason = authorization == .notDetermined ? "has not been granted" : "is denied or restricted"
    print("BLOCKED: Mac Bluetooth access \(reason). The probe did not request it.")
    exit(1)
}
let application = NSApplication.shared
private let app = ProbeApp(requestingAuthorization: requestingAuthorization, rfcommTarget: rfcommTarget, traceURL: traceURL)
application.delegate = app
application.setActivationPolicy(.regular)
application.run()
