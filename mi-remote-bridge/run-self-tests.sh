#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
OUTPUT="$SCRIPT_DIR/.build/mi-remote-self-test"

mkdir -p "${OUTPUT:h}"
swiftc \
  "$SCRIPT_DIR/Sources/MiRemoteBridge/ATVV/BridgeError.swift" \
  "$SCRIPT_DIR/Sources/MiRemoteBridge/ATVV/ADPCMDecoder.swift" \
  "$SCRIPT_DIR/Sources/MiRemoteBridge/ATVV/ATVVProtocol.swift" \
  "$SCRIPT_DIR/SelfTests/main.swift" \
  -o "$OUTPUT"
"$OUTPUT"

