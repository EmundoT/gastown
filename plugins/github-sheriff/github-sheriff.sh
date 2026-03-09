#!/usr/bin/env bash
# GitHub Sheriff Plugin
# Polls GitHub for failed CI checks on open pull requests and creates beads for failures

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Error handler
trap 'handle_error "$LINENO" "$?"' ERR

handle_error() {
  local lineno=$1
  local code=$2
  ERROR="GitHub sheriff failed at line $lineno with exit code $code"
  echo -e "${RED}✗ $ERROR${NC}"

  # Create failure bead
  bd create "github-sheriff: FAILED" -t chore --ephemeral \
    -l type:plugin-run,plugin:github-sheriff,result:failure \
    -d "GitHub sheriff failed: $ERROR" --silent 2>/dev/null || true

  # Escalate
  gt escalate "Plugin FAILED: github-sheriff" \
    --severity low \
    --reason "$ERROR" 2>/dev/null || true

  exit 1
}

# Step 1: Detection - Verify gh is available and authenticated
echo "Checking gh CLI authentication..."
if ! gh auth status > /dev/null 2>&1; then
  echo "SKIP: gh CLI not authenticated"
  exit 0
fi

# Detect the repo from the rig's git remote
REPO=$(git -C "${GT_RIG_ROOT:-.}" remote get-url origin 2>/dev/null \
  | sed -E 's|.*github\.com[:/]||; s|\.git$||') || true

if [ -z "$REPO" ]; then
  echo "SKIP: could not detect GitHub repo from rig remote"
  exit 0
fi

echo "Found repo: $REPO"

# Step 2: List open PRs
echo "Fetching open PRs..."
PRS=$(gh pr list --repo "$REPO" --state open \
  --json number,title,author,headRefName,url --limit 100)

PR_COUNT=$(echo "$PRS" | jq length)
if [ "$PR_COUNT" -eq 0 ]; then
  echo "No open PRs found for $REPO"
  # Still record success
  bd create "github-sheriff: $REPO: 0 PRs checked, 0 failures, 0 beads created" \
    -t chore --ephemeral \
    -l type:plugin-run,plugin:github-sheriff,result:success \
    --silent 2>/dev/null || true
  exit 0
fi

echo "Found $PR_COUNT open PRs"

# Step 3: Check each PR for failures
echo "Checking PR status..."
FAILURES=()
for PR_NUM in $(echo "$PRS" | jq -r '.[].number'); do
  PR_TITLE=$(echo "$PRS" | jq -r ".[] | select(.number == $PR_NUM) | .title")

  echo "  Checking PR #$PR_NUM: $PR_TITLE"
  CHECKS=$(gh pr checks "$PR_NUM" --repo "$REPO" \
    --json name,bucket,link 2>/dev/null || echo "[]")

  while IFS= read -r ROW; do
    [ -z "$ROW" ] && continue
    CHECK_NAME=$(echo "$ROW" | jq -r '.name')
    CHECK_URL=$(echo "$ROW" | jq -r '.link')
    BUCKET=$(echo "$ROW" | jq -r '.bucket')

    if [ "$BUCKET" = "fail" ] || [ "$BUCKET" = "cancel" ]; then
      echo "    ✗ $CHECK_NAME ($BUCKET)"
      FAILURES+=("$PR_NUM|$PR_TITLE|$CHECK_NAME|$CHECK_URL|$BUCKET")
    fi
  done < <(echo "$CHECKS" | jq -c '.[]' 2>/dev/null)
done

echo "Found ${#FAILURES[@]} failures"

# Step 4: Deduplicate against existing beads
echo "Checking for existing beads..."
EXISTING=$(bd list --label ci-failure --status open --json 2>/dev/null || echo "[]")

CREATED=0
SKIPPED=0

for F in "${FAILURES[@]}"; do
  IFS='|' read -r PR_NUM PR_TITLE CHECK_NAME CHECK_URL BUCKET <<< "$F"
  BEAD_TITLE="CI failure: $CHECK_NAME on PR #$PR_NUM"

  # Check for duplicate (use jq --arg for safe string comparison)
  if echo "$EXISTING" | jq -e --arg t "$BEAD_TITLE" '.[] | select(.title == $t)' > /dev/null 2>&1; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Create bead
  DESCRIPTION="CI check \`$CHECK_NAME\` failed on PR #$PR_NUM ($PR_TITLE)

PR: https://github.com/$REPO/pull/$PR_NUM
Check: $CHECK_URL
Result: $BUCKET"

  BEAD_ID=$(bd create "$BEAD_TITLE" -t task -p 2 \
    -d "$DESCRIPTION" \
    -l ci-failure \
    --json 2>/dev/null | jq -r '.id // empty') || true

  if [ -n "$BEAD_ID" ]; then
    CREATED=$((CREATED + 1))
    echo "  Created bead: $BEAD_ID"

    # Log to activity feed (if available)
    gt activity emit github_check_failed \
      --message "CI check $CHECK_NAME failed on PR #$PR_NUM ($REPO), bead $BEAD_ID" \
      2>/dev/null || true
  fi
done

# Step 5: Record result
SUMMARY="$REPO: checked $PR_COUNT PRs, ${#FAILURES[@]} failure(s), $CREATED bead(s) created, $SKIPPED already tracked"
echo "=== SUMMARY ==="
echo "$SUMMARY"

# On success
bd create "github-sheriff: $SUMMARY" -t chore --ephemeral \
  -l type:plugin-run,plugin:github-sheriff,result:success \
  -d "$SUMMARY" --silent 2>/dev/null || true

echo -e "${GREEN}✓ GitHub Sheriff completed successfully${NC}"
