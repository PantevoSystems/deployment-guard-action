# 🛡️ Deployment Guard Action

Deterministischer Risk Score vor jedem Deployment. Analysiert Code-Änderungen automatisch und blockiert riskante Deployments. Nachvollziehbare Formel, keine Black Box.

**Von [PantevoSystems](https://www.pantevosystems.com)** · [English](README.md)

---

## Schnellstart

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 2

- name: Deployment Guard
  uses: PantevoSystems/deployment-guard-action@v1
  with:
    api-key: ${{ secrets.GUARD_API_KEY }}
```

> ⚠️ `fetch-depth: 2` ist erforderlich — ohne den vorherigen Commit kann kein Diff berechnet werden.

---

## Vollständiges Beispiel

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

      - name: Score anzeigen
        run: |
          echo "Score:   ${{ steps.guard.outputs.score }}"
          echo "Status:  ${{ steps.guard.outputs.status }}"
          echo "Verdict: ${{ steps.guard.outputs.verdict }}"

  deploy:
    needs: risk-check
    runs-on: ubuntu-latest
    steps:
      - name: Deploy
        run: echo "Dein Deploy-Schritt hier"
```

---

## Mit Pipeline Security Stack (Team Plan)

Für vollständigen DevSecOps-Stack — Trivy + Semgrep + Checkov werden ausgeführt und Findings automatisch in den Risk Score gespeist:

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

Templates: [PantevoSystems/pipeline-security-templates](https://github.com/PantevoSystems/pipeline-security-templates) (MIT-Lizenz)

---

## Inputs

| Input | Beschreibung | Pflicht | Standard |
|---|---|---|---|
| `api-key` | Deployment Guard API Key | ✅ | — |
| `fail-on-blocked` | Pipeline bei BLOCKED fehlschlagen lassen | ❌ | `true` |
| `incidents-last-7d` | Produktionsvorfälle letzte 7 Tage (manuell angeben) | ❌ | `0` |
| `incidents-last-30d` | Produktionsvorfälle letzte 30 Tage (manuell angeben) | ❌ | `0` |
| `trivy-critical-cves` | Anzahl CRITICAL CVEs aus Trivy (CVSS ≥ 9.0) | ❌ | `0` |
| `trivy-high-cves` | Anzahl HIGH CVEs aus Trivy (CVSS 7.0-8.9) | ❌ | `0` |
| `semgrep-findings` | Gesamtanzahl Semgrep-Findings | ❌ | `0` |
| `semgrep-high-severity` | HIGH-Severity Semgrep-Findings (level=error) | ❌ | `0` |
| `checkov-failed-checks` | Fehlgeschlagene Checkov-Checks | ❌ | `0` |
| `checkov-critical-failures` | CRITICAL Checkov-Failures | ❌ | `0` |

---

## Outputs

| Output | Beschreibung |
|---|---|
| `score` | Risk Score (0–100) |
| `verdict` | LOW RISK / MEDIUM RISK / HIGH RISK / CRITICAL RISK |
| `status` | PASS / WARN / BLOCKED |
| `explanation` | Erklärung des Scores in verständlicher Sprache |

---

## Was wird automatisch erkannt?

Die Action erkennt folgende Faktoren automatisch aus dem Git-Diff:

### Diff-Komplexität
- Anzahl geänderter Zeilen (hinzugefügt + entfernt)
- Anzahl geänderter Dateien

### Kubernetes-Risiko
Erkennt echte K8s-Manifeste anhand des `kind:` Feldes. Ausgeschlossen werden:
- GitHub Actions Workflows (`.github/`)
- `action.yml` / `action.yaml`
- Helm Templates (`templates/`)

Erkannte Risiken:
- Anzahl geänderter K8s-Manifeste
- `replicas: 1` in einem Deployment → Single Replica Flag
- Deployment vorhanden aber kein `PodDisruptionBudget` → Missing PDB Flag

### Helm-Parameter
- `helm_values_changed` — YAML-Dateien mit `image:`, `tag:`, `replicaCount:` oder `resources:`
- `helm_chart_bumped` — `Chart.yaml` oder `Chart.yml` geändert

### Dependency-Änderungen
Erkennt Änderungen an:
`package.json`, `requirements.txt`, `go.mod`, `pom.xml`, `Gemfile`, `Cargo.toml`, `yarn.lock`, `package-lock.json`

> Dieser Faktor misst, **wie stark** sich die Dependencies bewegt haben — nicht, ob die neuen Versionen sicher sind. Bekannte Schwachstellen deckt der Pipeline-Findings-Teil weiter unten ab.

### Major Version Bumps
Erkennt Major-Upgrades automatisch in:
- `package.json` — Hauptversionsnummern verglichen
- `requirements.txt` — `==X.y.z` Versionsnummern verglichen
- `go.mod` — `/vX` Module-Pfade verglichen

### Fehlerhistorie
Wird **nicht** automatisch erkannt — muss manuell übergeben werden:

```yaml
- name: Deployment Guard
  uses: PantevoSystems/deployment-guard-action@v1
  with:
    api-key: ${{ secrets.GUARD_API_KEY }}
    incidents-last-7d: '2'
    incidents-last-30d: '5'
```

### Pipeline-Findings (optional)
Werden **nicht** automatisch erkannt — werden über die [Pipeline Security Templates](https://github.com/PantevoSystems/pipeline-security-templates) durchgereicht. Im Standalone-Setup einfach weglassen, dann sind alle Felder 0.

Felder: `trivy-critical-cves`, `trivy-high-cves`, `semgrep-findings`, `semgrep-high-severity`, `checkov-failed-checks`, `checkov-critical-failures`

---

## Score-Logik

| Score | Verdict | Status |
|---|---|---|
| 0–49 | LOW RISK | ✅ PASS |
| 50–74 | MEDIUM RISK | ⚠️ WARN |
| 75–84 | HIGH RISK | ❌ BLOCKED |
| 85–100 | CRITICAL RISK | ❌ BLOCKED |

### Gewichtung der Faktoren

Jeder Faktor wird für sich auf einer Skala von 0 bis 100 berechnet. Wie stark er in den Gesamtscore einfließt, hängt vom Kontext des Repositories ab:

| Modus | Diff | K8s | Dependencies | Fehlerhistorie | Findings |
|---|---|---|---|---|---|
| ohne K8s, ohne Findings | 42% | — | 32% | 26% | — |
| mit K8s, ohne Findings | 30% | 30% | 20% | 20% | — |
| ohne K8s, mit Findings | 36% | — | 27% | 22% | 15% |
| mit K8s, mit Findings | 26% | 26% | 17% | 16% | 15% |

Das sind die Standardwerte. Wird der Repo-Typ erkannt, überschreiben typspezifische Gewichtungen diese Tabelle — in einem Infrastructure-Repo zählt Kubernetes bis zu 55 Prozent, in einer Library zählen Dependencies bis zu 50 Prozent.

Die Gewichte passen sich dem Kontext an. Ein Frontend-Repo ohne Kubernetes bekommt damit einen genauso fairen Score wie ein Full-Stack-Repo mit Helm und Pipeline-Scans.

> Diese Werte beschreiben **Scoring-Formel v1.0**. Jede Analyse hält fest, welche Formelversion sie erzeugt hat — ein Score von vor Monaten bleibt damit nachvollziehbar, auch wenn sich die Formel später ändert.

**Repo-Historie als Kontext:** Bei jeder Analyse wird der aktuelle Score mit dem Median und Trend früherer Analysen desselben Repositories abgeglichen. Liegt der Score deutlich über dem Median, geht er leicht nach oben (max. +5). Folgt er dem üblichen Muster, kann er sich um wenige Punkte abmildern (max. -3). Ab 5 historischen Analysen aktiv.

### Adjustment-Layer

Auf den Basis-Score werden vier zusätzliche Layer angewendet:

| Layer | Auswirkung | Beschreibung |
|---|---|---|
| Repo-Historie | -3 bis +5 | Vergleich mit Median/Trend früherer Analysen |
| Time-Awareness | bis +25 | Friday-PM, Wochenende und Late-Night-Deploys = höheres Risiko |
| Pfad-Klassifizierung | -5 bis +20 | High-Risk-Pfade (`auth/`, `migrations/`) riskanter als `docs/`, `tests/` |
| Repo-Typ | überschreibt Gewichtung | Frontend / Backend-API / Infra / Library — automatisch erkannt |

**Repo-Typ wird automatisch erkannt:**
- `Dockerfile` + Python-Deps → Backend-API
- `package.json` ohne Dockerfile → Frontend
- Terraform-Files (`.tf`) → Infrastructure
- `setup.py` ohne Dockerfile → Library
- Sonst → Unknown (Standard-Gewichtung)

Die Action sendet diese Indikatoren automatisch ans Backend — keine manuelle Konfiguration nötig.

---

## Häufige Probleme

### K8s-Score ist 0 obwohl Manifeste geändert wurden

Die Action erkennt K8s-Manifeste anhand des `kind:` Feldes. Prüfe:
- Enthält deine YAML-Datei `kind: Deployment` / `kind: Service` etc.?
- Liegt die Datei nicht in `.github/` oder `templates/`?
- Ist `fetch-depth: 2` gesetzt?

### Score ist immer LOW obwohl viel geändert wurde

Fehlerhistorie (`incidents-last-7d`, `incidents-last-30d`) ist standardmäßig 0. Wenn dein Team Produktionsvorfälle hat, übergib diese manuell.

### Pipeline schlägt nicht fehl bei BLOCKED

Stelle sicher, dass `fail-on-blocked: 'true'` gesetzt ist (Standardwert). Und `continue-on-error: true` darf nicht gesetzt sein, wenn der Gate greifen soll.

---

## Debug-Output

Die Action gibt alle erkannten Werte vor dem API-Call aus:

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

Nach der Analyse folgt die Score-Aufschlüsselung — jeder Faktor mit Wert, Gewicht und Beitrag, dazu der Modus und die angewendeten Adjustments.

---

## API Key holen

1. [pantevosystems.com/signup](https://www.pantevosystems.com/signup) → Free Plan (kostenlos, keine Kreditkarte)
2. API Key als GitHub Secret anlegen: **Settings → Secrets and variables → Actions → New repository secret → `GUARD_API_KEY`**
3. Action einbinden — fertig

---

## Links

- 🌐 [pantevosystems.com](https://www.pantevosystems.com)
- 📊 [Dashboard](https://www.pantevosystems.com/dashboard)
- 🚀 [API Key holen](https://www.pantevosystems.com/signup)
- 📧 [support@pantevosystems.com](mailto:support@pantevosystems.com)
