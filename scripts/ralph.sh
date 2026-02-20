#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh --tool <amp|claude|claude-sandbox> [--sandbox <name>] [docker flags...] [max_iterations]
#
# Examples:
#   ./ralph.sh --tool claude
#   ./ralph.sh --tool claude 20
#   ./ralph.sh --tool claude-sandbox
#   ./ralph.sh --tool claude-sandbox --sandbox existing-sandbox-name
#   ./ralph.sh --tool claude-sandbox --volume $PWD:/workspace --env FOO=bar 20

set -e

# Parse arguments
TOOL="amp" # Default to amp for backwards compatibility
MAX_ITERATIONS=10
DOCKER_FLAGS=""
SANDBOX_NAME=""

while [[ $# -gt 0 ]]; do
	case $1 in
	--tool)
		TOOL="$2"
		shift 2

		# If tool is claude-sandbox, collect any docker flags that follow
		if [[ "$TOOL" == "claude-sandbox" ]]; then
			# Collect docker flags (anything starting with - or -- that's not a number)
			while [[ $# -gt 0 ]] && [[ "$1" =~ ^- ]] && [[ ! "$1" =~ ^[0-9]+$ ]]; do
				if [[ "$1" == "--sandbox" ]]; then
					SANDBOX_NAME="$2"
					shift 2
				elif [[ "$1" == --sandbox=* ]]; then
					SANDBOX_NAME="${1#*=}"
					shift
				else
					DOCKER_FLAGS="$DOCKER_FLAGS $1"
					shift
					# If this flag takes a value (next arg doesn't start with -)
					if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ ^[0-9]+$ ]]; then
						DOCKER_FLAGS="$DOCKER_FLAGS $1"
						shift
					fi
				fi
			done
		fi
		;;
	--tool=*)
		TOOL="${1#*=}"
		shift
		;;
	--sandbox)
		SANDBOX_NAME="$2"
		shift 2
		;;
	--sandbox=*)
		SANDBOX_NAME="${1#*=}"
		shift
		;;
	*)
		# Assume it's max_iterations if it's a number
		if [[ "$1" =~ ^[0-9]+$ ]]; then
			MAX_ITERATIONS="$1"
		fi
		shift
		;;
	esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" && "$TOOL" != "claude-sandbox" ]]; then
	echo "Error: Invalid tool '$TOOL'. Must be 'amp', 'claude', or 'claude-sandbox'."
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
RALPH_DIR="$WORK_DIR/ralph"
PRD_FILE="$RALPH_DIR/prd.json"
PROGRESS_FILE="$RALPH_DIR/progress.txt"
ARCHIVE_DIR="$RALPH_DIR/archive"
LAST_BRANCH_FILE="$RALPH_DIR/.last-branch"

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
	CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
	LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

	if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
		# Archive the previous run
		DATE=$(date +%Y-%m-%d)
		# Strip "ralph/" prefix from branch name for folder
		FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
		ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

		echo "Archiving previous run: $LAST_BRANCH"
		mkdir -p "$ARCHIVE_FOLDER"
		[ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
		[ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
		echo "   Archived to: $ARCHIVE_FOLDER"

		# Reset progress file for new run
		echo "# Ralph Progress Log" >"$PROGRESS_FILE"
		echo "Started: $(date)" >>"$PROGRESS_FILE"
		echo "---" >>"$PROGRESS_FILE"
	fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
	CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
	if [ -n "$CURRENT_BRANCH" ]; then
		echo "$CURRENT_BRANCH" >"$LAST_BRANCH_FILE"
	fi
fi

mkdir -p "$RALPH_DIR"

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
	echo "# Ralph Progress Log" >"$PROGRESS_FILE"
	echo "Started: $(date)" >>"$PROGRESS_FILE"
	echo "---" >>"$PROGRESS_FILE"
fi

if [[ "$TOOL" == "claude-sandbox" ]]; then
	echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
	[[ -n "$SANDBOX_NAME" ]] && echo "Sandbox name: $SANDBOX_NAME"
	[[ -n "$DOCKER_FLAGS" ]] && echo "Docker flags:$DOCKER_FLAGS"
else
	echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
fi

for i in $(seq 1 $MAX_ITERATIONS); do
	echo ""
	echo "==============================================================="
	echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
	echo "==============================================================="

	# Run the selected tool with the ralph prompt
	if [[ "$TOOL" == "amp" ]]; then
		OUTPUT=$(cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
	elif [[ "$TOOL" == "claude-sandbox" ]]; then
		# Run in Docker sandbox with optional sandbox name and additional flags
		# SANDBOX_NAME is passed as a positional arg (runs existing sandbox by name, or defaults to "claude")
		OUTPUT=$(docker sandbox run ${SANDBOX_NAME:-claude} $DOCKER_FLAGS -- --print <"$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr) || true
	else
		# Run locally
		OUTPUT=$(claude --dangerously-skip-permissions --print <"$SCRIPT_DIR/CLAUDE.md" 2>&1 | tee /dev/stderr) || true
	fi

	# Check for completion signal
	if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
		echo ""
		echo "Ralph completed all tasks!"
		echo "Completed at iteration $i of $MAX_ITERATIONS"
		exit 0
	fi

	echo "Iteration $i complete. Continuing..."
	sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
