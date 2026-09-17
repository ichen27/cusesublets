#!/bin/sh
set -eu
export PATH=/opt/homebrew/bin:$PATH
: "${APP_DATA_DIR:?Launcher must provide APP_DATA_DIR}"
: "${PORT:?Launcher must provide PORT}"
# The local Wrangler proxy rewrites same-host Origin to its HTTP origin.
# The public Cloudflare endpoint remains HTTPS; keep exact-host CSRF checks.
exec /opt/homebrew/bin/node node_modules/wrangler/bin/wrangler.js dev --ip 127.0.0.1 --port "$PORT" --persist-to "$APP_DATA_DIR/state" --var APP_ENV:staging --var ACCESS_TEAM_DOMAIN:snowy-voice-36a1.cloudflareaccess.com --var ACCESS_AUD:4f1a9e0503b212b76c7e7f462543f6f1c01ba6e31f3aec31e265ab788083bf4a --var ADMIN_EMAILS:ivan27chen@gmail.com --var APP_ORIGIN:http://app-cusesublets.chenagent.com
