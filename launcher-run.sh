#!/bin/sh
set -eu
export PATH=/opt/homebrew/bin:$PATH
: "${APP_DATA_DIR:?Launcher must provide APP_DATA_DIR}"
: "${PORT:?Launcher must provide PORT}"
exec /opt/homebrew/bin/node node_modules/wrangler/bin/wrangler.js dev --ip 127.0.0.1 --port "$PORT" --persist-to "$APP_DATA_DIR/state" --var APP_ENV:hosted-preview --var APP_ORIGIN:https://app-cusesublets.chenagent.com
