#!/bin/bash
#
# The x86_64 install job's "Report times" step summarises the variant's
# initial install: its install phases, first boot and everyday boot, which
# base-test.sh saves in that install's base folder. A job can leave more than
# one base folder behind — pxe-test.sh forces BIOS, so a job running every
# scenario also gets a -bios one with no install numbers in it. This runs the
# step's own script against fake test-runs trees and checks it reports from
# the install's folder.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORKFLOW="$ROOT/.github/workflows/install-test.yml"

# The first "Report times" step (the x86_64 job's) as a script, with the two
# expressions GitHub would substitute filled in.
step_script() {
  awk '
    /^ *- name: Report times$/ && !found { found = 1; next }
    found && !indent && /^ *run: \|$/ { match($0, /^ */); indent = RLENGTH; next }
    indent {
      if ($0 !~ /^ *$/) { match($0, /^ */); if (RLENGTH <= indent) exit }
      print
    }
  ' "$WORKFLOW" | sed -e 's/\${{ matrix\.variant }}/$VARIANT/g' -e "s/\${{ inputs\.channel || 'stable' }}/stable/g"
}

script=$(step_script)
if [[ -z $script ]]; then
  echo "FAIL: no Report times step in ${WORKFLOW#"$ROOT/"}"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A base folder as a finished install leaves it.
install_dir() {
  mkdir -p "$1/runs/20261022-120000-boot"
  echo '{"started_at": 0, "finished_at": 312.4, "phases": [{"name": "image write", "elapsed": 41.0}]}' \
    >"$1/omarchy-install-timing.json"
  echo "Startup finished in 1.0s (firmware) + 2.0s (loader) + 3.0s (kernel) + 4.0s (userspace) = 10.0s" \
    >"$1/first-boot-systemd-analyze.txt"
  echo "Startup finished in 1.0s (firmware) + 2.0s (loader) + 2.5s (kernel) + 3.5s (userspace) = 9.0s" \
    >"$1/runs/20261022-120000-boot/systemd-analyze.txt"
  echo '{"system_state": "running"}' >"$1/runs/20261022-120000-boot/boot-timing.json"
}

# A folder pxe-test.sh leaves: its own run, no install numbers.
pxe_dir() {
  mkdir -p "$1/runs/20261022-130000-pxe"
  : >"$1/runs/20261022-130000-pxe/serial.log"
}

fails=0
report() { # desc, variant, options, variant env, install folder suffix, [pxe folder suffix]
  local desc=$1 dir="$work/$2"
  mkdir -p "$dir/test-runs"
  install_dir "$dir/test-runs/omarchy-9.9.9-integration$5"
  [[ -z ${6:-} ]] || pxe_dir "$dir/test-runs/omarchy-9.9.9-integration$6"
  local summary
  summary=$(cd "$dir" && VARIANT=$2 OPTIONS=$3 VARIANT_ENV=$4 GITHUB_STEP_SUMMARY="$dir/summary" \
    bash -euo pipefail -c "$script" >/dev/null 2>&1; cat "$dir/summary" 2>/dev/null || true)
  local want
  for want in "**Install:** 312.4 s across 1 phases" "| image write | 41 |" \
    "**First boot:** Startup finished in 2.0s (loader) + 3.0s (kernel) + 4.0s (userspace)" \
    "**Everyday boot:** Startup finished in 2.0s (loader) + 2.5s (kernel) + 3.5s (userspace)" "System state: running"; do
    if [[ $summary != *"$want"* ]]; then
      echo "FAIL: $desc: the summary lacks '$want'"; fails=1; return
    fi
  done
  echo "ok: $desc"
}

report "default reports its install, not the PXE run's -bios folder" default "" "" "" "-bios"
report "encrypted reports its install, not the PXE run's -bios-encrypted folder" \
  encrypted "" "OMARCHY_INTEGRATION_ENCRYPT=true" "-encrypted" "-bios-encrypted"
# --bios: the PXE run, if any, shares the install's own folder.
report "bios reports its own -bios-bios folder" bios "--bios" "" "-bios-bios"
report "a keyboard variant reports its -kb folder" encrypted-kb-uk "" \
  "OMARCHY_INTEGRATION_ENCRYPT=true OMARCHY_INTEGRATION_KB_LAYOUT=uk" "-encrypted-kb-uk-kbuk" "-bios-encrypted-kb-uk-kbuk"

((fails == 0))
