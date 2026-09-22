#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${MYPTGUI_METAL_OUTPUT_DIR:-${ROOT_DIR}/build/native}"
SRC="${ROOT_DIR}/native/metal_renderer/MyPTGuiMetalRenderer.mm"
OUT="${OUT_DIR}/libmyptgui_metal.dylib"

mkdir -p "${OUT_DIR}"
xcrun clang++ \
  -std=c++17 \
  -fobjc-arc \
  -dynamiclib \
  -Wl,-install_name,@rpath/libmyptgui_metal.dylib \
  -framework Foundation \
  -framework Metal \
  -o "${OUT}" \
  "${SRC}"

echo "${OUT}"
