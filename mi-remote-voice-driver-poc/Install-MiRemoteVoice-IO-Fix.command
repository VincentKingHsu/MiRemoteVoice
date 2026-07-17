#!/bin/zsh
set -e

echo "即将安装 MiRemoteVoice I/O 修复版。"
echo "原 BlackHole2ch.driver 不会被修改。"
echo

sudo /bin/zsh -c \
  '/tmp/mi-remote-voice-driver-device-usb-1A0861D7/uninstall-poc.sh && /tmp/mi-remote-voice-driver-device-usb-1A0861D7/install-poc.sh'

echo
echo "安装完成。可以关闭此窗口，然后回到 Codex 告诉我“完成”。"
read -k 1 "?按任意键关闭…"
