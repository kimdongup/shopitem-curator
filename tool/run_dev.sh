#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: bash tool/run_dev.sh [--device chrome|macos] [--web-port PORT] [--check]"
  echo "Starts and verifies the local proxy before launching Flutter."
}

DEVICE="macos"
WEB_PORT="${CURATOR_WEB_PORT:-3000}"
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      DEVICE="$2"
      shift 2
      ;;
    --device=*)
      DEVICE="${1#*=}"
      shift
      ;;
    --web-port)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      WEB_PORT="$2"
      shift 2
      ;;
    --web-port=*)
      WEB_PORT="${1#*=}"
      shift
      ;;
    --check)
      CHECK_ONLY=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "$DEVICE" != "chrome" && "$DEVICE" != "macos" ]]; then
  echo "Unsupported device: $DEVICE (expected chrome or macos)." >&2
  exit 64
fi
if [[ ! "$WEB_PORT" =~ ^[0-9]+$ ]] || ((WEB_PORT < 1 || WEB_PORT > 65535)); then
  echo "--web-port must be between 1 and 65535." >&2
  exit 64
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROXY_PORT="${CURATOR_PROXY_PORT:-8787}"
if [[ ! "$PROXY_PORT" =~ ^[0-9]+$ ]] ||
    ((PROXY_PORT < 1 || PROXY_PORT > 65535)); then
  echo "CURATOR_PROXY_PORT must be between 1 and 65535." >&2
  exit 64
fi

FLUTTER_BIN="${CURATOR_FLUTTER_BIN:-}"
DART_BIN="${CURATOR_DART_BIN:-}"
if [[ "$CHECK_ONLY" != "true" && -z "$FLUTTER_BIN" ]]; then
  FLUTTER_BIN="$(command -v flutter || true)"
fi
if [[ -z "$DART_BIN" ]]; then
  DART_BIN="$(command -v dart || true)"
fi
if [[ "$CHECK_ONLY" != "true" &&
      ( -z "$FLUTTER_BIN" || ! -x "$FLUTTER_BIN" ) ]]; then
  echo "Flutter was not found. Set CURATOR_FLUTTER_BIN or update PATH." >&2
  exit 69
fi
if [[ -z "$DART_BIN" || ! -x "$DART_BIN" ]]; then
  echo "Dart was not found. Set CURATOR_DART_BIN or update PATH." >&2
  exit 69
fi

BASE_URL="http://127.0.0.1:$PROXY_PORT"
HEALTH_URL="$BASE_URL/health"
READINESS_URL="$BASE_URL/ready"
TEMP_DIR="$(mktemp -d)"
RESPONSE_FILE="$TEMP_DIR/response.json"
PROXY_PID=""
APP_PID=""

terminate_pid() {
  local pid="$1"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    return
  fi
  kill "$pid" 2>/dev/null || true
  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return
    fi
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  terminate_pid "$APP_PID"
  terminate_pid "$PROXY_PID"
  /bin/rm -f -- "$RESPONSE_FILE"
  rmdir "$TEMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

request_status() {
  : >"$RESPONSE_FILE"
  /usr/bin/curl \
    --silent \
    --show-error \
    --output "$RESPONSE_FILE" \
    --write-out '%{http_code}' \
    --max-time 1 \
    "$1" 2>/dev/null || true
}

is_curator_health_body() {
  /usr/bin/grep -q '"service":"shopitem-curator-proxy"' "$RESPONSE_FILE" &&
    /usr/bin/grep -q '"api_version":"v1"' "$RESPONSE_FILE"
}

cd "$PROJECT_DIR"

health_status="$(request_status "$HEALTH_URL")"
if [[ "$health_status" == "200" ]]; then
  if ! is_curator_health_body; then
    echo "Port $PROXY_PORT belongs to an incompatible HTTP service." >&2
    exit 70
  fi
  echo "A Curator proxy is already listening on 127.0.0.1:$PROXY_PORT." >&2
  echo "The runner cannot verify its auth/CORS contract, so it will not reuse it." >&2
  echo "Stop that proxy, or start Flutter directly if you intentionally own it." >&2
  exit 70
elif [[ "$health_status" != "000" ]]; then
  echo "Port $PROXY_PORT responded with HTTP $health_status but is not a healthy Curator proxy." >&2
  exit 70
else
  echo "Starting the Curator proxy on 127.0.0.1:$PROXY_PORT..."
  /usr/bin/env \
    -u CURATOR_PROXY_TOKEN \
    -u CURATOR_TRUSTED_AUTH_HEADER \
    -u CURATOR_CORS_ALLOW_ORIGIN \
    CURATOR_PROXY_HOST=127.0.0.1 \
    CURATOR_PROXY_PORT="$PROXY_PORT" \
    CURATOR_ALLOW_UNAUTHENTICATED_LOOPBACK=true \
    "$DART_BIN" run server/curator_proxy_server.dart &
  PROXY_PID=$!
fi

ready=false
for ((attempt = 0; attempt < 75; attempt++)); do
  readiness_status="$(request_status "$READINESS_URL")"
  if [[ "$readiness_status" == "200" ]]; then
    if ! is_curator_health_body ||
        ! /usr/bin/grep -q '"status":"ready"' "$RESPONSE_FILE"; then
      echo "The readiness response came from an incompatible service." >&2
      exit 70
    fi
    ready=true
    break
  fi
  if [[ "$readiness_status" == "503" ]] &&
      /usr/bin/grep -q '"ocr":"not_configured"' "$RESPONSE_FILE"; then
    echo "Local OCR is unavailable. Install Tesseract and language data; check CURATOR_TESSERACT_BIN / CURATOR_OCR_LANGUAGE." >&2
    exit 78
  fi
  if [[ -n "$PROXY_PID" ]] && ! kill -0 "$PROXY_PID" 2>/dev/null; then
    wait "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
    echo "The Curator proxy exited before becoming ready." >&2
    exit 70
  fi
  sleep 0.2
done

if [[ "$ready" != "true" ]]; then
  echo "Timed out waiting for $READINESS_URL." >&2
  exit 70
fi
if [[ "$CHECK_ONLY" == "true" ]]; then
  echo "Curator proxy readiness check passed."
  exit 0
fi

echo "Curator proxy is ready. Starting Flutter for $DEVICE..."
flutter_args=(
  run
  -d "$DEVICE"
  "--dart-define=CURATOR_BACKEND_URL=$BASE_URL"
)
if [[ "$DEVICE" == "chrome" ]]; then
  flutter_args+=("--web-port=$WEB_PORT")
fi

/usr/bin/env \
  -u GEMINI_API_KEY \
  -u CURATOR_TARGET_REDSKY_KEY \
  -u CURATOR_PROXY_TOKEN \
  -u CURATOR_TRUSTED_AUTH_HEADER \
  "$FLUTTER_BIN" "${flutter_args[@]}" &
APP_PID=$!

while kill -0 "$APP_PID" 2>/dev/null; do
  if [[ -n "$PROXY_PID" ]] && ! kill -0 "$PROXY_PID" 2>/dev/null; then
    set +e
    wait "$PROXY_PID"
    proxy_status=$?
    set -e
    PROXY_PID=""
    echo "The owned Curator proxy exited while Flutter was running." >&2
    terminate_pid "$APP_PID"
    APP_PID=""
    ((proxy_status == 0)) && exit 70
    exit "$proxy_status"
  fi
  sleep 0.5
done

set +e
wait "$APP_PID"
flutter_status=$?
set -e
APP_PID=""
exit "$flutter_status"
