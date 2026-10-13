#!/usr/bin/env bash
# Run every tests/*_test.sh and tests/*_test.py; exit non-zero if any fails.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
ran=0
shopt -s nullglob
for t in "$here"/*_test.sh "$here"/*_test.py; do
  ran=$((ran + 1))
  name="$(basename "$t")"
  echo "== $name"
  case "$t" in
    *.sh) bash "$t" ;;
    *.py) python3 "$t" ;;
  esac
  rc=$?
  if [ "$rc" -ne 0 ]; then
    failed+=("$name (exit $rc)")
  fi
done
echo
if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED ${#failed[@]} of $ran test files:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo "OK: $ran test files passed"
