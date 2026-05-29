#!/usr/bin/env bash
# Functional eval runner for fullsend agents.
#
# Lifecycle:
#   1. Setup    — create an ephemeral repo, push test content, create a fixture
#   2. Run      — execute fullsend run with full harness (pre/post scripts)
#   3. Capture  — snapshot the fixture's observable state → fixture-state.json
#   4. Teardown — delete the ephemeral repo
#
# Usage:
#   ./eval/fullsend-runner.sh <agent-name> <case-dir> <output-dir>
#
# The case directory must contain:
#   input.yaml       — fixture definition (title, body, type)
#   repo/            — (optional) contents to push as the ephemeral repo
#
# Required environment:
#   FULLSEND_DIR  — path to the fullsend scaffold directory
#   GH_TOKEN      — GitHub token with repo and delete_repo scope
#   EVAL_ORG      — GitHub org/user for ephemeral repos (e.g. "halfsend")
#
# Optional environment:
#   GOOGLE_APPLICATION_CREDENTIALS — path to GCP service account key
#   ANTHROPIC_VERTEX_PROJECT_ID    — GCP project for Vertex AI
set -euo pipefail

AGENT="${1:?agent name required}"
CASE_DIR="${2:?case directory required}"
OUTPUT_DIR="${3:?output dir required}"

EVAL_ORG="${EVAL_ORG:?EVAL_ORG is required (GitHub org/user for ephemeral repos)}"

# Resolve FULLSEND_DIR to absolute path
FULLSEND_DIR="$(cd "${FULLSEND_DIR:?FULLSEND_DIR is required}" && pwd)"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
for cmd in gh yq jq fullsend git uuidgen; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found in PATH" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Parse input.yaml
# ---------------------------------------------------------------------------
INPUT="${CASE_DIR}/input.yaml"
if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: ${INPUT} not found" >&2
  exit 1
fi

FORGE=$(yq -r '.forge // "github"' "$INPUT")
FIXTURE_TYPE=$(yq -r '.fixture.type // "issue"' "$INPUT")
FIXTURE_TITLE=$(yq -r '.fixture.title' "$INPUT")
FIXTURE_BODY=$(yq -r '.fixture.body' "$INPUT")

# PR-specific fields
FIXTURE_BASE=$(yq -r '.fixture.base // "main"' "$INPUT")
FIXTURE_HEAD=$(yq -r '.fixture.head_branch // ""' "$INPUT")
FIXTURE_FILES=$(yq -r '.fixture.files // "[]"' "$INPUT")

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# State tracking — cleaned up on exit
# ---------------------------------------------------------------------------
EPHEMERAL_REPO=""        # org/name of the created repo
FIXTURE_URL=""
FIXTURE_NUMBER=""
PR_BRANCH=""
TARGET_DIR=""

cleanup() {
  local exit_code=$?
  echo "--- Teardown ---"
  teardown_repo
  if [[ -n "$TARGET_DIR" && -d "$TARGET_DIR" ]]; then
    rm -rf "$TARGET_DIR"
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# ===========================================================================
# Forge: GitHub — repo lifecycle
# ===========================================================================

github_create_repo() {
  local uuid
  uuid=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)
  local repo_name="eval-${AGENT}-${uuid}"
  EPHEMERAL_REPO="${EVAL_ORG}/${repo_name}"

  gh repo create "$EPHEMERAL_REPO" --public --description "Ephemeral eval repo (auto-deleted)" >&2
  echo "Created repo: $EPHEMERAL_REPO"

  # Clone and push using GH_TOKEN without persisting it in .git/config.
  # The credential helper reads GH_TOKEN from the environment at runtime.
  TARGET_DIR=$(mktemp -d)
  GH_CRED_HELPER='!f(){ echo "password=${GH_TOKEN}"; };f'
  git -c "credential.helper=${GH_CRED_HELPER}" \
    clone "https://x-access-token@github.com/${EPHEMERAL_REPO}.git" "$TARGET_DIR"
  git -C "$TARGET_DIR" config credential.helper "${GH_CRED_HELPER}"

  if [[ -d "${CASE_DIR}/repo" ]]; then
    # Copy test case repo contents into the clone
    cp -a "${CASE_DIR}/repo/." "$TARGET_DIR/"
  else
    # No repo/ dir — just add a minimal README
    echo "# Eval test repo" > "$TARGET_DIR/README.md"
  fi

  git -C "$TARGET_DIR" add -A
  if git -C "$TARGET_DIR" diff --cached --quiet; then
    echo "  (no changes to commit — repo already has content)"
  else
    git -C "$TARGET_DIR" commit -m "eval: initial content for ${AGENT} test"
    git -C "$TARGET_DIR" push origin HEAD
  fi
}

github_teardown_repo() {
  if [[ -n "$EPHEMERAL_REPO" ]]; then
    gh repo delete "$EPHEMERAL_REPO" --yes 2>/dev/null || true
    echo "Deleted repo: $EPHEMERAL_REPO"
  fi
}

# ===========================================================================
# Forge: GitHub — fixture lifecycle
# ===========================================================================

github_create_issue() {
  local url
  url=$(gh issue create \
    --repo "$EPHEMERAL_REPO" \
    --title "$FIXTURE_TITLE" \
    --body "$FIXTURE_BODY")
  FIXTURE_URL="$url"
  FIXTURE_NUMBER="${url##*/}"
  echo "Created issue: $FIXTURE_URL"
}

github_create_pr() {
  if [[ -z "$FIXTURE_HEAD" ]]; then
    PR_BRANCH="eval-pr-$(date +%s)-$$"
  else
    PR_BRANCH="$FIXTURE_HEAD"
  fi

  git -C "$TARGET_DIR" checkout -b "$PR_BRANCH"

  # Create/modify files specified in input.yaml fixture.files
  local file_count
  file_count=$(echo "$FIXTURE_FILES" | yq -r 'length')
  for i in $(seq 0 $((file_count - 1))); do
    local path content
    path=$(echo "$FIXTURE_FILES" | yq -r ".[$i].path")
    mkdir -p "$TARGET_DIR/$(dirname "$path")"
    echo "$FIXTURE_FILES" | yq -r ".[$i].content" > "$TARGET_DIR/$path"
  done

  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -m "eval: fixture changes for ${AGENT} test"
  git -C "$TARGET_DIR" push origin "$PR_BRANCH"

  local url
  url=$(gh pr create \
    --repo "$EPHEMERAL_REPO" \
    --base "$FIXTURE_BASE" \
    --head "$PR_BRANCH" \
    --title "$FIXTURE_TITLE" \
    --body "$FIXTURE_BODY")
  FIXTURE_URL="$url"
  FIXTURE_NUMBER="${url##*/}"
  echo "Created PR: $FIXTURE_URL"
}

github_capture_issue_state() {
  local state_file="$OUTPUT_DIR/output/fixture-state.json"
  mkdir -p "$OUTPUT_DIR/output"
  local issue_json comments_json

  issue_json=$(gh issue view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json state,labels,assignees,milestone,title)
  comments_json=$(gh issue view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json comments \
    | jq '[.comments[] | {author: .author.login, body: .body, created_at: .createdAt}]')

  jq -n \
    --arg fixture_type "issue" \
    --arg fixture_url "$FIXTURE_URL" \
    --argjson issue "$issue_json" \
    --argjson comments "$comments_json" \
    '{
      fixture_type: $fixture_type,
      fixture_url: $fixture_url,
      state: $issue.state,
      title: $issue.title,
      labels: [($issue.labels // [])[] | .name],
      assignees: [($issue.assignees // [])[] | .login],
      milestone: ($issue.milestone.title // null),
      comments: $comments
    }' > "$state_file"

  echo "Captured issue state → $state_file"
}

github_capture_pr_state() {
  local state_file="$OUTPUT_DIR/output/fixture-state.json"
  mkdir -p "$OUTPUT_DIR/output"
  local pr_json comments_json reviews_json

  pr_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
    --json state,labels,assignees,milestone,title,mergeable,reviewDecision)
  comments_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json comments \
    | jq '[.comments[] | {author: .author.login, body: .body, created_at: .createdAt}]')
  reviews_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json reviews \
    | jq '[.reviews[] | {author: .author.login, state: .state, body: .body}]')

  jq -n \
    --arg fixture_type "pull_request" \
    --arg fixture_url "$FIXTURE_URL" \
    --argjson pr "$pr_json" \
    --argjson comments "$comments_json" \
    --argjson reviews "$reviews_json" \
    '{
      fixture_type: $fixture_type,
      fixture_url: $fixture_url,
      state: $pr.state,
      title: $pr.title,
      labels: [($pr.labels // [])[] | .name],
      assignees: [($pr.assignees // [])[] | .login],
      milestone: ($pr.milestone.title // null),
      mergeable: $pr.mergeable,
      review_decision: $pr.reviewDecision,
      comments: $comments,
      reviews: $reviews
    }' > "$state_file"

  echo "Captured PR state → $state_file"
}

# ===========================================================================
# Forge dispatch
# ===========================================================================

create_repo() {
  case "$FORGE" in
    github) github_create_repo ;;
    *)
      echo "ERROR: unsupported forge: ${FORGE}" >&2
      exit 1
      ;;
  esac
}

teardown_repo() {
  case "$FORGE" in
    github) github_teardown_repo ;;
  esac
}

create_fixture() {
  case "${FORGE}:${FIXTURE_TYPE}" in
    github:issue)        github_create_issue ;;
    github:pull_request) github_create_pr ;;
    *)
      echo "ERROR: unsupported forge:fixture_type = ${FORGE}:${FIXTURE_TYPE}" >&2
      exit 1
      ;;
  esac
}

capture_state() {
  case "${FORGE}:${FIXTURE_TYPE}" in
    github:issue)        github_capture_issue_state ;;
    github:pull_request) github_capture_pr_state ;;
  esac
}

# ===========================================================================
# Main
# ===========================================================================

echo "=== Eval Runner: ${AGENT} ==="
echo "Forge: ${FORGE} | Fixture: ${FIXTURE_TYPE} | Org: ${EVAL_ORG}"

# 1. Create ephemeral repo and push test content
echo "--- Setup: repo ---"
create_repo

# 2. Create the fixture (issue or PR)
echo "--- Setup: fixture ---"
create_fixture

# 3. Build the env file for fullsend run
ENV_FILE="${OUTPUT_DIR}/.eval-env"
install -m 0600 /dev/null "$ENV_FILE"
{
  echo "GH_TOKEN=${GH_TOKEN}"
  echo "PUSH_TOKEN=${GH_TOKEN}"
  echo "REVIEW_TOKEN=${GH_TOKEN}"

  case "$FIXTURE_TYPE" in
    issue)        echo "GITHUB_ISSUE_URL=${FIXTURE_URL}" ;;
    pull_request) echo "GITHUB_PR_URL=${FIXTURE_URL}" ;;
  esac

  # GCP / Vertex AI (optional)
  [[ -n "${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]] && echo "ANTHROPIC_VERTEX_PROJECT_ID=${ANTHROPIC_VERTEX_PROJECT_ID}"
  [[ -n "${GOOGLE_CLOUD_PROJECT:-}" ]]        && echo "GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT}"
  [[ -n "${CLOUD_ML_REGION:-}" ]]             && echo "CLOUD_ML_REGION=${CLOUD_ML_REGION}"
  [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && echo "GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS}"
} > "$ENV_FILE"

# 4. Run fullsend with full harness (pre + post scripts)
echo "--- Run ---"
FULLSEND_BIN="$(command -v fullsend)"
rc=0
fullsend run "$AGENT" \
  --fullsend-dir "${FULLSEND_DIR}" \
  --target-repo "$TARGET_DIR" \
  --env-file "$ENV_FILE" \
  --output-dir "$OUTPUT_DIR" \
  --fullsend-binary "$FULLSEND_BIN" \
  || rc=$?
if [[ $rc -ne 0 ]]; then
  echo "WARNING: fullsend run exited with status $rc"
fi

# Remove env file to prevent secrets from being uploaded as artifacts
rm -f "$ENV_FILE"

# 5. Capture fixture state for judges
echo "--- Capture ---"
capture_state

echo "=== Done ==="
