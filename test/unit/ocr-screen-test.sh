#!/bin/bash
# The harnesses read the console with tesseract. The install's last screen
# puts "Reboot Now" on a focused button, dark text on a light bar, which the
# plain negated image reads as "Reboot Nou": the harness then never sees the
# install finish and waits out its timeout.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCREEN="$ROOT/test/unit/fixtures/install-finished-screen.png"

for tool in magick tesseract; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool is not installed"
    exit 0
  fi
done

RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT
screendump() { cp "$SCREEN" "$1"; }

for harness in bin/omarchy-iso-test test/integration.d/base-test.sh; do
  eval "$(sed -n '/^ocr_screen() {$/,/^}$/p' "$ROOT/$harness")"
  text=$(ocr_screen)
  if ! grep -qi "Reboot Now" <<<"$text"; then
    printf '%s read the finished install as:\n%s\n' "$harness" "$text" >&2
    exit 1
  fi
done
echo "ok - both harnesses read the Reboot Now button on the finished install"
