#!/usr/bin/env bash

set -euo pipefail

# Dart Code's `customTool` launches this wrapper with the exact arguments it
# would normally pass to `dart`. Antigravity/VS Code may have been opened from
# the Dock before shell environment variables were registered, so resolve the
# Dart SDK and local Tesseract PATH from a fresh login shell.
exec /bin/zsh -lic '
  dart_bin="${CURATOR_DART_BIN:-$(command -v dart || true)}"
  if [[ -z "$dart_bin" || ! -x "$dart_bin" ]]; then
    print -u2 -- "Dart was not found. Set CURATOR_DART_BIN or update PATH."
    exit 69
  fi

  # Local IDE debugging always uses the explicit loopback development policy.
  # Do not inherit stale production authentication or CORS settings.
  unset CURATOR_PROXY_TOKEN
  unset CURATOR_TRUSTED_AUTH_HEADER
  unset CURATOR_CORS_ALLOW_ORIGIN
  export CURATOR_PROXY_HOST=127.0.0.1
  export CURATOR_PROXY_PORT=8787
  export CURATOR_ALLOW_UNAUTHENTICATED_LOOPBACK=true

  # A debug launch must own the server it starts. Fail before Dart/DAP startup
  # when an old or unrelated listener occupies the fixed development port;
  # otherwise Flutter could keep polling that stale process indefinitely.
  if [[ -x /usr/bin/curl ]]; then
    if /usr/bin/curl \
        --disable \
        --silent \
        --output /dev/null \
        --noproxy 127.0.0.1 \
        --connect-timeout 1 \
        --max-time 1 \
        http://127.0.0.1:8787/health; then
      port_probe_status=0
    else
      port_probe_status=$?
    fi
    if (( port_probe_status != 7 )); then
      print -u2 -- "Port 8787 is already occupied by another process."
      print -u2 -- "Stop the existing listener, then retry the compound debug launch."
      exit 70
    fi
  fi

  exec "$dart_bin" "$@"
' curator-proxy-dart "$@"
