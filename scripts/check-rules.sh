#!/usr/bin/env bash
#
# Lint and unit-test the PrometheusRule CRs.
#
# promtool cannot read a PrometheusRule CR directly — it expects a bare rule file
# (top-level `groups:`). This extracts .spec from each CR into a temp dir, then
# runs promtool from the official image so no local install is needed.
#
# Usage: ./check-rules.sh            # lint all rule CRs, then run unit tests
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
RULES_DIR=kubernetes/monitoring/rules
TESTS_DIR=tests/rules
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# mktemp -d defaults to 0700, but prom/prometheus:latest runs as uid 65534
# (nobody) and can't even traverse a 0700 dir it doesn't own — make it
# world-readable/traversable so the container can see the mounted files.
chmod 755 "$WORK"

RULE_FILES=()
for f in "$RULES_DIR"/*.yml; do
  python3 - "$f" "$WORK/$(basename "$f")" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    cr = yaml.safe_load(fh)
with open(dst, "w") as fh:
    yaml.safe_dump({"groups": cr["spec"]["groups"]}, fh, sort_keys=False)
PY
  echo "extracted $(basename "$f")"
  RULE_FILES+=("$(basename "$f")")
done

TEST_FILES=()
for t in "$TESTS_DIR"/*_test.yml; do
  [ -e "$t" ] || continue
  cp "$t" "$WORK/"
  TEST_FILES+=("$(basename "$t")")
done

# Fail loudly instead of silently reporting green: a missing/renamed tests dir
# would otherwise make the "for t in ..." loop below iterate zero times and
# the whole script would exit 0 having run no unit tests at all.
[ ${#TEST_FILES[@]} -gt 0 ] || {
  echo "ERROR: no unit tests found in $TESTS_DIR" >&2
  exit 1
}

# Pass an explicit file list rather than a glob: a glob here is evaluated by
# this script's shell against the repo root (no *.yml matches there), so it
# would reach docker unexpanded and promtool would try to open the literal
# string "./*.yml" — it does not glob-expand its own arguments.
docker run --rm -v "$WORK:/work" -w /work --entrypoint promtool \
  prom/prometheus:latest check rules "${RULE_FILES[@]}"

for t in "${TEST_FILES[@]}"; do
  echo "running unit tests: $t"
  docker run --rm -v "$WORK:/work" -w /work --entrypoint promtool \
    prom/prometheus:latest test rules "$t"
done
