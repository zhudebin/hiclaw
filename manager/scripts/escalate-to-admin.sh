#!/bin/bash
# escalate-to-admin.sh
# Sends a question to admin via their primary channel and routes reply back to source session.
# Usage: escalate-to-admin.sh --source-session <key> --question <text>
#
# Exit 0: hook dispatched (admin will receive question; reply routes back via sessions_send)
# Exit 1: no non-matrix primary configured, or dispatch failed — caller must use Matrix fallback

set -euo pipefail

SOURCE_SESSION=""
QUESTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-session) SOURCE_SESSION="$2"; shift 2 ;;
    --question)       QUESTION="$2";       shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -z "$SOURCE_SESSION" ] && { echo "Missing --source-session" >&2; exit 2; }
[ -z "$QUESTION" ]       && { echo "Missing --question" >&2;       exit 2; }

PRIMARY_FILE="${HOME}/primary-channel.json"
GATEWAY_URL="http://localhost:18799"
GATEWAY_TOKEN="${MANAGER_GATEWAY_KEY:-}"

[ -z "$GATEWAY_TOKEN" ] && exit 1
[ -f "$PRIMARY_FILE" ]  || exit 1

CONFIRMED=$(jq -r '.confirmed // false' "$PRIMARY_FILE" 2>/dev/null)
CHANNEL=$(jq -r '.channel // "matrix"' "$PRIMARY_FILE" 2>/dev/null)
TO=$(jq -r '.to // ""' "$PRIMARY_FILE" 2>/dev/null)
SENDER_ID=$(jq -r '.sender_id // ""' "$PRIMARY_FILE" 2>/dev/null)

[ "$CONFIRMED" = "true" ]   || exit 1
[ -z "$CHANNEL" ]           && exit 1
[ "$CHANNEL" = "matrix" ]   && exit 1
[ -z "$TO" ]                && exit 1
[ -z "$SENDER_ID" ]         && exit 1

DM_SESSION_KEY="agent:main:${CHANNEL}:dm:${SENDER_ID}"

HOOK_MSG="[ESCALATION from manager session]
Source session (route reply back here): ${SOURCE_SESSION}
Question: ${QUESTION}

Turn 1 instructions: Present the above question to the admin in a clear, friendly message. End with: \"Please reply here and I will relay your decision back.\"
Turn 2 instructions (when admin replies): Call the sessions_send tool with:
  sessionKey = \"${SOURCE_SESSION}\"
  message = \"[ADMIN_REPLY] \" + admin's reply text
Then confirm to the admin that their reply has been relayed."

PAYLOAD=$(jq -n \
  --arg msg "$HOOK_MSG" \
  --arg channel "$CHANNEL" \
  --arg to "$TO" \
  --arg sk "$DM_SESSION_KEY" \
  '{message: $msg, name: "Escalation", channel: $channel, to: $to, deliver: true, wakeMode: "now", sessionKey: $sk}')

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${GATEWAY_URL}/hooks/agent" \
  -H "Authorization: Bearer ${GATEWAY_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

[ "$HTTP_CODE" = "202" ] && exit 0 || exit 1
