#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/MiRemoteBridge.app"
DRIVER="/Library/Audio/Plug-Ins/HAL/MiRemoteVoice.driver"

if [[ ! -d "$DRIVER" ]]; then
  print "缺少 MiRemoteV 2ch 驱动：$DRIVER"
  print "请先安装驱动，再启动米遥桥。"
  read -k 1 "?按任意键关闭…"
  exit 2
fi

if [[ ! -d "$APP" ]]; then
  print "找不到已安装应用：$APP"
  print "请先运行 mi-remote-bridge/install-app.sh 安装应用。"
  read -k 1 "?按任意键关闭…"
  exit 3
fi

open "$APP"
print "米遥桥已启动。菜单栏出现 🎤 后即可使用。"

