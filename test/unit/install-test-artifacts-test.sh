#!/bin/bash
#
# The install test hands each architecture's ISO from the build job to its
# install jobs as an artifact. "Re-run failed jobs" starts a new attempt
# without the build jobs that passed, and their install jobs then fetch the
# ISO an earlier attempt uploaded (download-artifact reads the run's earlier
# attempts too). So the ISO's name must not carry the attempt, and a build
# that does run again replaces its ISO, since a name is unique in a run.
# The test results stay per attempt: the comment workflow reads
# install-test-<run>-<attempt>*.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORKFLOW="$ROOT/.github/workflows/install-test.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The step that names this artifact: from its "- " line to the next line
# indented no deeper.
step_of() {
  awk -v name="$1" '
    match($0, /^ *- /) { if (keep) exit; indent = RLENGTH - 2; block = "" }
    keep && $0 !~ /^ *$/ { match($0, /^ */); if (RLENGTH <= indent) exit }
    { block = block $0 "\n" }
    index($0, "name: " name) { keep = 1 }
    END { if (keep) printf "%s", block }
  ' "$WORKFLOW"
}

isos=$(sed -nE 's/^ *name: (iso-.*)$/\1/p' "$WORKFLOW")
upload=$(grep -F '${{ matrix.arch }}' <<<"$isos") || fail "the build job uploads no per-architecture ISO artifact"
[[ $(grep -c "" <<<"$upload") == 1 ]] || fail "more than one ISO upload: $upload"
grep -F 'run_attempt' <<<"$isos" && fail "an ISO artifact name carries the attempt, which a partial re-run's install jobs never find"
for arch in x86_64 aarch64; do
  want=${upload//'${{ matrix.arch }}'/$arch}
  grep -Fxq "$want" <<<"$isos" || fail "no install job fetches $want, the ISO the $arch build uploads"
done
step_of "$upload" | grep -Eq '^ *overwrite: true$' || fail "a build that runs again cannot replace its ISO"

# Every test-result artifact keeps the run and the attempt, as the comment
# workflow reads them.
results=$(sed -nE 's/^ *name: (install-test-.*)$/\1/p' "$WORKFLOW")
[[ $(grep -c "" <<<"$results") == 2 ]] || fail "expected the x86_64 and aarch64 result artifacts, found: $results"
while read -r name; do
  [[ $name == *'${{ github.run_id }}-${{ github.run_attempt }}-'* ]] || fail "result artifact $name does not carry its run and attempt"
done <<<"$results"
grep -Fq -- '-p "install-test-$RUN_ID-$ATTEMPT*"' "$ROOT/.github/workflows/install-test-comment.yml" \
  || fail "the comment workflow no longer reads install-test-<run>-<attempt>*"
echo "install test artifact names passed"
