#!/usr/bin/env bash
# CI smoke test on a simulator: launch, pair through the sextant:// link, download a song from a
# stand-in Kılavuz, then check that it is served from the phone with the computer gone.
set -euo pipefail
APP="$1"; UDID="$2"; OUT="${3:-smoke}"
mkdir -p "$OUT"
fail() { echo "::error::smoke: $1"; xcrun simctl io "$UDID" screenshot "$OUT/fail.png" >/dev/null 2>&1 || true; exit 1; }
check() { python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
python3 scripts/fake_kilavuz.py 8765 2>"$OUT/kilavuz-stub.log" & STUB=$!
trap 'kill $STUB 2>/dev/null || true' EXIT
xcrun simctl launch "$UDID" com.batuhxn.sextant >/dev/null

# The app's server binds the loopback interface the simulator shares with this Mac.
S=""
for i in $(seq 1 40); do
  for p in $(seq 47831 47840); do
    if curl -fsS -m 1 "http://127.0.0.1:$p/api/app/state" >/dev/null 2>&1; then S="http://127.0.0.1:$p"; break 2; fi
  done
  sleep 1
done
[ -n "$S" ] || fail "local server did not start"
echo "local server: $S"
# (no pipe into grep -q: with pipefail, curl's SIGPIPE would fail the check)
curl -fsS -o "$OUT/index.html" "$S/" || fail "web page not served"
grep -q "Sextant" "$OUT/index.html" || fail "web page content unexpected ($(head -c 200 "$OUT/index.html"))"
sleep 3; xcrun simctl io "$UDID" screenshot "$OUT/1-library-unpaired.png" >/dev/null

curl -fsS "$S/api/app/state" | check "d['paired'] is False" || fail "should start unpaired"
code=$(curl -s -o /dev/null -w '%{http_code}' "$S/api/find?q=x"); [ "$code" = 503 ] || fail "unpaired proxy should be 503, got $code"

# Pair. (The QR code's sextant:// link goes through the same AppRouter.pair; iOS asks "Open in Sextant?"
# for it, which nobody can answer in CI. The link parsing itself is covered by the unit tests.)
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"url":"127.0.0.1","token":"wrong"}' "$S/api/app/pair")
[ "$code" = 400 ] || fail "a wrong key must be refused, got $code"
curl -fsS -X POST -H 'Content-Type: application/json' -d '{"url":"127.0.0.1:8765","token":"testkey"}' "$S/api/app/pair" | check "d['ok']" || fail "pairing"
curl -fsS "$S/api/app/state" | check "d['paired'] and d['online'] and d['server']=='http://127.0.0.1:8765'" || fail "pairing state: $(curl -sS "$S/api/app/state")"
echo "paired: OK"
curl -fsS "$S/api/songs" | check "d[0]['id']=='test-song' and d[0]['offline'] is False" || fail "remote song list"
curl -fsS "$S/api/find?q=x" | check "d['mode']=='catalog'" || fail "proxy to the computer"

curl -fsS -X POST "$S/api/app/download/test-song" | check "d['ok']" || fail "download"
curl -fsS "$S/api/songs" | check "d[0]['offline'] is True" || fail "song not marked as on the phone"
sleep 2; xcrun simctl io "$UDID" screenshot "$OUT/2-library-paired.png" >/dev/null
echo "download: OK"

# Computer gone: list, song data and audio (with byte ranges) come from the phone.
kill $STUB; wait $STUB 2>/dev/null || true
sleep 6  # online state is cached for 5 s
curl -fsS "$S/api/app/state" | check "d['online'] is False" || fail "should notice the computer is gone"
curl -fsS "$S/api/songs" | check "len(d)==1 and d[0]['remote'] is False and d[0]['offline'] is True" || fail "offline list"
curl -fsS "$S/api/songs/test-song" | check "d.get('offline_copy') and 'analysis' in d and len(d['analysis']['chords'])>10" || fail "offline song data"
hdr=$(curl -sS -D - -o "$OUT/part.bin" -H "Range: bytes=100-199" "$S/media/test-song/full.mp3")
echo "$hdr" | grep -q "206" || fail "range request not 206"
echo "$hdr" | grep -qi "Content-Range: bytes 100-199/300000" || fail "content-range"
[ "$(wc -c < "$OUT/part.bin" | tr -d ' ')" = 100 ] || fail "range length"
code=$(curl -s -o /dev/null -w '%{http_code}' "$S/api/find?q=x"); [ "$code" = 503 ] || fail "offline proxy should be 503, got $code"
echo "offline: OK"

curl -fsS -X DELETE "$S/api/app/download/test-song" | check "d['ok']" || fail "remove"
curl -fsS "$S/api/songs" | check "len(d)==0" || fail "song should be gone from the phone"
echo "SMOKE: PASS"
