#!/usr/bin/env bash
# Runs the full iPhone marketplace journey UI test against a throwaway local API.
# Hosted CI runs the focused UI tests; run this on a local Mac before merging iPhone
# changes or preparing a release. Usage: npm run ios:journey [-- <simulator-udid>]
set -euo pipefail

cd "$(dirname "$0")/.."
PORT=8936
STATE="work/ios-journey-state"
LOG="work/ios-journey-api.log"
RESULT="work/ios-journey.xcresult"

if ! xcodebuild -version >/dev/null 2>&1; then
  if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "Xcode is required (xcodebuild not found)." >&2
    exit 1
  fi
fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is in use; stop that process before running the journey test." >&2
  exit 1
fi

DEVICE_ID="${1:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for devices in d["devices"].values() for v in devices if v["name"].startswith("iPhone")))')}"

mkdir -p work
rm -rf "$STATE" "$RESULT"
npm run build >/dev/null
npx wrangler d1 migrations apply DB --local --persist-to "$STATE" >/dev/null
npx wrangler d1 execute DB --local --persist-to "$STATE" --file seeds/demo.sql >/dev/null
npx wrangler dev --ip 127.0.0.1 --port "$PORT" --persist-to "$STATE" --var APP_ENV:development >"$LOG" 2>&1 &
API_PID=$!
cleanup() {
  kill "$API_PID" 2>/dev/null || true
  xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in {1..40}; do
  curl --fail --silent "http://127.0.0.1:$PORT/api/session" >/dev/null && break
  sleep 1
done
curl --fail --silent "http://127.0.0.1:$PORT/api/session" >/dev/null || {
  cat "$LOG"
  exit 1
}

TEST_RUNNER_CUSE_FULL_JOURNEY=1 xcodebuild -project ios/CuseSublets.xcodeproj -scheme CuseSublets \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" -derivedDataPath work/ios-build \
  -resultBundlePath "$RESULT" \
  -only-testing:CuseSubletsUITests/MarketplaceTests/testFullMarketplaceJourney \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
echo "Full journey passed. Result bundle: $RESULT"
