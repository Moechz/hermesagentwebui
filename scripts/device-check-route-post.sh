#!/usr/bin/env bash
# Device check for route-based WebUI apps (TOS gateway -> app loopback).
#
# Why this exists (seq -015): the -012..-014 packages shipped a route with
# `proxy_set_header Host $host;`. The port was stripped, so upstream
# hermes-webui's CSRF same-origin gate 403'd every browser POST/PUT/DELETE
# ("Cross-origin mismatch - check reverse proxy headers") while GETs kept
# working — an app that "opens fine" but cannot save anything. A GET/HEAD
# 200 is therefore NOT sufficient evidence for a route-based app: the check
# must include a browser-shaped POST carrying an Origin header.
#
# Usage:
#   scripts/device-check-route-post.sh https://<tos>:5443/hermesagent
#   scripts/device-check-route-post.sh https://<tos>:5443/hermesagent \
#       --provider-url http://127.0.0.1:18787/v1
#
# Notes:
#   * Runs from the operator machine; needs curl only.
#   * The Origin it sends is exactly the route's own origin, i.e. what a
#     browser opened at that URL would send (same-origin fetch).
#   * --provider-url additionally exercises the onboarding probe end to end
#     (only meaningful when an OpenAI-compatible server really answers there,
#     e.g. llama.cpp). Without it the probe body is allowed to fail; what must
#     NOT happen is a CSRF rejection.
set -euo pipefail

BASE=""
PROVIDER_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider-url) PROVIDER_URL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) BASE="$1"; shift ;;
  esac
done
[ -n "$BASE" ] || { echo "usage: $0 https://<tos>:5443/<appid> [--provider-url URL]" >&2; exit 2; }
BASE="${BASE%/}"
ORIGIN="$(printf '%s' "$BASE" | sed -E 's#^(https?://[^/]+).*#\1#')"

fail=0
say() { printf '%s\n' "$*"; }

# 1) GET (NOT HEAD — hermes-webui answers HEAD with 501).
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$BASE/" || echo 000)
if [ "$code" = "200" ]; then say "PASS: GET $BASE/ -> 200"; else say "FAIL: GET $BASE/ -> $code"; fail=1; fi

# 2) Browser-shaped POST with same-origin Origin (the CSRF gate's input).
body=$(mktemp); trap 'rm -f "$body"' EXIT
payload='{"provider":"custom","base_url":"http://127.0.0.1:1/v1"}'
[ -n "$PROVIDER_URL" ] && payload=$(printf '{"provider":"custom","base_url":"%s"}' "$PROVIDER_URL")
code=$(curl -sk -o "$body" -w '%{http_code}' --max-time 60 \
        -X POST -H "Origin: $ORIGIN" -H 'Content-Type: application/json' \
        -d "$payload" "$BASE/api/onboarding/probe" || echo 000)
if [ "$code" = "403" ] && grep -qi 'cross-origin' "$body"; then
  say "FAIL: POST with Origin $ORIGIN -> 403 (CSRF same-origin rejection)"
  say "      $(cat "$body")"
  say "      => the route strips the port from Host; use 'proxy_set_header Host \$http_host;'"
  fail=1
else
  say "PASS: POST with Origin $ORIGIN -> $code (no CSRF rejection)"
  say "      $(head -c 200 "$body")"
fi

# 3) With --provider-url the probe must actually succeed.
if [ -n "$PROVIDER_URL" ]; then
  if grep -q '"ok": *true' "$body"; then
    say "PASS: provider probe reached $PROVIDER_URL and returned models"
  else
    say "FAIL: provider probe did not succeed against $PROVIDER_URL"
    fail=1
  fi
fi

[ "$fail" = "0" ] && say "OK: route POST verification passed" || say "FAILED"
exit "$fail"
