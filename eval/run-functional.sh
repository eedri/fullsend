#!/usr/bin/env bash
# Run functional agent evals using agent-eval-harness for scoring.
#
# Usage:
#   ./eval/run-functional.sh <agent-name>
#
# Example:
#   EVAL_ORG=halfsend FULLSEND_DIR=./internal/scaffold/fullsend-repo \
#     ./eval/run-functional.sh triage
#
# Required environment:
#   EVAL_ORG      — GitHub org for ephemeral repos
#   FULLSEND_DIR  — path to fullsend scaffold directory
#   GH_TOKEN      — GitHub token (defaults to gh auth token)
#
# Required:
#   agent-eval-harness — pip install from github.com/opendatahub-io/agent-eval-harness
#   The harness scoring scripts live in the eval/.agent-eval-harness submodule.
#
# Optional environment:
#   GOOGLE_APPLICATION_CREDENTIALS, ANTHROPIC_VERTEX_PROJECT_ID, etc.
#   AGENT_EVAL_HARNESS_DIR — path to agent-eval-harness checkout (default: eval/.agent-eval-harness submodule)
set -euo pipefail

AGENT="${1:?agent name required}"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_YAML="${EVAL_DIR}/${AGENT}/eval.yaml"
CASES_DIR="${EVAL_DIR}/${AGENT}/cases"
HARNESS_DIR="${AGENT_EVAL_HARNESS_DIR:-${EVAL_DIR}/.agent-eval-harness}"

if [[ ! -f "$EVAL_YAML" ]]; then
  echo "ERROR: eval config not found: $EVAL_YAML" >&2
  exit 1
fi

# Fail fast if agent_eval library is not installed
if ! python3 -c "import agent_eval" 2>/dev/null; then
  echo "ERROR: agent-eval-harness library is not installed." >&2
  echo "       pip install 'agent-eval-harness[anthropic] @ git+https://github.com/opendatahub-io/agent-eval-harness.git'" >&2
  exit 1
fi

# Ensure harness scoring scripts are available. The default path is a git
# submodule at eval/.agent-eval-harness — run `git submodule update --init`
# if it hasn't been checked out yet.
SCORE_PY="${HARNESS_DIR}/skills/eval-run/scripts/score.py"
if [[ ! -f "$SCORE_PY" ]]; then
  if [[ -f "${EVAL_DIR}/../.gitmodules" ]] && grep -q agent-eval-harness "${EVAL_DIR}/../.gitmodules" 2>/dev/null; then
    echo "==> Initializing agent-eval-harness submodule..."
    git -C "${EVAL_DIR}/.." submodule update --init eval/.agent-eval-harness
  else
    echo "ERROR: scoring script not found: $SCORE_PY" >&2
    echo "       Run: git submodule update --init eval/.agent-eval-harness" >&2
    exit 1
  fi
fi

export GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"
export CLAUDE_SKILL_DIR="${HARNESS_DIR}/skills/eval-run"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUNS_DIR="${EVAL_DIR}/runs/${AGENT}"
RUN_DIR="${RUNS_DIR}/${RUN_ID}"
mkdir -p "$RUN_DIR"

echo "=== Functional Evals: ${AGENT} ==="
echo "Config:  ${EVAL_YAML}"
echo "Cases:   ${CASES_DIR}"
echo "Run ID:  ${RUN_ID}"
echo "Output:  ${RUN_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Execute — run each case through our wrapper
# ---------------------------------------------------------------------------
# The CLI runner in agent-eval-harness handles placeholder resolution and
# subprocess management, but its orchestration (execute.py) expects a
# workspace layout created by the eval-run skill. We drive case iteration
# ourselves and write outputs where score.py expects them.
TOTAL=0
ERRORS=0

for case_dir in "$CASES_DIR"/*/; do
  case_name=$(basename "$case_dir")
  input="$case_dir/input.yaml"

  if [[ ! -f "$input" ]]; then
    continue
  fi

  TOTAL=$((TOTAL + 1))

  # score.py expects: <runs_dir>/<run_id>/cases/<case_name>/<output_path>/
  case_output_dir="${RUN_DIR}/cases/${case_name}"
  mkdir -p "$case_output_dir"

  echo "--- Case: ${case_name} ---"

  if "${EVAL_DIR}/fullsend-runner.sh" "$AGENT" "$case_dir" "$case_output_dir" \
      > "$case_output_dir/runner.log" 2>&1; then
    echo "  Runner: OK"
  else
    rc=$?
    echo "  Runner: exited with status $rc (see $case_output_dir/runner.log)"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "=== Execution complete: $TOTAL cases, $ERRORS errors ==="
echo ""

# ---------------------------------------------------------------------------
# Phase 2: Score — use agent-eval-harness score.py for judging
# ---------------------------------------------------------------------------
echo "=== Scoring ==="
# Scoring runs on the host and needs the original GCP credentials, not the
# sandbox-rewritten ones (which reference paths inside the container).
if [[ -n "${EVALS_HOST_CREDENTIALS:-}" ]]; then
  export GOOGLE_APPLICATION_CREDENTIALS="$EVALS_HOST_CREDENTIALS"
fi
AGENT_EVAL_RUNS_DIR="$RUNS_DIR" \
  python3 "$SCORE_PY" judges \
    --run-id "$RUN_ID" \
    --config "$EVAL_YAML" || ERRORS=$((ERRORS + 1))

if [[ "$ERRORS" -gt 0 ]]; then
  echo "FAIL: $ERRORS error(s) detected"
  exit 1
fi
