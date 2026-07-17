# MiRemoteVoice / 米遥桥

把小米蓝牙语音遥控器 2 Pro 变成 macOS 上的 Voice Coding 麦克风：

- 短按语音键：调用 MacBook 内置麦克风。
- 长按语音键：调用遥控器的 ATVV 蓝牙麦克风。
- 向豆包输入法暴露可识别的 `MiRemoteV 2ch` 输入设备。

## 当前版本

`v1.0.0-beta.1` 是在真实 Xiaomi Bluetooth Voice Remote 2 Pro、Apple
Silicon Mac 和豆包输入法上验证通过的首个稳定 beta。

## 启动与退出

已安装的应用位于：

```text
~/Applications/MiRemoteBridge.app
```

双击应用即可启动。它是菜单栏应用，不显示 Dock 图标；点击菜单栏的麦克风
图标可查看状态或退出。退出后再次双击即可重新启动。

## 目录

- `mi-remote-bridge/`：Swift 菜单栏应用、BLE/ATVV 解码和音频路由。
- `mi-remote-voice-driver-poc/`：基于 BlackHole 2ch 的 `MiRemoteV 2ch`
  HAL 驱动验证构建及安装脚本。

## 构建应用

```bash
cd mi-remote-bridge
./package-app.sh
./install-app.sh
open ~/Applications/MiRemoteBridge.app
```

应用采用稳定的本地 ad-hoc designated requirement，重编译后仍可复用已经授予的
辅助功能和输入监控权限。

## 驱动说明

当前驱动构建脚本从本机已安装的 `BlackHole2ch.driver` 复制并生成独立的
`MiRemoteVoice.driver`，不修改原 BlackHole。它把实际 Audio Device 的 transport
标记为 USB，使豆包能够列出该输入设备。

驱动来自 BlackHole 0.4.1，遵循 GNU GPL v3；应用本身遵循 MIT License。详见
`THIRD_PARTY_NOTICES.md`。

