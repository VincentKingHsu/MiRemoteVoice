# MiRemoteVoice / 米遥桥

把小米蓝牙语音遥控器 2 Pro 变成 macOS 上的 Voice Coding 麦克风：

- 短按语音键：调用 MacBook 内置麦克风。
- 长按语音键：调用遥控器的 ATVV 蓝牙麦克风。
- 向豆包输入法暴露可识别的 `MiRemoteV 2ch` 输入设备。

## 当前版本：v1.0.0-beta.2

这是 **Beta V2 源码预览版**。上一版是 `v1.0.0-beta.1`。

本次 Release 暂时只发布源码，没有预编译 App、PKG、DMG 或一键安装包。项目已在
Xiaomi Bluetooth Voice Remote 2 Pro、Apple Silicon Mac 和豆包输入法上完成连续长按、
短按和音源往返切换验证。有动手能力的用户可以按下文从源码安装，也可以让能够执行
终端命令的 AI Agent 协助安装。

### Beta V2 更新

- 修复 ATVV `AUDIO_SYNC` 在 `AUDIO_START` 前后到达时的解码状态问题。
- 增加协议自测，覆盖连续音频流和同步状态隔离。
- 增加菜单栏状态、登录时自动启动、日志与调试录音控制。
- 日志和调试录音默认关闭，可查看占用、打开目录或清空。
- 改进长按语音键的 Option 按键行为和遥控器音频诊断。

## 使用前准备

目前的源码安装方式需要：

1. macOS 12 或更高版本；当前主要在 Apple Silicon Mac 上验证。
2. Xcode Command Line Tools：`xcode-select --install`。
3. 已安装兼容的 BlackHole 2ch。当前脚本从本机
   `/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver` 生成独立的
   `MiRemoteVoice.driver`，不会修改原 BlackHole。
4. 安装 HAL 驱动时需要管理员密码。
5. 首次启动后，由用户手动授予蓝牙、麦克风、辅助功能和输入监控权限。

> AI Agent 可以执行检查、构建和安装命令，但不能代替用户输入管理员密码，也不能绕过
> macOS 的隐私授权界面。

## 从源码安装

### 有动手能力的用户

```bash
git clone --branch v1.0.0-beta.2 --depth 1 \
  https://github.com/VincentKingHsu/MiRemoteVoice.git
cd MiRemoteVoice

# 协议回归自测：应输出三行 PASS
./mi-remote-bridge/run-self-tests.sh

# 生成并安装 MiRemoteVoice HAL 驱动
./mi-remote-voice-driver-poc/build-poc.sh
sudo ./mi-remote-voice-driver-poc/install-poc.sh

# 构建并安装菜单栏 App
./mi-remote-bridge/package-app.sh
./mi-remote-bridge/install-app.sh

# 启动
./启动米遥桥.command
```

如果驱动构建阶段提示缺少 `BlackHole2ch.driver`，请先安装兼容的 BlackHole 2ch，
然后重新运行驱动构建命令。

### 让 AI Agent 协助安装

可以把下面这段任务直接交给能够操作终端的 Agent：

```text
请在我的 Mac 上从源码安装 MiRemoteVoice v1.0.0-beta.2：
1. 检查 macOS、Xcode Command Line Tools，以及
   /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver。
2. 克隆 https://github.com/VincentKingHsu/MiRemoteVoice.git 的
   v1.0.0-beta.2 tag。
3. 运行 mi-remote-bridge/run-self-tests.sh，必须全部 PASS。
4. 运行 mi-remote-voice-driver-poc/build-poc.sh。
5. 在我确认后，用管理员权限运行 install-poc.sh。
6. 运行 mi-remote-bridge/package-app.sh 和 install-app.sh。
7. 启动 MiRemoteBridge.app，逐项告诉我需要手动授予的 macOS 权限。
不要绕过 Gatekeeper，不要替我修改系统安全策略。
```

安装成功的基本判据：

- 自测输出三行 `PASS`。
- 驱动构建输出 `Built: .../MiRemoteVoice.driver`。
- App 构建输出 `Built: .../MiRemoteBridge.app`。
- “音频 MIDI 设置”或音频输入设备中出现 `MiRemoteV 2ch`。
- 菜单栏出现米遥桥状态图标。

## 启动与退出

已安装的应用位于：

```text
~/Applications/MiRemoteBridge.app
```

双击应用或运行 `启动米遥桥.command` 即可启动。它是菜单栏应用，不显示 Dock 图标；
点击菜单栏的麦克风图标可查看状态或退出。菜单中的“登录时自动启动”可以控制登录后
自动启动，不需要管理员权限。

## 日志与调试录音

默认不写日志，也不保存录音。菜单中可以分别开启，并提供占用大小、刷新、打开文件夹
和清空功能。

- 日志：`~/Library/Logs/MiRemoteBridge/MiRemoteBridge.log`
- 录音：`~/Library/Application Support/MiRemoteBridge/Recordings/`

日志最大为 5 MB，到达上限后自动截断。调试录音会同时保存 16 kHz WAV 和原始 ATVV
数据，仅在用户手动开启后生效。

## 当前限制

- 这是源码预览版，App 和驱动目前使用本地 ad-hoc 签名，尚未提供签名和 Apple 公证的安装包。
- 驱动目前是基于本机已安装 BlackHole 2ch 的验证构建，不是独立的源码构建工程。
- 当前明确验证的硬件是 Xiaomi Bluetooth Voice Remote 2 Pro；其他型号和固件不保证兼容。
- macOS 隐私权限必须由用户本人手动授予。

## 下一步计划

等维护者有时间后，会逐步推进：

- 将 MiRemoteVoice 驱动改为可重复、可审计的源码构建。
- 完善 GPL v3 对应源码和许可证分发。
- 提供 App、驱动和登录启动项的统一卸载方法。
- 增加 Developer ID 签名、Hardened Runtime 和 Apple 公证。
- 评估统一 PKG、DMG 和 `.command` 安装体验。
- 增加 GitHub Actions、更多自动测试和干净 Mac 安装验证。

当前请把 `v1.0.0-beta.2` 视为供开发者、动手能力较强的用户和 AI Agent 使用的源码
预览版。正式一键安装包会在后续版本中提供，感谢耐心等待。

## 目录

- `mi-remote-bridge/`：Swift 菜单栏应用、BLE/ATVV 解码和音频路由。
- `mi-remote-voice-driver-poc/`：生成 `MiRemoteV 2ch` HAL 驱动的验证构建及安装脚本。

## 许可证

应用源码遵循 [MIT License](LICENSE)。当前驱动来自 BlackHole 0.4.1，遵循 GNU GPL v3。
第三方项目、许可证和归属信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
