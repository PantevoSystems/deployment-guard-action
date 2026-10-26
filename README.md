# 🛡️ Deployment Guard Action

[![Deployment Guard](https://api.pantevosystems.com/badge/2Yg2FpGsCnQ60zKgsURzH5fk3myKtoX5.svg)](https://www.pantevosystems.com)

Deterministic risk score before every deployment. Analyses your code changes automatically and blocks risky deployments. A formula you can follow — not a black box.

**By [PantevoSystems](https://www.pantevosystems.com)** · [Deutsch](README.de.md)

---

## Quick start

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

- name: Deployment Guard
  uses: PantevoSystems/deployment-guard-action@v1
  with:
    api-key: ${{ secrets.GUARD_API_KEY }}
```

> ⚠️ **Full history required.** Use `fetch-depth: 0` (recommended). `fetch-depth: 2` only covers single-commit pushes — for pushes with several commits or for pull requests the base commit is missing. The action diffs against `github.event.before` (push), `pull_request.base.sha` (pull request) or `HEAD~1` (fallback); you can override the base with the env variable `GUARD_DIFF_BASE`. If the base commit is missing from a shallow clone, the step **fails** instead of silently scoring an empty diff.

> 🏷️ **Tag, release and `workflow_dispatch` deploys:** these events have no usable "before" commit, so the action falls back to `HEAD~1` and only the last commit is scored. The log then shows `[guard] WARNING: diff base fell back to HEAD~1` plus a workflow warning. Set `GUARD_DIFF_BASE` (e.g. the previously deployed tag or SHA) for such deploys:
>
> ```yaml
> env:
>   GUARD_DIFF_BASE: ${{ steps.last-deploy.outputs.sha }}   # e.g. the previous release tag
> ```

> 📌 **Pinning:** reference `@v1` (major tag) or, for maximum supply-chain safety, a full commit SHA (`PantevoSystems/deployment-guard-action@<sha> # v1.x.y`). Never use `@main`.

---

## What the action sends

Each run sends one JSON request to `<api-url>/analyze`. It contains:

- repository name (`owner/repo`), branch name and commit SHA
- the **paths** of the changed files (max. 500 paths, each truncated to 300 characters) — **no file contents**
- line and file counts of the diff (lines added / removed, files changed)
- Kubernetes/Helm flags: number of changed manifests, single replica, missing PDB, Helm values changed, chart bumped
- dependency file changes and the number of major version bumps
- finding counts from Trivy, Semgrep and Checkov (when passed in)
- incident counts for the last 7 / 30 days (when passed in)
- repo type indicators (Dockerfile, Python/Node dependencies, Terraform, `setup.py` present: yes/no)
- since v1.9.0, git metrics as plain numbers: number of touched directories, spread of the change, number of people and commits that changed these files in the last year, previous commits of the author, reverts and hotfixes in the last 7 / 30 days
- since v1.9.0, the SHAs of commits this push reverts via `git revert`, and whether the push is a hotfix (commit subject starts with `hotfix`). This measures how accurate earlier scores were.

Not transmitted: source code, diff contents, file contents, commit messages, names, email addresses. Git metrics are computed on the runner; with a shallow clone they are not sent.

The risk score is a **deterministic formula** — same input, same result. No language model takes part in the calculation. The explanation text is generated afterwards by an OpenAI language model from the computed factors and the changed file paths; it does not change the score.

---

## Full example

```yaml
name: Deploy

on:
  push:
    branches: [ main, master ]

jobs:
  risk-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Deployment Guard
        id: guard
        uses: PantevoSystems/deployment-guard-action@v1
        with:
          api-key: ${{ secrets.GUARD_API_KEY }}
          fail-on-blocked: 'true'
          incidents-last-7d: '0'
          incidents-last-30d: '0'

      - name: Show score
        # Pass outputs via env — never interpolate ${{ }} directly into run:
        env:
          SCORE: ${{ steps.guard.outputs.score }}
          STATUS: ${{ steps.guard.outputs.status }}
          VERDICT: ${{ steps.guard.outputs.verdict }}
        run: |
          echo "Score:   $SCORE"
          echo "Status:  $STATUS"
          echo "Verdict: $VERDICT"

  deploy:
    needs: risk-check
    runs-on: ubuntu-latest
    steps:
      - name: Deploy
        run: echo "Your deploy step here"
```

---

## With the Pipeline Security Stack (Team plan)

For a full DevSecOps stack — Trivy, Semgrep and Checkov run first, and their findings feed straight into the risk score:

```yaml
jobs:
  security:
    uses: PantevoSystems/pipeline-security-templates/.github/workflows/full-stack-with-guard.yml@v1.2.5
    permissions:
      contents: read
      security-events: write
      actions: read
    with:
      trivy-dockerfile: 'Dockerfile'
      semgrep-config: 'p/default'
      checkov-directory: '.'
    secrets:
      guard-api-key: ${{ secrets.GUARD_API_KEY }}
```

Templates: [PantevoSystems/pipeline-security-templates](https://github.com/PantevoSystems/pipeline-security-templates) (MIT licence)

---

## Inputs

| Input | Description | Required | Default |
|---|---|---|---|
| `api-key` | Deployment Guard API key (the step fails if it is empty) | ✅ | — |
| `fail-on-blocked` | Fail the pipeline on BLOCKED (`true`/`false` only — any other value fails the step) | ❌ | `true` |
| `fail-open` | `true`: only outages — API unreachable/timeout, HTTP 429, HTTP 5xx or an invalid body on HTTP 200 — warn and the deployment continues. `false`: these cases fail the step. All other HTTP statuses always fail | ❌ | `true` |
| `api-url` | API base URL (must be `https://`) | ❌ | `https://api.pantevosystems.com` |
| `incidents-last-7d` | Production incidents in the last 7 days (pass manually) | ❌ | `0` |
| `incidents-last-30d` | Production incidents in the last 30 days (pass manually) | ❌ | `0` |
| `trivy-critical-cves` | CRITICAL CVEs from Trivy (CVSS ≥ 9.0) | ❌ | `0` |
| `trivy-high-cves` | HIGH CVEs from Trivy (CVSS 7.0–8.9) | ❌ | `0` |
| `semgrep-findings` | Total Semgrep findings | ❌ | `0` |
| `semgrep-high-severity` | HIGH-severity Semgrep findings (level=error) | ❌ | `0` |
| `checkov-failed-checks` | Failed Checkov checks | ❌ | `0` |
| `checkov-critical-failures` | CRITICAL Checkov failures | ❌ | `0` |
| `diff-changed-paths` | Comma-separated list of changed paths (overrides auto-detection) | ❌ | — |

All count inputs must be non-negative integers — anything else fails the step.

---

## Failure handling (advisory by default)

| Situation | `fail-open: 'true'` (default) | `fail-open: 'false'` |
|---|---|---|
| API unreachable / timeout | ⚠️ warning, deployment continues | ❌ step fails |
| HTTP 429 (analysis limit) | ⚠️ warning, deployment continues | ❌ step fails |
| HTTP 5xx | ⚠️ warning, deployment continues | ❌ step fails |
| HTTP 200 with invalid body (no JSON, status not PASS/WARN/BLOCKED, bad score) | ⚠️ warning, deployment continues | ❌ step fails |
| `api-key` empty | ❌ always fails | ❌ always fails |
| HTTP 401/403 (invalid API key) | ❌ always fails | ❌ always fails |
| HTTP 400/422 (rejected request) | ❌ always fails | ❌ always fails |
| Any other status: 3xx redirect (never followed — the key is not sent on), 402, 404, 405, 407, 413, … | ❌ always fails | ❌ always fails |
| `fail-open` / `fail-on-blocked` not exactly `true` or `false` | ❌ always fails | ❌ always fails |
| Base commit missing (shallow clone) | ❌ always fails | ❌ always fails |

Deployment Guard is an advisory gate: an outage of our API (network, timeout, 429, 5xx, broken 200 body) never stops your deployments. Everything else — misconfiguration (missing or wrong key, invalid input, wrong `api-url`, proxy or redirect) — always fails, so the gate cannot be bypassed by accident. Set `fail-open: 'false'` if your deployments must never run without a score.

---

## Outputs

| Output | Description |
|---|---|
| `score` | Risk score (0–100) |
| `verdict` | LOW RISK / MEDIUM RISK / HIGH RISK / CRITICAL RISK |
| `status` | PASS / WARN / BLOCKED |
| `explanation` | Plain-language explanation of the score |

---

## What is detected automatically?

The action derives these factors from the git diff on its own:

### Diff complexity
- Lines changed (added + removed)
- Files changed (binary files count as changed files without line counts)

> 🔒 **`.gitattributes` cannot hide changes.** All diffs run with the repository's attributes disabled (`attr.tree` = empty tree, git ≥ 2.40), so a `* -diff` or `binary` entry in `.gitattributes` does not turn line counts into 0. A changed `.gitattributes` is flagged in the log.

### Kubernetes risk
Real K8s manifests are identified by their `kind:` field. Excluded:
- GitHub Actions workflows (`.github/`)
- `action.yml` / `action.yaml`
- Helm templates (`templates/`)

Detected risks:
- Number of changed K8s manifests
- `replicas: 1` in a Deployment → single replica flag
- Deployment present but no `PodDisruptionBudget` → missing PDB flag

### Helm parameters
- `helm_values_changed` — YAML files containing `image:`, `tag:`, `replicaCount:` or `resources:`
- `helm_chart_bumped` — `Chart.yaml` or `Chart.yml` changed

### Dependency changes
Detects changes to:
`package.json`, `requirements.txt`, `go.mod`, `pom.xml`, `Gemfile`, `Cargo.toml`, `yarn.lock`, `package-lock.json`

> This factor measures **how much** your dependencies moved, not whether the new versions are secure. Known vulnerabilities are covered separately by the pipeline findings below.

### Major version bumps
Detected automatically in:
- `package.json` — major version numbers compared
- `requirements.txt` — `==X.y.z` version numbers compared
- `go.mod` — `/vX` module paths compared

### Incident history
**Not** detected automatically for the current score (1.0) — pass it yourself. Since v1.9.0 the action also counts reverts and hotfixes of the last 7 / 30 days from the git history; the upcoming score version 2.0 uses the higher of both values:

```yaml
- name: Deployment Guard
  uses: PantevoSystems/deployment-guard-action@v1
  with:
    api-key: ${{ secrets.GUARD_API_KEY }}
    incidents-last-7d: '2'
    incidents-last-30d: '5'
```

### Pipeline findings (optional)
**Not** detected automatically — they are passed through by the [Pipeline Security Templates](https://github.com/PantevoSystems/pipeline-security-templates). In a standalone setup just leave them out and every field stays at 0.

Fields: `trivy-critical-cves`, `trivy-high-cves`, `semgrep-findings`, `semgrep-high-severity`, `checkov-failed-checks`, `checkov-critical-failures`

---

## How the score works

| Score | Verdict | Status |
|---|---|---|
| 0–49 | LOW RISK | ✅ PASS |
| 50–74 | MEDIUM RISK | ⚠️ WARN |
| 75–84 | HIGH RISK | ❌ BLOCKED |
| 85–100 | CRITICAL RISK | ❌ BLOCKED |

### Factor weighting

Every factor is scored on its own scale from 0 to 100. How much it counts towards the total depends on the context of your repository:

| Mode | Diff | K8s | Dependencies | Incidents | Findings |
|---|---|---|---|---|---|
| no K8s, no findings | 42% | — | 32% | 26% | — |
| K8s, no findings | 30% | 30% | 20% | 20% | — |
| no K8s, with findings | 36% | — | 27% | 22% | 15% |
| K8s, with findings | 26% | 26% | 17% | 16% | 15% |

Those are the defaults. When the repo type is detected, type-specific weights override this table — Kubernetes counts up to 55 percent in an infrastructure repo, dependencies up to 50 percent in a library.

The weights adapt to context, so a frontend repo without Kubernetes gets a score that is just as fair as a full-stack repo with Helm charts and pipeline scans.

> These figures describe **scoring formula v1.0**. Every analysis records the formula version that produced it, so a score from months ago stays reproducible after the formula changes.

**Repo history as context:** every analysis compares the current score against the median and trend of earlier analyses of the same repository. A score well above the median is nudged up (max. +5); one that follows the usual pattern can be softened slightly (max. −3). Active from 5 historical analyses onwards.

### Adjustment layers

Four layers are applied on top of the base score:

| Layer | Effect | Description |
|---|---|---|
| Repo history | −3 to +5 | Compared against median and trend of earlier analyses |
| Time awareness | up to +25 | Friday afternoons, weekends and late-night deploys carry more risk |
| Path classification | −5 to +20 | High-risk paths (`auth/`, `migrations/`) count for more than `docs/` or `tests/` |
| Repo type | overrides weighting | Frontend / backend API / infrastructure / library — detected automatically |

**Repo type detection:**
- `Dockerfile` + Python deps → backend API
- `package.json` without a Dockerfile → frontend
- Terraform files (`.tf`) → infrastructure
- `setup.py` without a Dockerfile → library
- Otherwise → unknown (default weighting)

The action sends these indicators to the backend automatically — no configuration needed.

---

## Common problems

### The K8s score is 0 even though I changed manifests

Manifests are identified by their `kind:` field. Check that:
- your YAML contains `kind: Deployment`, `kind: Service` and so on
- the file is not inside `.github/` or `templates/`
- `fetch-depth: 0` is set on `actions/checkout`

### The score is always LOW even after large changes

Incident history (`incidents-last-7d`, `incidents-last-30d`) defaults to 0. If your team had production incidents, pass them in.

### The pipeline does not fail on BLOCKED

Make sure `fail-on-blocked: 'true'` is set (it is the default), and that `continue-on-error: true` is not set on the step — otherwise the gate cannot stop anything.

---

## Debug output

The action prints every detected value before calling the API:

```
  [guard] diff_lines_added:     245
  [guard] diff_lines_removed:   88
  [guard] diff_files_changed:   12
  [guard] k8s_manifests:        3
  [guard] single_replica:       true
  [guard] missing_pdb:          true
  [guard] helm_values_changed:  1
  [guard] helm_chart_bumped:    false
  [guard] dependency_updates:   2
  [guard] major_version_bumps:  1
  [guard] incidents_7d:         0
  [guard] incidents_30d:        0
  [guard] trivy_critical:       0
  [guard] trivy_high:           0
  [guard] semgrep_findings:     0
  [guard] semgrep_high:         0
  [guard] checkov_failed:       0
  [guard] checkov_critical:     0
  [guard] changed_paths:        app/auth/login.py,docs/readme.md
  [guard] has_dockerfile:       true
  [guard] has_python_deps:      true
  [guard] has_node_deps:        false
  [guard] has_terraform:        false
  [guard] has_setup_py:         false
```

After the analysis the score breakdown is printed as well — each factor with its value, weight and contribution, plus the mode and any adjustments that were applied.

---

## Getting an API key

1. [pantevosystems.com/signup](https://www.pantevosystems.com/signup) → Free plan (no credit card)
2. Store the key as a GitHub secret: **Settings → Secrets and variables → Actions → New repository secret → `GUARD_API_KEY`**
3. Add the action to your workflow — done

---

## Score badge

Show the latest risk score of your repository right in your README — like the one at the top of this page:

```markdown
[![Deployment Guard](https://api.pantevosystems.com/badge/YOUR-TOKEN.svg)](https://www.pantevosystems.com)
```

Create the badge in the [dashboard](https://www.pantevosystems.com/dashboard) under **Settings → Integrations → Score badge**, then copy the generated Markdown. The colour follows your own thresholds — green below WARN, orange in between, red from BLOCKED upwards.

The URL carries a random token. Neither the repository name nor your account can be derived from it, and the only thing it exposes is the current score. You can revoke a badge from the dashboard at any time.

---

## Links

- 🌐 [pantevosystems.com](https://www.pantevosystems.com)
- 📊 [Dashboard](https://www.pantevosystems.com/dashboard)
- 🚀 [Get an API key](https://www.pantevosystems.com/signup)
- 📧 [support@pantevosystems.com](mailto:support@pantevosystems.com)