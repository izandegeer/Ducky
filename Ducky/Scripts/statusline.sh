#!/bin/bash
# Ducky statusline wrapper for Claude Code
# 1. Reads session data from stdin (JSON)
# 2. Extracts key metrics and writes them to ~/.ducky/statusline/{session_id}.json
# 3. If the user had an existing statusline command, pipes the original JSON through it
#    Otherwise outputs "Ducky 🐥"

set -euo pipefail

# Read JSON from stdin into a variable
INPUT=$(cat)

# Ensure jq is available
if ! command -v jq &>/dev/null; then
    echo "Ducky 🐥"
    exit 0
fi

# Extract session_id — required field
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# Write Ducky data if we have a session_id
if [ -n "$SESSION_ID" ]; then
    STATUSLINE_DIR="$HOME/.ducky/statusline"
    mkdir -p "$STATUSLINE_DIR"

    TIMESTAMP=$(date +%s)

    # Build the output JSON, handling missing/null fields gracefully
    OUTPUT=$(jq -n \
        --arg sid "$SESSION_ID" \
        --argjson ts "$TIMESTAMP" \
        --argjson input "$INPUT" \
        '{
            session_id: $sid,
            timestamp: $ts,
            rate_limits: (
                if ($input.rate_limits // null) != null then
                    {
                        five_hour: {
                            used_percentage: ($input.rate_limits.five_hour.used_percentage // null),
                            resets_at: ($input.rate_limits.five_hour.resets_at // null)
                        },
                        seven_day: {
                            used_percentage: ($input.rate_limits.seven_day.used_percentage // null),
                            resets_at: ($input.rate_limits.seven_day.resets_at // null)
                        }
                    }
                else null end
            ),
            cost: {
                total_cost_usd: ($input.cost.total_cost_usd // 0),
                total_lines_added: ($input.cost.total_lines_added // 0),
                total_lines_removed: ($input.cost.total_lines_removed // 0)
            },
            context_window: {
                used_percentage: ($input.context_window.used_percentage // 0),
                context_window_size: ($input.context_window.context_window_size // 0)
            },
            worktree: (
                if ($input.worktree // null) != null then
                    {
                        name: ($input.worktree.name // null),
                        branch: ($input.worktree.branch // null),
                        original_branch: ($input.worktree.original_branch // null)
                    }
                else null end
            )
        }' 2>/dev/null)

    # Write to file atomically (write to temp, then move)
    TEMP_FILE="$STATUSLINE_DIR/.${SESSION_ID}.json.tmp"
    echo "$OUTPUT" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$STATUSLINE_DIR/${SESSION_ID}.json"
fi

# Check if user has their own statusline command to chain
USER_CMD_FILE="$HOME/.ducky/user-statusline-command"
if [ -f "$USER_CMD_FILE" ]; then
    CMD=$(cat "$USER_CMD_FILE")
    if [ -n "$CMD" ]; then
        # Pipe the original JSON through the user's command
        echo "$INPUT" | eval "$CMD"
        exit $?
    fi
fi

# No user command — output default
echo "Ducky 🐥"
