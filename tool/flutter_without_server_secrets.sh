#!/usr/bin/env bash

set -euo pipefail

# Dart Code's `customTool` passes the same arguments it would pass to Flutter.
# Keep server credentials out of native and Web client processes even when the
# IDE itself was opened from a shell that contains those credentials.
FLUTTER_BIN="${CURATOR_FLUTTER_BIN:-}"
if [[ -z "$FLUTTER_BIN" ]]; then
  FLUTTER_BIN="$(command -v flutter || true)"
fi
if [[ -z "$FLUTTER_BIN" && -x /usr/local/share/flutter/bin/flutter ]]; then
  FLUTTER_BIN=/usr/local/share/flutter/bin/flutter
fi
if [[ -z "$FLUTTER_BIN" || ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter was not found. Set CURATOR_FLUTTER_BIN or update PATH." >&2
  exit 69
fi

exec /usr/bin/env \
  -u GEMINI_API_KEY \
  -u CURATOR_TARGET_REDSKY_KEY \
  -u CURATOR_PROXY_TOKEN \
  -u CURATOR_TRUSTED_AUTH_HEADER \
  "$FLUTTER_BIN" "$@"
