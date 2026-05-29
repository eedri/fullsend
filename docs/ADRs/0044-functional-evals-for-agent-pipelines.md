---
title: "44. Functional evals for agent pipelines"
status: Accepted
relates_to:
  - testing-agents
topics:
  - testing
  - evals
---

# 44. Functional evals for agent pipelines

Date: 2026-05-29

## Status

Accepted

<!-- Once this ADR is Accepted, its content is frozen. Do not edit the Context,
     Decision, or Consequences sections. If circumstances change, write a new
     ADR that supersedes this one. Only status changes and links to superseding
     ADRs should be added after acceptance. -->

## Context

The [testing-agents](../problems/testing-agents.md) problem doc identifies a
gap: we have CI for code but no CI for prompts. It surveys prompt-level eval
frameworks (promptfoo, deepeval) and agent-level runners (Inspect AI), but
notes that most eval frameworks test prompts, not agents — they send a single
prompt to a model API and score the response, without exercising the full
agent loop (tool calls, multi-turn reasoning, environment interaction).

Prior attempts to run agent evals were cut short because agents misbehaved
during eval runs — misusing credentials and producing side effects outside
the test boundary. The sandboxed execution model introduced in
[ADR 0036](0036-agent-execution-sandbox.md) changed this: agents now run in
containers with controlled network access and scoped credentials, limiting
blast radius enough to make eval suites practical.

PR [#1682](https://github.com/fullsend-ai/fullsend/pull/1682) introduces a
functional eval framework that tests at a different level: the complete agent
pipeline (pre-script, agent execution, post-script) running against ephemeral
GitHub fixtures and scored by an LLM judge. A key property of functional
evals is that they verify post-scripts and credential use actually work
against real external services — not just that the agent produces plausible
output, but that the full pipeline's interaction with GitHub (labeling,
commenting, state transitions) succeeds end-to-end.

This creates a new test category that needs a name and a place in the testing
taxonomy. The emerging test pyramid for this project has four layers:

1. **Unit tests** — deterministic Go tests (`make go-test`). Cheap, fast,
   plentiful.
2. **Prompt evals** — test agent prompts and skills in isolation, with mocked
   external dependencies (not yet implemented). Cheaper than functional evals
   because they avoid real service interactions, so they can be more numerous
   and provide broader coverage. Custom network policies could enforce the
   mocking boundary.
3. **Functional evals** — exercise the full agent pipeline against real
   GitHub fixtures. More expensive because they interact with live services,
   so their number should be kept deliberately small — enough to cover the
   critical integration paths, not exhaustive.
4. **E2e tests** — browser-driven install/uninstall flows (`make e2e-test`).
   The most expensive layer; limited to a narrow happy-path verification of
   the admin install/uninstall flow.

Each layer up the pyramid costs more per case and should therefore have fewer
cases. This ADR addresses layer 3. Layer 2 remains an open opportunity.

## Decision

We adopt **functional evals** as a distinct test category for agent pipelines.

A functional eval exercises the full `fullsend run` pipeline — dispatch,
sandbox setup, agent execution, and post-processing — against a controlled
GitHub fixture (ephemeral repo + issue/PR), then scores the agent's observable
side effects (labels applied, comments posted, PR state) using both
deterministic checks and LLM-graded rubrics.

The eval infrastructure lives in `eval/` at the repo root, organized per
agent skill:

```
eval/
  fullsend-runner.sh          # CLI runner: fixture setup -> fullsend run -> capture state
  run-functional.sh           # Orchestrator: iterate cases, score
  <skill>/
    eval.yaml                 # Eval config: judges, thresholds, models
    cases/
      001-<name>/
        input.yaml            # Fixture definition
        annotations.yaml      # Expected state and rubric hints
        repo/                 # Source tree the agent sees
    repos/                    # Shared repo content, symlinked by cases
```

Functional evals run in CI when `eval/` or `internal/scaffold/` changes, and
are triggered via `make functional-evals`. They are gated on score thresholds
(e.g., `min_mean: 2.5` for LLM quality, `min_pass_rate: 0.9` for
deterministic checks) rather than binary pass/fail, acknowledging the
non-determinism inherent in agent behavior.

## Consequences

- The test pyramid now has three implemented layers (unit, functional eval,
  e2e) with a fourth (prompt eval) identified but not yet built. Each layer
  has a distinct scope, cost profile, and trigger.
- Functional evals require cloud credentials (GCP for Vertex AI, GitHub token
  for fixture repos), so they cannot run in unprivileged CI contexts.
- Adding a new agent skill's eval requires only a new directory under `eval/`
  with the standard case layout — no framework code changes.
- LLM-as-judge introduces a second layer of non-determinism: both the agent
  under test and the judge are probabilistic. Threshold-based gating mitigates
  this but does not eliminate flakiness.
- The `eval/` directory is a new top-level concern that contributors need to
  know about. Documentation belongs in `docs/testing/evals.md`.
- Functional eval count should be monitored to prevent bloat. Because each
  case interacts with live services, the suite's cost and runtime scale
  directly with case count.
- This decision does not preclude a lighter-weight prompt eval layer that
  tests agent prompts and skills without the full pipeline. Such a layer
  would complement functional evals by covering more cases at lower cost.
