#!/bin/bash
# send-to-agent.sh — Bridge messaging between paired Claude agents.
#
# Usage (called from within a Claude agent's bash tool):
#   {{BRIDGE}}/send-to-agent.sh b "Your question here"   # A → B
#   {{BRIDGE}}/send-to-agent.sh a "Your response here"   # B → A
#
# Arguments:
#   $1  target: "a" or "b"
#   $2  message text

BRIDGE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
MESSAGE="${2:-}"

if [[ -z "$TARGET" || -z "$MESSAGE" ]]; then
  echo "Usage: $0 <a|b> \"message\"" >&2
  exit 1
fi

TARGET="${TARGET,,}"
if [[ "$TARGET" != "a" && "$TARGET" != "b" ]]; then
  echo "Error: target must be 'a' or 'b'" >&2
  exit 1
fi

if [[ "$TARGET" == "b" ]]; then
  SENDER_ROLE=$(cat "$BRIDGE/role-a" 2>/dev/null || echo "A")
  RECV_ROLE=$(cat "$BRIDGE/role-b" 2>/dev/null || echo "B")
  MSG_FILE="$BRIDGE/a-to-b.md"
  SENDER_STATUS="$BRIDGE/a-status"
  RECV_STATUS="$BRIDGE/b-status"
  RECV_PROMPT="Agent $SENDER_ROLE has sent you a message. Read $MSG_FILE and respond using $BRIDGE/send-to-agent.sh a \"your response\""
else
  SENDER_ROLE=$(cat "$BRIDGE/role-b" 2>/dev/null || echo "B")
  RECV_ROLE=$(cat "$BRIDGE/role-a" 2>/dev/null || echo "A")
  MSG_FILE="$BRIDGE/b-to-a.md"
  SENDER_STATUS="$BRIDGE/b-status"
  RECV_STATUS="$BRIDGE/a-status"
  RECV_PROMPT="Agent $SENDER_ROLE has responded. Read $MSG_FILE and continue your work."
fi

RECV_SESSION=$(cat "$BRIDGE/session-$TARGET" 2>/dev/null)

if [[ -z "$RECV_SESSION" ]]; then
  echo "Error: Bridge not initialized — $BRIDGE/session-$TARGET not found." >&2
  echo "Make sure launch.sh started this session." >&2
  exit 1
fi

# Write the message
TIMESTAMP=$(date +"%H:%M:%S")
cat > "$MSG_FILE" << ENDMSG
# Message from $SENDER_ROLE → $RECV_ROLE [$TIMESTAMP]

$MESSAGE
ENDMSG

echo "waiting" > "$SENDER_STATUS"
echo "pending" > "$RECV_STATUS"

cat >> "$BRIDGE/conversation-log.md" << ENDLOG

---
### [$TIMESTAMP] $SENDER_ROLE → $RECV_ROLE
$MESSAGE
ENDLOG

# Inject prompt into the receiving agent's tmux session
tmux send-keys -t "$RECV_SESSION" "$RECV_PROMPT" ""
sleep 0.2
tmux send-keys -t "$RECV_SESSION" Enter

echo "✓ Sent to $RECV_ROLE agent (session $RECV_SESSION)"
echo "✓ Written to $MSG_FILE"
