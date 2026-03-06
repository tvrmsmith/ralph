#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh --tool <amp|claude|claude-sandbox> [--sandbox <name>] [max_iterations]
#
# Examples:
#   ./ralph.sh --tool claude
#   ./ralph.sh --tool claude 20
#   ./ralph.sh --tool claude-sandbox
#   ./ralph.sh --tool claude-sandbox --sandbox existing-sandbox-name

set -e

# Parse arguments
TOOL="amp" # Default to amp for backwards compatibility
MAX_ITERATIONS=10
SANDBOX_NAME=""

show_help() {
	cat <<EOF
Usage: ralph.sh [OPTIONS] [max_iterations]

Run Ralph, a long-running AI agent loop.

OPTIONS:
  --tool <tool>         AI tool to use: amp, claude, claude-sandbox (default: amp)
  --sandbox <name>      Sandbox name for claude-sandbox tool (default: claude)
  -h, --help            Show this help message

ARGUMENTS:
  max_iterations        Maximum number of iterations to run (default: 10)

EXAMPLES:
  ralph.sh --tool claude
  ralph.sh --tool claude 20
  ralph.sh --tool claude-sandbox
  ralph.sh --tool claude-sandbox --sandbox existing-sandbox-name
EOF
}

while [[ $# -gt 0 ]]; do
	case $1 in
	-h | --help)
		show_help
		exit 0
		;;
	--tool)
		TOOL="$2"
		shift 2
		;;
	--tool=*)
		TOOL="${1#*=}"
		shift
		;;
	--sandbox | --docker-sandbox)
		SANDBOX_NAME="$2"
		shift 2
		;;
	--sandbox=* | --docker-sandbox=*)
		SANDBOX_NAME="${1#*=}"
		shift
		;;
	*)
		if [[ "$1" =~ ^[0-9]+$ ]]; then
			MAX_ITERATIONS="$1"
		else
			echo "Error: Unknown option '$1'"
			echo "Run with -h for usage."
			exit 1
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

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
[[ "$TOOL" == "claude-sandbox" && -n "$SANDBOX_NAME" ]] && echo "Sandbox name: $SANDBOX_NAME"

for i in $(seq 1 $MAX_ITERATIONS); do
	echo ""
	echo "==============================================================="
	echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
	echo "==============================================================="

	# Run the selected tool with the ralph prompt
	if [[ "$TOOL" == "amp" ]]; then
		OUTPUT=$(cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all 2>&1 | tee /dev/stderr) || true
	elif [[ "$TOOL" == "claude-sandbox" ]]; then
		# Run in Docker sandbox. docker sandbox run does not forward piped stdin to the agent,
		# so we pass the prompt content as a CLI argument using command substitution on the host.
		OUTPUT=$(docker sandbox run ${SANDBOX_NAME:-claude} -- --verbose --print "$(cat "$SCRIPT_DIR/CLAUDE.md")" 2>&1 | tee /dev/stderr) || true
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
