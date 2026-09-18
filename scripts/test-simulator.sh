#!/usr/bin/env bash
# Roda a suíte no iOS Simulator com o servidor simulado, incluindo a integração da ponte numa
# WKWebView real (SimulatorBridgeTests). O servidor roda no Mac; o simulador enxerga o 127.0.0.1
# dele.
#
# Dois modos:
#   scripts/test-simulator.sh
#       xcodebuild test no simulador de DESTINATION (padrão: iPhone 16), no conjunto de
#       simuladores padrão do Xcode. O xcodebuild repassa TEST_RUNNER_<VAR> ao teste como <VAR>.
#   SIM_SET=/pasta/do/conjunto SIM_UDID=<udid> scripts/test-simulator.sh
#       build-for-testing + `simctl --set … spawn … xctest` com o bundle de testes, num conjunto
#       de simuladores próprio (simctl repassa SIMCTL_CHILD_<VAR>). Serve quando o conjunto padrão
#       está num disco a que o CoreSimulator não tem acesso. Crie o aparelho antes:
#         xcrun simctl --set "$SIM_SET" create "iPhone 16" com.apple.CoreSimulator.SimDeviceType.iPhone-16 <runtime>
#         xcrun simctl --set "$SIM_SET" boot <udid>
#
# Fora do monorepo: BFOCUS_CONFORMANCE_DIR=/caminho/conformance.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFORMANCE="${BFOCUS_CONFORMANCE_DIR:-../conformance}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
LOG="$(mktemp -t bfocus-mock)"

node "$CONFORMANCE/mock-server.mjs" 0 >"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -f "$LOG"' EXIT

URL=""
for _ in $(seq 1 100); do
  URL="$(grep -o 'http://127.0.0.1:[0-9]*' "$LOG" | head -1 || true)"
  [ -n "$URL" ] && break
  sleep 0.1
done
[ -n "$URL" ] || { echo "mock-server não subiu:"; cat "$LOG"; exit 1; }
echo "mock-server em $URL"

if [ -n "${SIM_SET:-}" ]; then
  : "${SIM_UDID:?defina SIM_UDID (xcrun simctl --set \"\$SIM_SET\" list devices)}"
  DERIVED="$(pwd)/.build/xcode-simulator"
  xcodebuild build-for-testing \
    -scheme BFocusWidget-Package \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO -quiet
  PRODUCTS="$DERIVED/Build/Products/Debug-iphonesimulator"
  PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
  SIMCTL_CHILD_BFOCUS_MOCK_URL="$URL" \
  SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$PRODUCTS:$PLATFORM/Developer/Library/Frameworks" \
  SIMCTL_CHILD_DYLD_LIBRARY_PATH="$PRODUCTS:$PLATFORM/Developer/usr/lib" \
    xcrun simctl --set "$SIM_SET" spawn "$SIM_UDID" \
      "$PLATFORM/Developer/Library/Xcode/Agents/xctest" "$PRODUCTS/BFocusWidgetTests.xctest"
else
  TEST_RUNNER_BFOCUS_MOCK_URL="$URL" xcodebuild test \
    -scheme BFocusWidget-Package \
    -destination "$DESTINATION" \
    CODE_SIGNING_ALLOWED=NO \
    "$@"
fi
