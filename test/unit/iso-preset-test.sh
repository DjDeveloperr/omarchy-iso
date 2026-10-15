#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The installer's preset fields, taken from the configurator itself, with the
# region lookup pointed at test profiles.
eval "$(sed -n '/^preset_install_fields() {$/,/^}$/p' "$ROOT/configs/airootfs/root/configurator")"
mkdir -p "$work/regions/cn" "$work/iso/orchestrator"
printf 'Asia/Shanghai\nAsia/Urumqi\n' >"$work/regions/cn/timezones"
cp "$ROOT/configs/airootfs/usr/share/omarchy-iso/orchestrator/region.py" "$work/iso/orchestrator/"
: >"$work/iso/orchestrator/__init__.py"
sed -i "s|^REGIONS_DIR = .*|REGIONS_DIR = Path(\"$work/regions\")|" "$work/iso/orchestrator/region.py"
ORCHESTRATOR_DIR="$work/iso"
config() { printf '{"input_xkb_layout": "",%s\n "mode": "protected"}' "$(preset_install_fields "$1")"; }

ISO_PRESET="$work/absent.json"
[[ $(config Asia/Shanghai) == $'{"input_xkb_layout": "",\n "mode": "protected"}' ]] || { echo "a global ISO's install config changed" >&2; exit 1; }
echo "ok - a global ISO writes exactly the install config it always did"

ISO_PRESET="$ROOT/configs/presets/china.json"
preset_language=$(jq -r .language "$ISO_PRESET")
preset_region=$(jq -r .region "$ISO_PRESET")
for case in "Asia/Shanghai cn" "UTC cn" "Europe/Copenhagen cn" "Asia/Hong_Kong global" "Hongkong global" "Asia/Macau global" "Asia/Macao global" "Asia/Taipei global" "ROC global"; do
  read -r timezone expected <<<"$case"
  got=$(config "$timezone" | jq -r '"\(.language) \(.region)"')
  [[ $got == "zh-CN $expected" ]] || { echo "China preset with $timezone gave '$got', expected 'zh-CN $expected'" >&2; exit 1; }
done
echo "ok - a China ISO installs zh-CN with China's mirrors, except where the chosen timezone is Hong Kong, Macau or Taiwan"

for key in keyboard timezone language region; do
  [[ -n $(jq -r ".$key // empty" "$ISO_PRESET") ]] || { echo "the China preset lacks $key" >&2; exit 1; }
done
[[ $(jq -r .keyboard "$ISO_PRESET") == "Chinese (Simplified, Pinyin)" ]] || { echo "the China preset preselects the Pinyin keyboard row" >&2; exit 1; }
echo "ok - the China preset names the Pinyin keyboard, a timezone, a language and a region"
