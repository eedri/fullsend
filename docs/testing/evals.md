# Functional Evals

Functional evals test the full agent pipeline — pre-script, agent execution,
post-script — against ephemeral GitHub fixtures. They verify that agents
produce the right side effects (labels, comments, PR state) when given
controlled inputs.

For the decision rationale, see
[ADR 0044](../ADRs/0044-functional-evals-for-agent-pipelines.md). For the
framework choice, see
[ADR 0045](../ADRs/0045-agent-eval-harness-for-eval-infrastructure.md). For
the broader testing problem, see
[testing-agents.md](../problems/testing-agents.md).

## agent-eval-harness

Functional evals are built on
[agent-eval-harness](https://github.com/opendatahub-io/agent-eval-harness),
a generic evaluation framework for agents and skills. We use it for test case
management, judge orchestration, scoring, and threshold gating so we don't
build eval infrastructure ourselves.

The integration point is the
[opaque CLI runner contract](https://github.com/opendatahub-io/agent-eval-harness/blob/main/docs/opaque-cli-runner-contract.md).
Fullsend's `eval/fullsend-runner.sh` implements this contract: it receives a
workspace and output directory from the harness, runs `fullsend run` inside a
sandbox, and writes captured fixture state to the output directory. The harness
handles everything else — iterating cases, invoking judges, computing scores,
and enforcing thresholds.

When adding eval capabilities (new judge types, dataset generation, regression
detection), check whether agent-eval-harness already supports it or can be
extended upstream before building something fullsend-specific.

## Prerequisites

- Go toolchain (to build `fullsend`)
- `gh` CLI, authenticated
- A GitHub org for eval fixtures (`EVAL_ORG`)
- GCP credentials with Vertex AI access (`GOOGLE_APPLICATION_CREDENTIALS`)
- Anthropic project ID (`ANTHROPIC_VERTEX_PROJECT_ID`)

## Running evals

```bash
make functional-evals
```

This builds the `fullsend` binary, iterates over eval cases, and scores each
one. Results are printed to stdout with pass/fail per judge and threshold.

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `EVAL_ORG` | Yes | GitHub org where ephemeral fixture repos are created |
| `GH_TOKEN` | Yes | GitHub token with repo/org permissions in `EVAL_ORG` |
| `GOOGLE_APPLICATION_CREDENTIALS` | Yes | Path to GCP credentials JSON |
| `ANTHROPIC_VERTEX_PROJECT_ID` | Yes | GCP project with Vertex AI access |
| `GOOGLE_CLOUD_PROJECT` | Yes | GCP project ID |
| `CLOUD_ML_REGION` | Yes | GCP region for Vertex AI (e.g. `us-central1`) |
| `FULLSEND_DIR` | No | Path to fullsend scaffold directory (default: `internal/scaffold/fullsend-repo`) |
| `EVALS_HOST_CREDENTIALS` | No | Path to host GCP credentials for scoring (CI only — overrides sandbox-rewritten creds) |

## Directory layout

```
eval/
  fullsend-runner.sh          # CLI runner: fixture -> fullsend run -> capture
  run-functional.sh           # Orchestrator: iterate cases, score
  <skill>/                    # One directory per agent skill
    eval.yaml                 # Eval config: judges, thresholds, models
    cases/
      001-<name>/
        input.yaml            # Fixture definition (forge, type, title, body)
        annotations.yaml      # Expected state + rubric hints for LLM judge
        repo/                 # Source tree the agent sees (or symlink)
    repos/                    # Shared repo content, symlinked by cases
```

## Writing a test case

### 1. Create the case directory

```bash
mkdir -p eval/<skill>/cases/<NNN>-<short-name>
```

Number cases sequentially within each skill.

### 2. Write `input.yaml`

Define the GitHub fixture the agent will triage or review:

```yaml
forge: github
fixture: issue          # or: pull_request
title: "Bug: login fails with special characters"
body: |
  When a username contains a `+`, the login form rejects it
  with a 400 error.
```

### 3. Write `annotations.yaml`

Describe the expected outcome. This serves two purposes: deterministic checks
(labels, state) and hints for the LLM judge.

```yaml
labels:
  required:
    - bug
    - triage/accepted
triage_expectations:
  - Agent should read the validation regex in src/auth/validators.py
  - Agent should notice the regex already handles `+` characters
  - Comment should reference the specific regex pattern
```

### 4. Add repo content

Either create a `repo/` directory with the source files the agent will see, or
symlink to a shared repo under `eval/<skill>/repos/`:

```bash
ln -s ../../repos/python-webapp eval/<skill>/cases/<NNN>-<short-name>/repo
```

### 5. Configure judges in `eval.yaml`

Each skill's `eval.yaml` defines judges (LLM-graded or deterministic) and
pass thresholds. See `eval/triage/eval.yaml` for a working example.

## Scoring

Two types of judges score each case:

- **LLM judge** — an LLM evaluates the agent's work against the
  `annotations.yaml` rubric on a 1-5 scale. Gated on `min_mean`.
- **Deterministic checks** — Python expressions that verify specific
  properties of the captured fixture state (e.g., required labels present).
  Gated on `min_pass_rate`.

Threshold-based gating acknowledges non-determinism. A `min_mean: 2.5` means
the agent must score at least 2.5 averaged across runs, not that every run
must score 2.5.

## CI integration

Functional evals run in GitHub Actions when files under `eval/` or
`internal/scaffold/` change. The workflow is defined in
`.github/workflows/functional-evals.yml`.

Evals require the `evals` GitHub environment, which provides secrets
(`EVAL_GH_TOKEN`, `GCP_CREDENTIALS`) and vars (`EVAL_ORG`,
`ANTHROPIC_VERTEX_PROJECT_ID`).
