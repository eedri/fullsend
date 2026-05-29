---
title: "45. agent-eval-harness for eval infrastructure"
status: Accepted
relates_to:
  - testing-agents
topics:
  - testing
  - evals
---

# 45. agent-eval-harness for eval infrastructure

Date: 2026-05-29

## Status

Accepted

<!-- Once this ADR is Accepted, its content is frozen. Do not edit the Context,
     Decision, or Consequences sections. If circumstances change, write a new
     ADR that supersedes this one. Only status changes and links to superseding
     ADRs should be added after acceptance. -->

## Context

[ADR 0044](0044-functional-evals-for-agent-pipelines.md) establishes
functional evals as a test category. That decision is silent on which
framework orchestrates them — it could be custom scripts, Inspect AI, or
something else.

Building eval infrastructure from scratch is expensive and tangential to our
core problem. We need test case management, judge orchestration, scoring,
threshold gating, and regression detection. We do not need to build any of
these ourselves.

[agent-eval-harness](https://github.com/opendatahub-io/agent-eval-harness)
is a generic evaluation framework for agents and skills. It provides dataset
management, LLM-graded and deterministic judges, scoring pipelines, MLflow
integration, and an
[opaque CLI runner contract](https://github.com/opendatahub-io/agent-eval-harness/blob/main/docs/opaque-cli-runner-contract.md)
that delegates execution to an external command. The CLI runner was added in
[issue #59](https://github.com/opendatahub-io/agent-eval-harness/issues/59),
which we filed specifically to make `fullsend run` testable without forking
or extending the harness with fullsend-specific code.

## Decision

We adopt agent-eval-harness as the eval framework for fullsend functional
evals. Fullsend's `eval/fullsend-runner.sh` implements the opaque CLI runner
contract — it accepts a workspace and output directory, runs `fullsend run`
inside a sandbox, and writes captured fixture state to the output directory.
Everything upstream (case iteration, judge invocation, scoring, thresholds)
is handled by agent-eval-harness.

When adding new eval capabilities, prefer extending or contributing to
agent-eval-harness over building fullsend-specific tooling.

## Consequences

- Fullsend evals inherit agent-eval-harness capabilities (MLflow logging,
  pairwise comparison, dataset generation) without building them.
- The opaque CLI runner contract is the integration boundary. Fullsend owns
  execution; the harness owns everything else.
- agent-eval-harness becomes a runtime dependency for eval execution, adding
  a Python dependency alongside the Go codebase.
- Bugs or gaps in agent-eval-harness may require upstream contributions. We
  have already done this once (issue #59).
- Future prompt evals (layer 2 in the test pyramid) can reuse the same
  harness with a different runner, keeping eval infrastructure unified.
