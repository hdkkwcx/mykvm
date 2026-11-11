# MyKVM 蓝牙链路原型

Mac 通过 BLE 发送带序号的模拟鼠标数据，Windows 回传探测确认。测试独立于 MyKVM 正式应用运行，保留 CUG Wi-Fi 和 Clash Verge 配置。程序只生成合成数据，不捕获或注入真实输入。

## 构建

macOS 使用现有的 Xcode Command Line Tools。从仓库根目录运行：

```sh
sh experiments/ble-link/macos/build.sh
experiments/ble-link/out/MyKVM-BLE-Probe.app/Contents/MacOS/MyKvmBleProbe --self-test
```

用 .NET 10 SDK 生成 Windows 免安装程序。从仓库根目录运行以下命令。Windows ARM 设备可把 `win-x64` 和输出目录分别改为 `win-arm64` 和 `windows-arm64`。

```text
dotnet publish experiments/ble-link/windows/MyKvmBleProbe.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o experiments/ble-link/out/windows-x64
```

把输出目录中的 `MyKvmBleProbe.exe` 复制到 Windows。目标机器需要蓝牙 LE 和 Windows 10 版本 2004 或更高版本。它不需要安装 .NET 或以管理员身份运行。用 PowerShell 执行 `.\MyKvmBleProbe.exe --self-test` 可检查协议编码和百分位数计算。

## 双机测试

1. 在 Mac 终端运行 `experiments/ble-link/out/MyKVM-BLE-Probe.app/Contents/MacOS/MyKvmBleProbe`。等待显示 `Advertising`，并保持测试窗口打开。首次需要请求本应用的蓝牙权限时，使用下方的授权启动命令。
2. 在 5 分钟内从 Windows PowerShell 运行 `.\MyKvmBleProbe.exe`。Windows 按服务 UUID 扫描，20 秒找不到就退出。测试自动依次运行 60 Hz 和 125 Hz，每档 60 秒。
3. 保存两端的终端输出。Windows 输出连接耗时、送达率和接收间隔的中位数及 P95。Mac 输出调度漏发、蓝牙发送队列丢弃、送达率、往返延迟和回复数。送达率的分母为计划样本数，包含发送前跳过的样本。RTT 用 Mac 的单调时钟从发出探测到收到 Windows 确认计算，不含真实输入处理或屏幕显示时间。
4. 每档以送达率 ≥99%、RTT P95 ≤50 ms 判定。Mac 退出码 `0` 表示请求的测量已完成且 60 Hz 达标，`2` 表示测量完成但 60 Hz 未达标，`1` 表示权限、超时或断连等原因导致未完成。若测量了 125 Hz，则单独打印该档结果。若 RTT 没有样本，该档判为未达标。

验证异常路径时，可单独启动 Windows 端检查扫描超时。成功连接后可关闭 Mac 测试窗口，检查 Windows 是否报断连或在 10 秒无通知后退出。随后按顺序重启两端，检查能否完成新一轮测试。

Mac 默认只使用现有授权。首次需要申请时，从仓库根目录执行以下命令，并在系统弹窗里确认 **MyKVM BLE Probe** 的请求。允许后应用继续启动广播。Windows 端沿用现有授权。

```sh
open -n -W --stdout "$PWD/experiments/ble-link/out/mac-live.stdout.log" \
  experiments/ble-link/out/MyKVM-BLE-Probe.app --args --request-bluetooth
```

### 60 Hz 单档与间隔记录

从仓库根目录启动 Mac 端。蓝牙回调和定时器使用专用串行队列，应用窗口在主线程显示状态。

```sh
open -n -W --stdout "$PWD/experiments/ble-link/out/mac-60hz.stdout.log" \
  experiments/ble-link/out/MyKVM-BLE-Probe.app --args --request-bluetooth \
  --trace "$PWD/experiments/ble-link/out/mac-submit-60hz.csv"
```

Mac 开始广播后，在 Windows 上用新版程序运行：

```powershell
.\MyKvmBleProbe.exe --rate 60 --trace windows-receive-60hz.csv
```

每端在测量完成后写入一份 CSV。字段为 `rate_hz,sequence,elapsed_ms,interval_ms`，每档第一条的相对时间为零，间隔留空。按频率和序号对照两份记录。Mac 在调用 Core Bluetooth `updateValue` 时计时，保留被接口接受的提交。Windows 在 GATT 通知回调入口计时，早于入队和回复。各端时间来自各自的单调时钟，可以比较间隔和序号。要测空口时间或单程延迟，需要另外的观测手段。

### 经典蓝牙 RFCOMM

在 Windows 上先运行以下命令。程序检查适配器的经典蓝牙能力，打开临时 RFCOMM 监听端口，然后打印本机蓝牙地址和通道。保持窗口打开，等待 Mac 连接。

```powershell
.\MyKvmBleProbe.exe --rfcomm --trace windows-rfcomm-60hz.csv
```

把输出中的地址和通道填进下方命令，在仓库根目录启动 Mac 程序。如果系统显示配对或授权弹窗，由用户确认后继续。

```sh
open -n -W --stdout "$PWD/experiments/ble-link/out/mac-rfcomm.stdout.log" \
  experiments/ble-link/out/MyKVM-BLE-Probe.app --args --request-bluetooth \
  --rfcomm WINDOWS_BLUETOOTH_ADDRESS CHANNEL \
  --trace "$PWD/experiments/ble-link/out/mac-rfcomm-60hz.csv"
```

连接后自动发送 60 秒的 60 Hz 模拟鼠标样本。Mac 以 IOBluetooth 接受异步写入为提交，Windows 以读取完一个 RFCOMM 应用帧为接收。两端沿用相同的序号、送达率与 RTT 统计。Windows 的读取时间包括本地流缓冲和应用调度。

两台机器完成配对后，Mac 修正了 Classic Bluetooth 初始化期间过早打开通道的问题，RFCOMM 连通并完成了 60 Hz、60 秒实测。两份 CSV 的序号均连续覆盖 1–3,600，顺序完全一致。送达率为 100%，Mac 调度漏发和发送队列丢弃均为零。

| RFCOMM 60 Hz | 中位数 | P95 |
| --- | ---: | ---: |
| Mac 提交间隔 | 16.01 ms | 18.01 ms |
| Windows 接收间隔 | 16.30 ms | 30.00 ms |
| 往返延迟 | 30.50 ms | 82.81 ms |

Windows 最长接收间隔为 60.24 ms，Mac 对应的提交间隔为 16.00 ms。60 个探测均收到回复。送达率达到 99% 门槛，往返延迟 P95 高于 50 ms 门槛。

## 线格式

GATT 通知从 Mac 发往 Windows，带响应的 GATT 写入从 Windows 发往 Mac。UUID 定义在两端源码中。每条消息固定 16 字节，依次为版本 `1`、类型、16 位频率、32 位序号和两个 32 位有符号模拟坐标。多字节字段用小端序。

Windows 写入 `Start` 后开始测试。`Start` 频率字段为 `0` 时沿用默认 60 Hz 和 125 Hz，字段为 `60` 时只测 60 Hz。每档由 `Begin`、若干 `Motion` 或 `Probe`、`End` 组成，运动序号从 1 开始。Windows 对每个 `Probe` 写回同序号的 `Ack`，收到 `End` 后写入 `Result`，用序号字段报告本档收到的样本数。该临时服务只用于近距离实验，负载全为合成数据。

## 初次验证记录

- Mac 应用及 Windows x64、ARM64 单文件构建通过。Swift 和 C# 的编解码、统计自检通过。C# 自检在 Mac 上用 .NET 运行，只验证与平台无关的逻辑。
- Mac 实机通过 `--request-bluetooth` 获得授权并开始广播。第一次等待 Windows 超时，重启 Mac 测试程序后完成双机测量。Windows 从开始扫描到就绪用时 3.2 秒，Mac 从开始广播到收到 Windows 开始消息用时 27.6 秒。

| 频率 | 送达样本 | Mac 调度漏发 | 发送队列丢弃 | Windows 接收间隔中位数 / P95 | RTT 中位数 / P95 | 探测回复 |
| --- | --- | --- | --- | --- | --- | --- |
| 60 Hz | 3,325 / 3,600（92.36%） | 274 | 1 | 0.58 / 59.68 ms | 86.49 / 106.96 ms | 60 / 60 |
| 125 Hz | 1,705 / 7,500（22.73%） | 5,795 | 0 | 59.20 / 60.30 ms | 92.19 / 119.19 ms | 60 / 60 |

两档均未达到 99% 送达率和 50 ms RTT P95 的门槛。两档被 Mac 发送队列接收的样本均到达 Windows。60 Hz 时，Windows 的通知回调间隔呈现短间隔和较长停顿并存的现象，单凭两端日志无法定位是哪一层造成。Windows 已实测找不到设备时在 20 秒后退出。主动断连后重连仍待验证。

## 60 Hz 串行队列重测

在同一对机器上使用 5 分钟的 Mac 广播窗口，Windows 从开始扫描到就绪用时 5.6 秒。单档测量 60 秒，计划发送 3,600 个样本。

| 指标 | 原始 60 Hz | 串行队列 60 Hz |
| --- | ---: | ---: |
| 送达样本 | 3,325 / 3,600（92.36%） | 3,267 / 3,600（90.75%） |
| Mac 调度漏发 / 发送队列丢弃 | 274 / 1 | 327 / 6 |
| Mac 提交间隔中位数 / P95 | 未记录 | 16.24 / 33.19 ms |
| Windows 接收间隔中位数 / P95 | 0.58 / 59.68 ms | 0.50 / 174.41 ms |
| RTT 中位数 / P95 | 86.49 / 106.96 ms | 105.50 / 222.67 ms |
| 探测回复 | 60 / 60 | 60 / 60 |

以频率和序号对齐两端 CSV，3,267 个序号及顺序完全一致，双方独有序号均为零。计划的 3,600 个样本中，333 个缺失在成功提交之前。Mac 日志将其分为 327 次调度漏发和 6 次发送队列丢弃。

Windows 有 172 个接收间隔达到 100 ms，其中 148 个对应的 Mac 提交间隔不超过 25 ms。序号 1588–1601 的 14 个样本在 Mac 上陆续提交，首尾相隔 216.99 ms。Windows 在上一条通知后等了 238.82 ms，然后在 5.71 ms 内收到这 14 条通知。

本轮未达到送达率和 RTT 门槛。两端间隔显示通知在 Mac 提交后、Windows 应用收到回调前出现成批到达。两份日志使用各自的单调时钟，可比较同一批样本在各端的时间跨度。要区分 Core Bluetooth 排队、空口传输和 Windows 通知分发，需要中间层时间戳。
