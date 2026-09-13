# 🛡️ Deployment Guard Action

Deterministic risk score before every deployment. Analyses your code changes automatically and blocks risky deployments. A formula you can follow — not a black box.

**By [PantevoSystems](https://www.pantevosystems.com)** · [Deutsch](README.de.md)

---

## Quick start

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 2

- name: Deployment Guard
  uses: PantevoSystems/deployment-guard-action@v1
  with:
    api-key: ${{ secrets.GUARD_API_KEY }}
```

> ⚠️ `fetch-depth: 2` is required — without the previous commit there is no diff to analyse.

---

## Full example

```yaml
name: Deploy

on:
  push:
    branches: [ main ]

jobs:
  risk-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Deployment Guard
        id: guard
        uses: PantevoSystems/deployment-guard-action@v1
        with:
          api-key: ${{ secrets.GUARD_API_KEY }}
          fail-on-blocked: 'true'
          incidents-last-7d: '0'
          incidents-last-30d: '0'

      - name: Show score
        run: |
          echo "Score:   ${{ steps.guard.outputs.score }}"
          echo "Status:  ${{ steps.guard.outputs.status }}"
          echo "Verdict: ${{ steps.guard.outputs.verdict }}"

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
    uses: PantevoSystems/pipeline-security-templates/.github/workflows/full-stack-with-guard.yml@v1.2.0
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
| `api-key` | Deployment Guard API key | ✅ | — |
| `fail-on-blocked` | Fail the pipeline on BLOCKED | ❌ | `true` |
| `incidents-last-7d` | Production incidents in the last 7 days (pass manually) | ❌ | `0` |
| `incidents-last-30d` | Production incidents in the last 30 days (pass manually) | ❌ | `0` |
| `trivy-critical-cves` | CRITICAL CVEs from Trivy (CVSS ≥ 9.0) | ❌ | `0` |
| `trivy-high-cves` | HIGH CVEs from Trivy (CVSS 7.0–8.9) | ❌ | `0` |
| `semgrep-findings` | Total Semgrep findings | ❌ | `0` |
| `semgrep-high-severity` | HIGH-severity Semgrep findings (level=error) | ❌ | `0` |
| `checkov-failed-checks` | Failed Checkov checks | ❌ | `0` |
| `checkov-critical-failures` | CRITICAL Checkov failures | ❌ | `0` |

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
- Files changed

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
**Not** detected automatically — pass it yourself:

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
- `fetch-depth: 2` is set

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

## Links

- 🌐 [pantevosystems.com](https://www.pantevosystems.com)
- 📊 [Dashboard](https://www.pantevosystems.com/dashboard)
- 🚀 [Get an API key](https://www.pantevosystems.com/signup)
- 📧 [support@pantevosystems.com](mailto:support@pantevosystems.com)