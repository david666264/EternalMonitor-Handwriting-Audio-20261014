# iPad USB 麦克风与本地 ASR 桥

本接口只传递用户主动开启的 iPad 麦克风音频。电脑端不安装新驱动，也不改变 Windows 默认麦克风、音量或静音状态。原有无线麦克风配置保持独立。

## 会话授权与生命周期

客户端 HELLO2 的 `feature_caps` 使用 `FEATURE_WANTS_MICROPHONE = 1 << 3`，Host 在 `host_caps` 返回 `HOSTCAP_MICROPHONE = 1 << 5`。两端均协商后，Host 只接受**当前已通过既有 HELLO 授权的 USB peer + session_id**，包括镜像主屏与扩展显示流。Wi-Fi、旧会话、其它 USB peer、未协商会话均丢弃。麦克风不会绕过现有连接授权。

同一会话 `mic_seq` 以 32 位回绕顺序前进；重复和倒退包不转发。用户关闭麦克风发送 end；切后台 BYE、USB 断线、会话接管、心跳超时、电脑停止流和任务结束都回收桥，并向本地消费者发送一次 end。新连接由客户端重新决定是否启用麦克风，Host 不自行打开麦克风。

## iPad → Host USB 数据包

使用已有 EMLINK 长度帧封装；EMv2 数据包类型 `0x04`。所有多字节整数均为 little endian。PCM 为 **16 kHz、单声道、signed PCM16LE**，每个普通包恰好 **320 samples / 20 ms / 640 bytes**。

| 偏移 | 字节数 | 字段 |
| --- | --- | --- |
| 0 | 2 | `EM`（`45 4D`） |
| 2 | 1 | version `2` |
| 3 | 1 | packet type `04` |
| 4 | 1 | flags：bit 0 为 end；其它位必须 0 |
| 5 | 1 | reserved：必须 0 |
| 6 | 2 | payload length：普通包 640，end 包 0 |
| 8 | 4 | 当前 session_id，非 0 |
| 12 | 4 | mic_seq |
| 16 | 8 | iPad capture_ts_us |
| 24 | 640 或 0 | PCM 或空 end |

普通包总长 664 bytes，end 总长 24 bytes。长度、保留位和会话不合法直接丢弃，不进入本地桥。

## Host → 本机 ASR UDP 数据包

目标固定为 **127.0.0.1:19878**，不会监听/发送到局域网。消费者只应绑定 IPv4 loopback，并从本机配置读取 token；不得将 token 传入模型、日志或云端。

配置在 `settings::app_data_dir()/microphone-bridge.json`（Windows 为 `%APPDATA%/EternalMonitor/microphone-bridge.json`）。首次合法 PCM 到来时按需创建，不在应用启动、Wi-Fi 连接或 end 包到来时创建。配置字段为 `schema_version`（必须 1）、`port`（必须 19878）、`token_hex`（随机非零 16 bytes 的 32 位 hex）。生产 token 不包含在源码和构建产物里。既有损坏或不兼容配置保留并禁用该次桥，不自动替换 token。Unix 配置文件权限为 0600；Windows 沿用当前用户应用数据目录的访问控制。

本地桥数据包固定头 40 bytes，整数同样 little endian：

| 偏移 | 字节数 | 字段 |
| --- | --- | --- |
| 0 | 4 | ASCII `EMM1` |
| 4 | 1 | version `1` |
| 5 | 1 | flags：bit 0 为 end，其它位 0 |
| 6 | 2 | payload length：640 或 0 |
| 8 | 16 | 本地配置 token 原始 bytes |
| 24 | 4 | session_id |
| 28 | 4 | mic_seq |
| 32 | 8 | capture_ts_us |
| 40 | 640 或 0 | PCM 或空 end |

普通桥包总长 680 bytes，end 总长 40 bytes。Host 回收产生的 end 使用最后一个接收序号加 1（回绕），时间戳保留最后一个采样时间。本机消费者必须验证来源为 loopback、magic/version/flags/长度/token/session/sequence；end 清理对应 ASR 输入队列。普通包是原 PCM，不经过有损编码。

UDP 为非阻塞发送；不可用、坏配置或本机发送失败只停止该会话麦克风桥，画面、TTS 和手写链路继续。这里确认的是本机转发，不代表 ASR 已识别或用户已提交文字。

### 本机诊断边界

每次新授权 HELLO 仅为麦克风协商新增 `usb / wants_mic / host_mic` 三个布尔诊断；当前会话的首个麦克风包仅记录一次 `decode_ok / authorized`，桥成功建立也仅记录一次。不会记录录音、包内容、令牌、设备标识或用户文字。这样可以区分未收到包、解码失败、未授权及本机桥初始化失败，不能以“引擎已开启”代替音频实际到达。

Windows 本机非阻塞 connected UDP 在没有消费者时仍可发送，消费者稍后启动可在同一 USB 麦克风会话收到后续包。独立回环复现确认 `10054` 出现在读取 ICMP 错误的 `recv`；本桥从不调用 `recv`，所以不据此修改现有发送错误策略。坏配置、权限或实际发送失败继续关闭该次桥，不自动替换凭据。

## Windows 桌面录音入口

若电脑已有并启用了 Steam Streaming Microphone 的录音和播放端，Host 会把同一份已授权 USB PCM 交给独立 WASAPI 工作线程。普通应用选择 `麦克风 (Steam Streaming Microphone)` 即可读取 iPad 声音；主程序的私有 UDP 桥继续提供原始 16 kHz PCM，供本地应用按自己的无线麦优先和音源锁定规则选择。

系统入口只规范 Steam 麦这两个端点的格式为 48 kHz、双声道、PCM32，并以 float32 写播放端。对实测默认 +30 dB 的录音增益采用软件衰减，避免削顶；不更改用户音量。启动失败会回滚此次修改的格式，缺失设备只停用系统入口，不影响 UDP、画面、手写或 TTS。工作队列最多 3 帧，丢弃过期音频；关闭麦克风、断线或会话结束后停止工作线程，不重放旧音频。

Host 不自动切换系统默认录音设备。Amadeus 的自动选麦仅作用于其共享 ASR 输入；普通桌面应用仍使用自身选择的录音设备，不会因该桥同时混入无线麦。

## 验证范围

Rust 单测覆盖 wire 偏移/长度/flags/end、协商与只 USB/当前 peer/旧 session 拦截、后台/断线/超时回收、随机 token 持久化与坏配置保留、序号回绕/去重，以及本机 UDP PCM + end。真实 iPad 录音许可、采样、USB 传输及 Amadeus ASR 接收仍需原生联调。

### 双向音频引擎的恢复

`AudioSessionCoordinator` 是唯一硬件恢复入口。播放层不因普通路由通知释放自身租约；已有麦克风正常运行时，播放开始、更换和静音只更新源节点读取的 PCM 缓冲，不重复创建 VoiceProcessing I/O。配置通知只把引擎身份值放入队列，避免为检查身份而延长退役引擎的生命周期。真正关麦、会话中断和 USB 结束仍停止录音。

启动诊断仅记录固定操作原因、原生阶段、错误域和数值，不记录设备名称、路径、错误详情或音频。自动化测试覆盖租约变更、旧通知、静音、真实中断及缓冲替换；模拟器成功仍需真实 iPad 验证采音与回声消除。

### 系统听写后的电脑声音恢复

系统键盘听写会中断应用音频。播放器在中断结束后清除旧的中断/失败状态与音频队列，收到新的电脑音频包后重新播放。若系统没有发出结束通知，用户收起本地键盘、重新开启“播放电脑声音”或返回前台也能发起一次恢复。键盘收起只在已有前台连接内恢复，不重连、不改变草稿或偏好。用户已经静音、断线或停止的播放不因此自动开启，健康播放不会因普通前台事件而重启。

每次播放的错误回调绑定当次输出代次；音频硬件保存回调快照，旧实例晚到的错误不能再次关闭新播放。恢复不使用定时重试，也不改变麦克风开关、音量、Windows 输出设备或回声消除设置。自动化验证覆盖通知/错误时序和后台前台播放，真实系统键盘听写的中断及恢复仍需签名安装后验收。
