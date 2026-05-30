---
name: fullsend-architecture
description: >
  Domain knowledge about fullsend install modes (per-org vs per-repo) and
  mint/inference resource separation (WIF pools, providers, IAM). Use when
  working on install, provisioning, enrollment, or WIF-related code to avoid
  common misconceptions.
allowed-tools: Bash
---

# Fullsend Architecture: Install Modes & Resource Separation

Quick-reference for agents working on install, provisioning, enrollment, or
WIF-related code. The two most common sources of agent confusion are:
1. Confusing per-org vs per-repo install semantics
2. Mixing up mint vs inference WIF resources

## Install Modes

The CLI argument format determines the mode — both use the same `install`
subcommand. The code branches on `strings.Contains(arg, "/")` in admin.go.

```
fullsend admin install acme          -> per-org mode  (no slash)
fullsend admin install acme/widget   -> per-repo mode (has slash)
```

### Per-org mode

Creates centralized infrastructure for an entire GitHub organization:

- Creates a `.fullsend` config repo (public, holds config.yaml, shim workflows)
- Creates per-role GitHub Apps via manifest flow (browser-based)
- Deploys a Cloud Function token mint to a GCP project
- Stores PEM secrets in GCP Secret Manager
- Enrolls repos by updating config.yaml (enabled: true/false)
- Enrollment triggers repo-maintenance workflow to create PRs in target repos

Key flags: `--enroll-all`, `--enroll-none` (per-org ONLY -- rejected in per-repo)
Default roles: fullsend, triage, coder, review, retro, prioritize

### Per-repo mode

Bootstraps a single repository without requiring a config repo:

- Writes `.github/workflows/fullsend.yaml` and `.fullsend/config.yaml` directly
- Sets repo-level variables (`FULLSEND_MINT_URL`, `FULLSEND_GCP_REGION`) and
  secrets (`FULLSEND_GCP_PROJECT_ID`, `FULLSEND_GCP_WIF_PROVIDER`)
- Sets guard variable `FULLSEND_PER_REPO_INSTALL=true` to prevent per-org
  enrollment from overwriting it
- Creates a dedicated WIF provider per repo (`gh-{owner}-{repo}`)
- No config repo, no cross-repo dispatch
- Requires `--inference-project` (mandatory, unlike per-org where it's optional)

Default roles: triage, coder, review, fix, retro, prioritize
Note: the "fullsend" role is EXCLUDED -- per-repo uses the target repo's own
shim for dispatch instead of a separate fullsend app.

### Flag scope

Unified flags (work in both modes):
  `--agents`, `--dry-run`, `--vendor-fullsend-binary`, `--inference-project`,
  `--inference-region`, `--inference-wif-provider`, `--mint-provider`,
  `--mint-project`, `--mint-region`, `--mint-source-dir`, `--skip-mint-deploy`,
  `--skip-mint-check`, `--public`, `--app-set`, `--mint-url`, `--skip-app-setup`

Per-org ONLY flags (rejected in per-repo with an error):
  `--enroll-all`, `--enroll-none`

Per-repo specifics:
  `--inference-project` is REQUIRED (optional in per-org).
  `--mint-project` defaults to `--inference-project` if not set.
  Guard variable prevents per-org from overwriting per-repo installs.

### Shared app sets

When `--public` is used, GitHub Apps are created as public (unlisted) and can
be installed by multiple orgs. The `--app-set` flag controls the app name
prefix:

```
--app-set=fullsend-ai  ->  apps named fullsend-ai-coder, fullsend-ai-review, etc.
Default app set: "fullsend-ai"
Legacy app sets checked during uninstall: ["fullsend"]
```

For shared apps, PEMs are tied to the APP, not the org. When enrolling a new
org that uses a shared app, PEMs are COPIED from the app set's secret
(`fullsend-{app-set}--{role}-app-pem`) to the org's secret
(`fullsend-{org}--{role}-app-pem`).

The `ROLE_APP_IDS` env var on the mint function maps org-scoped keys to app IDs:
```json
{"acme/coder": "12345", "acme/review": "12346", "beta/coder": "12345"}
```
Multiple orgs can share the same app ID when using public apps.

---

## Mint vs Inference Resource Separation

The mint and inference subsystems use SEPARATE WIF pools. This prevents
lifecycle operations on one from interfering with the other.

| Resource          | Mint                      | Inference                  |
|-------------------|---------------------------|----------------------------|
| WIF pool          | `fullsend-pool`           | `fullsend-inference`       |
| WIF provider (org)| `github-oidc` in mint pool| `github-oidc` in inference pool |
| WIF provider (repo)| registered in `PER_REPO_WIF_REPOS` | `gh-{owner}-{repo}` in inference pool |
| Service account   | `fullsend-mint@{project}` | None (direct WIF)          |
| Cloud Function    | `fullsend-mint`           | None                       |
| IAM role          | invoker on the function   | `roles/aiplatform.user`    |

### Mint infrastructure (token minting)

Purpose: Exchange GitHub OIDC JWTs for scoped GitHub App installation tokens.
Managed by: `fullsend mint deploy/enroll/unenroll`, `fullsend admin install`

GCP resources:
- Service account: `fullsend-mint@{project}.iam.gserviceaccount.com`
- WIF pool: `fullsend-pool` (const `defaultPool` in provisioner.go)
- WIF provider: `github-oidc` (org-scoped, shared provider with CEL condition)
- Cloud Function: `fullsend-mint` (deployed as GCF gen2 / Cloud Run)
- Secrets: `fullsend-{org}--{role}-app-pem` (one per org/role in Secret Manager)

Env vars on the Cloud Function:
  `ALLOWED_ORGS`, `ROLE_APP_IDS`, `ALLOWED_ROLES`, `ALLOWED_WORKFLOW_FILES`,
  `GCP_PROJECT_NUMBER`, `WIF_POOL_NAME`, `WIF_PROVIDER_NAME`, `OIDC_AUDIENCE`,
  `PER_REPO_WIF_REPOS`, `FULLSEND_SOURCE_HASH`

The mint pool's WIF provider attribute condition scopes to `repository_owner`:
```
assertion.repository_owner == 'acme'
assertion.repository_owner in ['acme', 'beta']
```

### Inference infrastructure (AI model access)

Purpose: Allow GitHub Actions workflows to authenticate to Vertex AI Agent
Platform for LLM inference via WIF (no service account key needed).
Managed by: `fullsend inference provision/status/deprovision`, or auto-provisioned
during `fullsend admin install` when `--inference-project` is set.

GCP resources:
- WIF pool: `fullsend-inference` (const `DefaultInferencePool` in provisioner.go)
- WIF provider:
  - Org-scoped: `github-oidc` (in the inference pool, NOT the mint pool)
  - Repo-scoped: `gh-{owner}-{repo}` (dedicated provider per repo)
- IAM binding: `roles/aiplatform.user` granted to WIF principalSet
- NO service account needed -- uses direct WIF (principalSet to project IAM)
- NO Cloud Function -- workflows authenticate directly to Vertex AI

The inference pool's WIF condition follows the same pattern as mint but in a
DIFFERENT pool:
```
Org-scoped:  assertion.repository_owner == 'acme'
Repo-scoped: assertion.repository == 'acme/widget'
```

### Per-repo WIF providers

Per-repo mode creates dedicated WIF providers in BOTH pools:

**Mint side:**
- Repo registered in `PER_REPO_WIF_REPOS` env var on the Cloud Function
- Created by: `fullsend mint enroll <owner/repo>`
- Condition: `assertion.repository == '{owner}/{repo}'`

**Inference side:**
- Provider ID: `gh-{owner}-{repo}` in the `fullsend-inference` pool
- Created by: `fullsend admin install <owner/repo>` or `fullsend inference provision <owner/repo>`
- Condition: `assertion.repository == '{owner}/{repo}'`
- IAM: `roles/aiplatform.user` granted to the repo's principalSet

The provider IDs may look identical but live in DIFFERENT pools.

### CLI command mapping

```
fullsend mint deploy           -> deploys Cloud Function + mint WIF (fullsend-pool)
fullsend mint enroll           -> registers org/repo in mint, copies PEMs
fullsend mint unenroll         -> removes org/repo from mint
fullsend mint status           -> shows mint health

fullsend inference provision   -> creates inference WIF (fullsend-inference)
fullsend inference status      -> checks inference WIF health
fullsend inference deprovision -> removes org/repo from inference WIF

fullsend admin install         -> does BOTH: provisions mint AND inference
                                  (when --inference-project is provided)
```

---

## Key Code Locations

```
cmd/fullsend/main.go                    -> CLI entry point
internal/cli/admin.go                   -> install/uninstall/enable/disable
internal/appsetup/appsetup.go           -> GitHub App manifest flow, shared apps
internal/config/config.go               -> org/repo config model
internal/cli/mint.go                    -> mint deploy/enroll/unenroll/status
internal/cli/inference.go               -> inference provision/status/deprovision
internal/dispatch/gcf/provisioner.go    -> GCF mint provisioner (WIF, PEMs, deploy)
internal/mint/main.go                   -> Cloud Function source (token exchange)
```

---

## Common Mistakes to Avoid

### Install mode mistakes

WRONG: "per-org and per-repo are different commands"
RIGHT: Same command, mode determined by whether the argument contains a slash.

WRONG: "per-repo mode doesn't need GCP infrastructure"
RIGHT: Per-repo still needs mint + inference WIF, just with repo-scoped providers.

WRONG: "--enroll-all works for per-repo"
RIGHT: `--enroll-all` and `--enroll-none` are per-org ONLY flags.

WRONG: "per-repo uses the fullsend role"
RIGHT: Per-repo excludes the fullsend dispatch role; it uses the repo's own shim.

WRONG: "each org gets its own GitHub Apps"
RIGHT: With `--public`, apps are shared across orgs via the app set; PEMs are copied.

### Resource separation mistakes

WRONG: "the WIF pool is shared between mint and inference"
RIGHT: Separate pools -- `fullsend-pool` (mint) and `fullsend-inference` (inference).

WRONG: "inference needs a service account"
RIGHT: Inference uses direct WIF -- principalSet binding to the project, no SA.

WRONG: "the mint pool name is fullsend-inference"
RIGHT: Mint uses `fullsend-pool`; inference uses `fullsend-inference`.

WRONG: "per-repo WIF providers are only needed for inference"
RIGHT: Per-repo mode creates providers in BOTH pools.

WRONG: "mint enroll also sets up inference"
RIGHT: `mint enroll` only handles the mint side; run `inference provision` separately.
