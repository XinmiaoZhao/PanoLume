#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${ROOT_DIR}/scripts/Private/environment.sh" ]]; then
  source "${ROOT_DIR}/scripts/Private/environment.sh"
fi
OUT_DIR="${PANOLUME_METAL_OUTPUT_DIR:-${ROOT_DIR}/build/native}"
SRC="${ROOT_DIR}/native/metal_renderer/PanoLumeMetalRenderer.mm"
OUT="${OUT_DIR}/libpanolume_metal.dylib"

mkdir -p "${OUT_DIR}"
xcrun clang++ \
  -std=c++17 \
  -fobjc-arc \
  -dynamiclib \
  -Wl,-install_name,@rpath/libpanolume_metal.dylib \
  -framework Foundation \
  -framework Metal \
  -o "${OUT}" \
  "${SRC}"

echo "${OUT}"
