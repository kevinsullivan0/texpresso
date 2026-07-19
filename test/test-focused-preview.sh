#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET="$SCRIPT_DIR/focused-preview/page2.tex"
MAIN="$SCRIPT_DIR/focused-preview/main.tex"
FIFO=$(mktemp -u /tmp/texpresso-focused-XXXXXX)
OUT=$(mktemp /tmp/texpresso-focused-out-XXXXXX)
ERR=$(mktemp /tmp/texpresso-focused-err-XXXXXX)
mkfifo "$FIFO"
trap 'rm -f "$FIFO" "$OUT" "$ERR"; kill "${PID:-}" 2>/dev/null || true' EXIT

SDL_VIDEODRIVER=dummy build/texpresso -stream \
  test/focused-preview/main.tex <"$FIFO" >"$OUT" 2>"$ERR" &
PID=$!
exec 3>"$FIFO"
for FILE in "$MAIN" "$SCRIPT_DIR/focused-preview/page1.tex" \
            "$TARGET" "$SCRIPT_DIR/focused-preview/page3.tex"; do
  CONTENT=$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' "$FILE" | \
    awk '{ if (NR > 1) printf "\\n"; printf "%s", $0 }')
  printf '(register "%s")\n(open "%s" "%s")\n' "$FILE" "$FILE" "$CONTENT" >&3
done
printf '(pause)\n(synctex-forward "%s" 0)\n(synctex-forward "%s" 0)\n' \
  "$SCRIPT_DIR/focused-preview/page1.tex" "$TARGET" >&3

# Manual pause must remain authoritative.
for _ in {1..20}; do
  grep -q 'preview-ready' "$OUT" && { echo 'FAIL: preview ignored pause' >&2; exit 1; }
  kill -0 "$PID" 2>/dev/null || { tail -20 "$ERR" >&2; echo 'FAIL: texpresso exited' >&2; exit 1; }
  sleep 0.02
done

printf '(resume)\n' >&3
for _ in {1..200}; do
  if grep -q '(preview-ready "page2.tex" 0 1)' "$OUT"; then
    grep -q '(preview-ready "page1.tex"' "$OUT" && {
      echo 'FAIL: replaced preview became ready' >&2
      exit 1
    }
    grep -q 'FOCUSED-PREVIEW-PAGE-THREE' "$OUT" && {
      echo 'FAIL: page three ran before focused suspension' >&2
      exit 1
    }
    printf '(next-page)\n' >&3
    for _ in {1..200}; do
      grep -q 'FOCUSED-PREVIEW-PAGE-THREE' "$OUT" && {
        echo 'PASS: focused preview'
        exit 0
      }
      kill -0 "$PID" 2>/dev/null || { tail -20 "$ERR" >&2; echo 'FAIL: texpresso exited' >&2; exit 1; }
      sleep 0.05
    done
    echo 'FAIL: navigation did not resume compilation' >&2
    exit 1
  fi
  kill -0 "$PID" 2>/dev/null || { tail -20 "$ERR" >&2; echo 'FAIL: texpresso exited' >&2; exit 1; }
  sleep 0.05
done

echo 'FAIL: preview-ready not received' >&2
exit 1
