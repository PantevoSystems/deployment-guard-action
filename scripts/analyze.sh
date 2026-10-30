#!/bin/bash
set -e

# ── Hilfsfunktionen ──────────────────────────────────────────────────────
die() {
  echo "❌ Deployment Guard: $*" >&2
  exit 1
}

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    od -An -tx1 -N8 /dev/urandom | tr -d ' \n'
  fi
}

# Workflow-Commands (::set-output, ::add-mask, ##[...]) in fremdem Text entschärfen.
# 1. Steuerzeichen außer \n und \t entfernen (u. a. \r, ESC/ANSI, NUL) — ein \r kann
#    sonst eine neue Log-Zeile beginnen, die der Runner als Workflow-Command liest.
# 2. Zeilen, die (nach Leerzeichen) mit "::" oder "##[" beginnen, bekommen ein Präfix.
sanitize() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' | sed -E 's/^([[:space:]]*)(::|##\[)/\1> \2/'
}

# Fremden Text (API-Antworten) ausgeben: bereinigt UND auf GitHub zusätzlich
# zwischen ::stop-commands:: — so wird er nie als Workflow-Command ausgewertet.
print_untrusted() {
  local token=""
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    token="dg$(rand_hex)$(rand_hex)"
    echo "::stop-commands::${token}"
  fi
  sanitize
  if [ -n "$token" ]; then
    echo ""
    echo "::${token}::"
  fi
}

# GITHUB_OUTPUT per Heredoc-Syntax mit zufälligem Delimiter schreiben —
# Zeilenumbrüche im Wert können so keine weiteren Outputs erzeugen.
set_output() {
  local name="$1" value="$2" delim
  delim="DG_$(rand_hex)"
  while [[ "$value" == *"$delim"* ]]; do
    delim="DG_$(rand_hex)"
  done
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
}

TMP_FILES=()
cleanup() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f -- "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

# new_tmp VARNAME — legt eine Temp-Datei (Modus 600) an und merkt sie für den trap vor
new_tmp() {
  local f
  f=$(umask 077 && mktemp "${RUNNER_TEMP:-/tmp}/dg.XXXXXXXX") || die "Temp-Datei konnte nicht angelegt werden."
  chmod 600 "$f"
  TMP_FILES+=("$f")
  printf -v "$1" '%s' "$f"
}

# ── Voraussetzungen & Inputs prüfen ──────────────────────────────────────
command -v jq   >/dev/null 2>&1 || die "'jq' wird benötigt, ist aber nicht installiert. Auf GitHub-hosted Runnern ist jq vorinstalliert — auf Self-hosted Runnern bitte jq installieren (z. B. apt-get install -y jq)."
command -v git  >/dev/null 2>&1 || die "'git' wird benötigt, ist aber nicht installiert."
command -v curl >/dev/null 2>&1 || die "'curl' wird benötigt, ist aber nicht installiert."

if [ -z "${GUARD_API_KEY:-}" ]; then
  die "api-key ist leer. Lege das Secret GUARD_API_KEY an und übergib es mit 'api-key: \${{ secrets.GUARD_API_KEY }}'. API Key: https://www.pantevosystems.com/signup"
fi
case "$GUARD_API_KEY" in
  *$'\n'*|*$'\r'*) die "api-key enthält Zeilenumbrüche — bitte das Secret prüfen." ;;
esac

FAIL_OPEN="${FAIL_OPEN:-true}"
case "$FAIL_OPEN" in
  true|false) ;;
  *) die "fail-open muss 'true' oder 'false' sein (erhalten: '${FAIL_OPEN}')." ;;
esac
FAIL_ON_BLOCKED="${FAIL_ON_BLOCKED:-true}"
case "$FAIL_ON_BLOCKED" in
  true|false) ;;
  *) die "fail-on-blocked muss 'true' oder 'false' sein (erhalten: '${FAIL_ON_BLOCKED}')." ;;
esac

LABEL_PR="${LABEL_PR:-true}"
case "$LABEL_PR" in
  true|false) ;;
  *) die "label-pr muss 'true' oder 'false' sein (erhalten: '${LABEL_PR}')." ;;
esac
POLICY_FILE="${POLICY_FILE:-.github/deployment-guard.yml}"
POLICY_FILE="${POLICY_FILE#./}"
ENFORCE_REVIEWS="${ENFORCE_REVIEWS:-false}"
case "$ENFORCE_REVIEWS" in
  true|false) ;;
  *) die "enforce-reviews muss 'true' oder 'false' sein (erhalten: '${ENFORCE_REVIEWS}')." ;;
esac
if [ "$ENFORCE_REVIEWS" = "true" ] && [ -z "${GH_TOKEN_INPUT:-}" ]; then
  die "enforce-reviews braucht github-token (z. B. secrets.GITHUB_TOKEN)."
fi
# Wer Freigaben erzwingt, darf bei API-Ausfall nicht durchlassen
if [ "$ENFORCE_REVIEWS" = "true" ] && [[ "${GITHUB_EVENT_NAME:-}" == pull_request* ]] && [ "$FAIL_OPEN" = "true" ]; then
  echo "  [guard] enforce-reviews aktiv: fail-open wird für diesen Pull-Request-Check abgeschaltet."
  FAIL_OPEN="false"
fi
if ! [[ "$POLICY_FILE" =~ ^[A-Za-z0-9._/-]{1,200}$ ]] || [[ "$POLICY_FILE" == *..* ]] || [[ "$POLICY_FILE" == /* ]]; then
  die "policy-file muss ein relativer Pfad ohne '..' sein (erhalten: '${POLICY_FILE}')."
fi

# API-URL kommt ausschließlich über den Input 'api-url' (env API_URL), nicht aus geerbten Variablen.
API_URL="${API_URL:-https://api.pantevosystems.com}"
API_URL="${API_URL%/}"
if ! [[ "$API_URL" =~ ^https://[^[:space:]]+$ || "$API_URL" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/[^[:space:]]*)?$ ]]; then
  die "api-url muss mit https:// beginnen (erhalten: '${API_URL}')."
fi

HTTP_TIMEOUT="${GUARD_HTTP_TIMEOUT:-120}"
[[ "$HTTP_TIMEOUT" =~ ^[0-9]{1,4}$ ]] || die "GUARD_HTTP_TIMEOUT muss eine Zahl (Sekunden) sein."

# Numerische Inputs: nur ^[0-9]+$ erlaubt (max. 9 Stellen), sonst Abbruch.
num_input() {
  local label="$1" raw="$2" v
  v=$(printf '%s' "$raw" | tr -d ' \t\r\n')
  [ -z "$v" ] && v=0
  if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "${#v}" -gt 9 ]; then
    die "Input '${label}' muss eine nicht-negative ganze Zahl sein (erhalten: '${raw}')."
  fi
  printf '%s' "$((10#$v))"
}

INC7=$(num_input incidents-last-7d "${INCIDENTS_7D:-0}")
INC30=$(num_input incidents-last-30d "${INCIDENTS_30D:-0}")

# ── Pipeline Security Findings (Phase 2) ─────────────────────────────────
TRIVY_CRIT=$(num_input trivy-critical-cves "${TRIVY_CRITICAL_CVES:-0}")
TRIVY_HIGH=$(num_input trivy-high-cves "${TRIVY_HIGH_CVES:-0}")
SEM_TOTAL=$(num_input semgrep-findings "${SEMGREP_FINDINGS:-0}")
SEM_HIGH=$(num_input semgrep-high-severity "${SEMGREP_HIGH_SEVERITY:-0}")
CKV_TOTAL=$(num_input checkov-failed-checks "${CHECKOV_FAILED_CHECKS:-0}")
CKV_CRIT=$(num_input checkov-critical-failures "${CHECKOV_CRITICAL_FAILURES:-0}")

# ── Diff-Basis bestimmen ─────────────────────────────────────────────────
# Reihenfolge: GUARD_DIFF_BASE → push: github.event.before → pull_request: base.sha → HEAD~1
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
IS_SHALLOW=$(git rev-parse --is-shallow-repository 2>/dev/null || echo "unknown")

commit_exists() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1
}

base_missing() {
  echo "❌ Deployment Guard: Diff-Basis '$1' ($2) ist im Checkout nicht vorhanden." >&2
  echo "   Ohne Basis-Commit kann kein Diff berechnet werden — der Score wäre falsch (0)." >&2
  echo "   Lösung: actions/checkout mit 'fetch-depth: 0' (empfohlen) oder mindestens 'fetch-depth: 2' verwenden." >&2
  exit 1
}

DIFF_BASE=""
BASE_SOURCE=""
BASE_FALLBACK_REASON=""
if [ -n "${GUARD_DIFF_BASE:-}" ]; then
  DIFF_BASE="$GUARD_DIFF_BASE"
  BASE_SOURCE="GUARD_DIFF_BASE"
  commit_exists "$DIFF_BASE" || base_missing "$DIFF_BASE" "$BASE_SOURCE"
elif [ "${GITHUB_EVENT_NAME:-}" = "push" ] && [[ "${GITHUB_EVENT_BEFORE:-}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] && ! [[ "$GITHUB_EVENT_BEFORE" =~ ^0+$ ]]; then
  if commit_exists "$GITHUB_EVENT_BEFORE"; then
    DIFF_BASE="$GITHUB_EVENT_BEFORE"
    BASE_SOURCE="github.event.before"
  elif [ "$IS_SHALLOW" = "true" ]; then
    base_missing "$GITHUB_EVENT_BEFORE" "github.event.before"
  else
    # Vollständiger Clone, aber Commit unbekannt (z. B. nach Force-Push) → HEAD~1
    echo "⚠️  Deployment Guard: github.event.before (${GITHUB_EVENT_BEFORE:0:7}) nicht in der Historie (Force-Push?) — nutze HEAD~1."
    BASE_FALLBACK_REASON="force push"
  fi
elif [[ "${GITHUB_EVENT_NAME:-}" == pull_request* ]] && [ -n "${GITHUB_PR_BASE_SHA:-}" ]; then
  DIFF_BASE="$GITHUB_PR_BASE_SHA"
  BASE_SOURCE="pull_request.base.sha"
  commit_exists "$DIFF_BASE" || base_missing "$DIFF_BASE" "$BASE_SOURCE"
fi

if [ -z "$DIFF_BASE" ]; then
  if commit_exists "HEAD~1"; then
    DIFF_BASE="HEAD~1"
    BASE_SOURCE="HEAD~1"
    # Tag-Push (before = 000…), neuer Branch, workflow_dispatch, release, Force-Push:
    # nur der letzte Commit wird bewertet — laut und sichtbar warnen.
    # ::warning:: hier, VOR jeder Ausgabe fremder Daten (Dateinamen, API-Text).
    echo "::warning title=Deployment Guard::Diff base fell back to HEAD~1 (event: ${GITHUB_EVENT_NAME:-unknown}${BASE_FALLBACK_REASON:+, ${BASE_FALLBACK_REASON}}) - only the last commit is scored. Set GUARD_DIFF_BASE for tag/release/dispatch deploys."
    echo "  [guard] WARNING: diff base fell back to HEAD~1 – only the last commit is scored. Set GUARD_DIFF_BASE for tag/release/dispatch deploys."
  elif [ "$IS_SHALLOW" = "false" ] && commit_exists "HEAD"; then
    # Erster Commit im Repo: gegen den leeren Baum vergleichen
    DIFF_BASE="$EMPTY_TREE"
    BASE_SOURCE="initial commit (empty tree)"
  else
    base_missing "HEAD~1" "Fallback"
  fi
fi

echo "  [guard] diff_base:            ${DIFF_BASE} (${BASE_SOURCE})"

# ── Diff-Statistik (base..HEAD) ──────────────────────────────────────────
# .gitattributes aus dem Repo (z. B. "* -diff" oder "binary") würde numstat auf "-\t-"
# setzen und die Zeilenzahlen auf 0 drücken. Deshalb alle Diffs mit leerem
# Attribut-Baum: attr.tree (git >= 2.42) bzw. GIT_ATTR_SOURCE (git >= 2.40).
gdiff() {
  GIT_ATTR_SOURCE="$EMPTY_TREE" git -c attr.tree="$EMPTY_TREE" -c core.quotePath=false diff --no-renames --no-ext-diff --no-textconv "$@"
}
GIT_VER=$(git version 2>/dev/null | sed -nE 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/p')
read -r GIT_MAJ GIT_MIN <<< "${GIT_VER:-0 0}"
if [ "${GIT_MAJ:-0}" -lt 2 ] || { [ "${GIT_MAJ:-0}" -eq 2 ] && [ "${GIT_MIN:-0}" -lt 40 ]; }; then
  echo "::warning title=Deployment Guard::git ${GIT_MAJ}.${GIT_MIN} is older than 2.40 - .gitattributes in the repo can hide diff lines. Update git on the runner."
  echo "  [guard] WARNING: git < 2.40 — .gitattributes-Schutz nicht verfügbar, Zeilenzahlen können zu niedrig sein."
fi

NUMSTAT=$(gdiff --numstat "$DIFF_BASE" HEAD) || die "git diff --numstat ${DIFF_BASE}..HEAD fehlgeschlagen."
ADDED=$(printf '%s\n' "$NUMSTAT" | awk '$1 ~ /^[0-9]+$/ {sum += $1} END {print sum+0}')
REMOVED=$(printf '%s\n' "$NUMSTAT" | awk '$2 ~ /^[0-9]+$/ {sum += $2} END {print sum+0}')
# Echte Binärdateien ("-\t-") haben keine Zeilenzahl, zählen aber als geänderte Datei.
BINARY_FILES=$(printf '%s\n' "$NUMSTAT" | awk -F '\t' '$1 == "-" && $2 == "-" {n++} END {print n+0}')

new_tmp NAMES_FILE
gdiff --name-only -z "$DIFF_BASE" HEAD > "$NAMES_FILE" \
  || die "git diff --name-only ${DIFF_BASE}..HEAD fehlgeschlagen."

CHANGED_FILES=()
while IFS= read -r -d '' f; do
  [ -n "$f" ] && CHANGED_FILES+=("$f")
done < "$NAMES_FILE"
FILES=${#CHANGED_FILES[@]}

GITATTR_CHANGED=0
if [ "$FILES" -gt 0 ]; then
  for f in "${CHANGED_FILES[@]}"; do
    [ "${f##*/}" = ".gitattributes" ] && GITATTR_CHANGED=$((GITATTR_CHANGED + 1))
  done
fi

# Newline-Liste nur für Mustererkennung (grep), nicht für den Payload
CHANGED_LIST=""
if [ "$FILES" -gt 0 ]; then
  CHANGED_LIST=$(printf '%s\n' "${CHANGED_FILES[@]}")
fi

# ── Kubernetes-Manifeste ─────────────────────────────────────────────────
# Ausgeschlossen: .github/, action.yml/action.yaml, Helm templates/
CHANGED_YAMLS=()
if [ "$FILES" -gt 0 ]; then
  for f in "${CHANGED_FILES[@]}"; do
    [[ "$f" =~ \.ya?ml$ ]] || continue
    [[ "$f" == *.github/* ]] && continue
    case "${f##*/}" in action.yml|action.yaml) continue ;; esac
    [[ "$f" == *templates/* ]] && continue
    CHANGED_YAMLS+=("$f")
  done
fi

K8S=0
HELM_VALUES=0

# ── K8s-Specifics (Single Replica, PDB) ──────────────────────────────────
SINGLE_REPLICA="false"
MISSING_PDB="false"
HAS_DEPLOYMENT=0
HAS_PDB=0

if [ "${#CHANGED_YAMLS[@]}" -gt 0 ]; then
  for f in "${CHANGED_YAMLS[@]}"; do
    [ -f "$f" ] || continue
    if grep -q 'kind:' -- "$f" 2>/dev/null; then
      K8S=$((K8S + 1))
    fi
    if grep -q 'image:\|tag:\|replicaCount:\|resources:' -- "$f" 2>/dev/null; then
      HELM_VALUES=$((HELM_VALUES + 1))
    fi
    if grep -q 'kind: Deployment' -- "$f" 2>/dev/null; then
      HAS_DEPLOYMENT=$((HAS_DEPLOYMENT + 1))
      REPLICAS=$(grep 'replicas:' -- "$f" 2>/dev/null | awk '{print $2}' | head -1)
      if [ "$REPLICAS" = "1" ]; then
        SINGLE_REPLICA="true"
      fi
    fi
    if grep -q 'kind: PodDisruptionBudget' -- "$f" 2>/dev/null; then
      HAS_PDB=$((HAS_PDB + 1))
    fi
  done
fi

if [ "$HAS_DEPLOYMENT" -gt 0 ] && [ "$HAS_PDB" -eq 0 ]; then
  MISSING_PDB="true"
fi

HELM_CHART_CHANGED=$(printf '%s' "$CHANGED_LIST" | grep -cE 'Chart\.ya?ml$' || true)
[ -z "$HELM_CHART_CHANGED" ] && HELM_CHART_CHANGED=0
[ "$HELM_CHART_CHANGED" -gt 0 ] && HELM_CHART_BUMPED="true" || HELM_CHART_BUMPED="false"

# ── Phase 5 — Repo-Type-Detection Metadata ───────────────────────────────
HAS_DOCKERFILE="false"
HAS_PYTHON_DEPS="false"
HAS_NODE_DEPS="false"
HAS_TERRAFORM="false"
HAS_SETUP_PY="false"

[ -f "Dockerfile" ] || [ -f "dockerfile" ] && HAS_DOCKERFILE="true"
[ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "Pipfile" ] && HAS_PYTHON_DEPS="true"
[ -f "package.json" ] && HAS_NODE_DEPS="true"

# Terraform-Files irgendwo im Repo?
if find . -maxdepth 3 -name "*.tf" -type f 2>/dev/null | head -1 | grep -q '.'; then
  HAS_TERRAFORM="true"
fi

[ -f "setup.py" ] && HAS_SETUP_PY="true"

# ── Dependencies & Major Bumps ────────────────────────────────────────────
DEP_FILES=$(printf '%s' "$CHANGED_LIST" | \
  grep -cE 'package\.json|requirements\.txt|go\.mod|pom\.xml|Gemfile|Cargo\.toml|yarn\.lock|package-lock\.json' || true)
[ -z "$DEP_FILES" ] && DEP_FILES=0

MAJOR_BUMPS=0

if printf '%s' "$CHANGED_LIST" | grep -q 'package\.json'; then
  PKG_MAJOR=$(gdiff "$DIFF_BASE" HEAD -- package.json 2>/dev/null | \
    grep '^[+-]' | grep -v '^---\|^+++' | \
    grep -oE '"[0-9]+\.' | grep -oE '[0-9]+' | \
    sort -n | uniq -d | wc -l | tr -d ' ')
  [ -z "$PKG_MAJOR" ] && PKG_MAJOR=0
  MAJOR_BUMPS=$((MAJOR_BUMPS + PKG_MAJOR))
fi

if printf '%s' "$CHANGED_LIST" | grep -q 'requirements\.txt'; then
  REQ_MAJOR=$(gdiff "$DIFF_BASE" HEAD -- requirements.txt 2>/dev/null | \
    grep '^[+-][a-zA-Z]' | grep -oE '==[0-9]+' | grep -oE '[0-9]+' | \
    sort | uniq -d | wc -l | tr -d ' ')
  [ -z "$REQ_MAJOR" ] && REQ_MAJOR=0
  MAJOR_BUMPS=$((MAJOR_BUMPS + REQ_MAJOR))
fi

if printf '%s' "$CHANGED_LIST" | grep -q 'go\.mod'; then
  GO_MAJOR=$(gdiff "$DIFF_BASE" HEAD -- go.mod 2>/dev/null | \
    grep '^[+-]' | grep -v '^---\|^+++' | \
    grep -oE '/v[0-9]+' | grep -oE '[0-9]+' | \
    sort -n | uniq -d | wc -l | tr -d ' ')
  [ -z "$GO_MAJOR" ] && GO_MAJOR=0
  MAJOR_BUMPS=$((MAJOR_BUMPS + GO_MAJOR))
fi

# ── Phase 3 — File-Path-Awareness ────────────────────────────────────────
# JSON-Array per jq aus NUL-getrennter Liste: max. 500 Pfade, je max. 300 Zeichen.
new_tmp PATHS_FILE
if [ -n "${DIFF_CHANGED_PATHS:-}" ]; then
  # Override über Action-Input (komma-separiert)
  jq -n --arg s "$DIFF_CHANGED_PATHS" \
    '$s | split(",") | map(select(length > 0)) | .[:500] | map(if length > 300 then "\u2026" + .[-299:] else . end)' > "$PATHS_FILE" \
    || die "diff-changed-paths konnte nicht verarbeitet werden."
else
  jq -Rs 'split("\u0000") | map(select(length > 0)) | .[:500] | map(if length > 300 then "\u2026" + .[-299:] else . end)' < "$NAMES_FILE" > "$PATHS_FILE" \
    || die "Geänderte Pfade konnten nicht verarbeitet werden."
fi
PATHS_COUNT=$(jq 'length' "$PATHS_FILE")
PATHS_PREVIEW=$(jq -r '.[:20] | join(",")' "$PATHS_FILE")
[ "$PATHS_COUNT" -gt 20 ] && PATHS_PREVIEW="${PATHS_PREVIEW},… (${PATHS_COUNT} gesamt)"

# ── Phase 6 — Git-Prozessmetriken (Score 2.0) ────────────────────────────
# Werden lokal aus der Git-Historie berechnet. An die API gehen nur Zahlen und
# die SHAs rückgängig gemachter Commits — keine Namen, Adressen oder Nachrichten.
# Flacher Clone oder erster Commit: nichts senden (null), statt falscher Nullen.
PM_AVAILABLE="false"
PM_SUBSYS=null; PM_DIRS=null; PM_ENTROPY=null; PM_DEVS=null; PM_PRIOR=null; PM_AUTHOR=null
REV7=null; REV30=null; HOT7=null; HOT30=null
IS_HOTFIX="false"
HOTFIX_RE='^(hotfix|hot-fix|\[hotfix\])'
new_tmp REVERTED_FILE
echo '[]' > "$REVERTED_FILE"

# Teure git-Abfragen in großen Repos begrenzen (timeout fehlt z. B. auf macOS)
with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 20 "$@"; else "$@"; fi
}
# Werte über 1.000.000 lehnt die API ab — kappen statt die Analyse scheitern zu lassen
cap() { awk '{ v = $1 + 0; print (v > 1000000 ? 1000000 : v) }'; }

if [ "$IS_SHALLOW" = "false" ] && commit_exists "$DIFF_BASE"; then
  PM_SUBSYS=0; PM_DIRS=0; PM_ENTROPY=0; PM_DEVS=0; PM_PRIOR=0; PM_AUTHOR=0
  if [ "$FILES" -gt 0 ]; then
    # Zeilenumbrüche in Dateinamen ersetzen, damit jede Datei genau eine Zeile ist
    PM_SUBSYS=$(printf '%s\n' "${CHANGED_FILES[@]//$'\n'/ }" | awk -F/ '{ print (NF > 1 ? $1 : ".") }' | sort -u | wc -l | cap)
    PM_DIRS=$(printf '%s\n' "${CHANGED_FILES[@]//$'\n'/ }" | awk '{ if (sub(/\/[^\/]*$/, "")) print; else print "." }' | sort -u | wc -l | cap)
    # Streuung: normierte Entropie der geänderten Zeilen über die Dateien (0–100)
    PM_ENTROPY=$(printf '%s\n' "$NUMSTAT" | awk -F '\t' '
      NF >= 3 { n = ($1 == "-") ? 1 : $1 + $2; if (n < 1) n = 1; c[++k] = n; t += n }
      END {
        if (k < 2 || t == 0) { print 0; exit }
        h = 0; for (i = 1; i <= k; i++) { p = c[i] / t; h -= p * log(p) }
        v = int(h / log(k) * 100 + 0.5); if (v > 100) v = 100; print v
      }')
    # Personen und Commits auf diesen Dateien im letzten Jahr (vor der Diff-Basis), max. 200 Dateien
    PM_FILES=("${CHANGED_FILES[@]:0:200}")
    new_tmp HIST_FILE
    if with_timeout git --literal-pathspecs log --no-merges --since="1 year ago" --format='%H %ae' "$DIFF_BASE" -- "${PM_FILES[@]}" > "$HIST_FILE" 2>/dev/null; then
      PM_PRIOR=$(cut -d' ' -f1 "$HIST_FILE" | sort -u | grep -c . | cap || true)
      PM_DEVS=$(cut -d' ' -f2- "$HIST_FILE" | tr '[:upper:]' '[:lower:]' | sort -u | grep -c . | cap || true)
    else
      echo "  [guard] WARNING: Git-Historie zu groß oder nicht lesbar — Prozessmetriken werden nicht gesendet."
      HIST_FAILED=1
    fi
  fi
  # Erfahrung: bisherige Commits des Autors von HEAD im Repo (max. 20.000 durchsucht)
  AUTHOR_EMAIL=$(git log -1 --format=%ae HEAD 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [ -n "$AUTHOR_EMAIL" ]; then
    PM_AUTHOR=$(with_timeout git log --no-merges -n 20000 --format=%ae "$DIFF_BASE" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -cxF -- "$AUTHOR_EMAIL" || true)
  fi
  # Fehlerhistorie aus Git: Reverts und Hotfixes der letzten 7/30 Tage
  REV7=$(git log --since="7 days ago" -F --grep='This reverts commit' --format=%H HEAD 2>/dev/null | grep -c . || true)
  REV30=$(git log --since="30 days ago" -F --grep='This reverts commit' --format=%H HEAD 2>/dev/null | grep -c . || true)
  HOT7=$(git log --no-merges --since="7 days ago" --format=%s HEAD 2>/dev/null | grep -ciE "$HOTFIX_RE" || true)
  HOT30=$(git log --no-merges --since="30 days ago" --format=%s HEAD 2>/dev/null | grep -ciE "$HOTFIX_RE" || true)
  # Ergebnis früherer Deployments: welche Commits macht dieser Push rückgängig?
  git log --format=%B "${DIFF_BASE}..HEAD" 2>/dev/null \
    | grep -oE 'This reverts commit [0-9a-f]{7,40}' | awk '{ print $4 }' | sort -u | head -20 \
    | jq -R . | jq -s . > "$REVERTED_FILE" || echo '[]' > "$REVERTED_FILE"
  if git log --no-merges --format=%s "${DIFF_BASE}..HEAD" 2>/dev/null | grep -qiE "$HOTFIX_RE"; then
    IS_HOTFIX="true"
  fi
  PM_AVAILABLE="true"
  if [ "${HIST_FAILED:-0}" = "1" ]; then
    PM_AVAILABLE="false"
    PM_SUBSYS=null; PM_DIRS=null; PM_ENTROPY=null; PM_DEVS=null; PM_PRIOR=null; PM_AUTHOR=null
  fi
fi
EVENT_NAME=$(printf '%s' "${GITHUB_EVENT_NAME:-}" | tr -cd 'a-z_' | head -c 40)
REVERTED_COUNT=$(jq 'length' "$REVERTED_FILE")

# ── Phase 7 — Freigabe-Gate ──────────────────────────────────────────────
# Policy vom BASIS-Commit lesen: Ein Pull Request kann seine eigenen Regeln nicht lockern.
new_tmp POLICY_TMP
POLICY_PRESENT="false"
POLICY_UNAVAILABLE="false"
POLICY_NOTE=""
# Bei Fallback-Basis (HEAD~1: Tag, workflow_dispatch, Force-Push) stammt die Basis
# evtl. vom Angreifer: dann die Policy vom Default-Branch lesen.
POLICY_REF="$DIFF_BASE"
if [ "$BASE_SOURCE" = "HEAD~1" ] || ! commit_exists "$DIFF_BASE"; then
  DEFAULT_BRANCH=$(printf '%s' "${GITHUB_DEFAULT_BRANCH:-}" | tr -cd 'A-Za-z0-9._/-' | head -c 200)
  if [ -n "$DEFAULT_BRANCH" ] && commit_exists "origin/${DEFAULT_BRANCH}"; then
    POLICY_REF="origin/${DEFAULT_BRANCH}"
  else
    POLICY_REF=""
    POLICY_NOTE="Keine vertrauenswürdige Basis für die Policy — Standardregeln, mindestens zwei Prüfer"
    [ -f "$POLICY_FILE" ] && POLICY_UNAVAILABLE="true"
  fi
fi
if [ -n "$POLICY_REF" ] && git cat-file -e "${POLICY_REF}:${POLICY_FILE}" 2>/dev/null; then
  git show "${POLICY_REF}:${POLICY_FILE}" 2>/dev/null | head -c 8001 > "$POLICY_TMP" || : > "$POLICY_TMP"
  if [ "$(wc -c < "$POLICY_TMP")" -gt 8000 ]; then
    POLICY_NOTE="policy-file größer als 8 KB — Standardregeln"
    : > "$POLICY_TMP"
  else
    POLICY_PRESENT="true"
  fi
elif [ -z "$POLICY_NOTE" ] && [ -f "$POLICY_FILE" ]; then
  POLICY_NOTE="${POLICY_FILE} ist neu und gilt ab dem nächsten Push (wird vom Basis-Commit gelesen) — jetzt Standardregeln"
fi

# KI-Agenten erkennen: Autor, Co-authored-by und typische Signaturen der Commits.
# Es werden nur Namen aus einer festen Liste gesendet, keine Personen oder Adressen.
AGENT_TEXT=""
if commit_exists "$DIFF_BASE"; then
  AGENT_TEXT=$(git log --format='%an <%ae>%n%cn <%ce>%n%b' "${DIFF_BASE}..HEAD" 2>/dev/null | head -c 500000 | tr '[:upper:]' '[:lower:]' || true)
else
  AGENT_TEXT=$(git log -1 --format='%an <%ae>%n%cn <%ce>%n%b' HEAD 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
fi
PR_AUTHOR=$(printf '%s' "${GITHUB_PR_AUTHOR:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9[]-' | head -c 100)
AGENT_TEXT="${AGENT_TEXT}"$'\n'"pr-author: ${PR_AUTHOR}"
AGENTS=()
detect_agent() {
  if printf '%s' "$AGENT_TEXT" | grep -qE -- "$2"; then AGENTS+=("$1"); fi
}
detect_agent copilot   'copilot-swe-agent|\+copilot@users\.noreply\.github\.com|pr-author: copilot'
detect_agent claude    'noreply@anthropic\.com|claude\[bot\]|co-authored-by: claude|generated with \[?claude code'
detect_agent cursor    'cursoragent@cursor\.com|cursor\[bot\]|co-authored-by: cursor'
detect_agent devin     'devin-ai-integration|devin\[bot\]'
detect_agent codex     'chatgpt-codex-connector|codex\[bot\]|co-authored-by: codex'
detect_agent jules     'google-labs-jules|jules\[bot\]'
detect_agent openhands 'openhands'
detect_agent aider     'co-authored-by: aider|aider\.chat'
detect_agent amazon-q  'amazon-q-developer|amazon q developer'
new_tmp AGENTS_FILE
if [ "${#AGENTS[@]}" -gt 0 ]; then
  printf '%s\n' "${AGENTS[@]}" | jq -R . | jq -s . > "$AGENTS_FILE"
else
  echo '[]' > "$AGENTS_FILE"
fi

# Alle Zähler sind intern berechnet — trotzdem prüfen, bevor sie als JSON-Zahl gehen
for v in "$ADDED" "$REMOVED" "$FILES" "$BINARY_FILES" "$K8S" "$HELM_VALUES" "$DEP_FILES" "$MAJOR_BUMPS" "$REVERTED_COUNT"; do
  [[ "$v" =~ ^[0-9]+$ ]] || die "Interner Fehler: ungültiger Zählerwert '${v}'."
done
for v in "$PM_SUBSYS" "$PM_DIRS" "$PM_ENTROPY" "$PM_DEVS" "$PM_PRIOR" "$PM_AUTHOR" "$REV7" "$REV30" "$HOT7" "$HOT30"; do
  [[ "$v" =~ ^[0-9]{1,9}$ || "$v" = "null" ]] || die "Interner Fehler: ungültiger Prozesswert '${v}'."
done

# ── Debug Output ─────────────────────────────────────────────────────────
echo "  [guard] diff_lines_added:     ${ADDED}"
echo "  [guard] diff_lines_removed:   ${REMOVED}"
echo "  [guard] diff_files_changed:   ${FILES}"
echo "  [guard] binary_files_changed: ${BINARY_FILES} (ohne Zeilenzahl, als geänderte Datei gezählt)"
if [ "$GITATTR_CHANGED" -gt 0 ]; then
  echo "  [guard] WARNING: .gitattributes geändert (${GITATTR_CHANGED}x) — Repo-Attribute werden für den Diff ignoriert, Änderung bitte reviewen."
fi
echo "  [guard] k8s_manifests:        ${K8S}"
echo "  [guard] single_replica:       ${SINGLE_REPLICA}"
echo "  [guard] missing_pdb:          ${MISSING_PDB}"
echo "  [guard] helm_values_changed:  ${HELM_VALUES}"
echo "  [guard] helm_chart_bumped:    ${HELM_CHART_BUMPED}"
echo "  [guard] dependency_updates:   ${DEP_FILES}"
echo "  [guard] major_version_bumps:  ${MAJOR_BUMPS}"
echo "  [guard] incidents_7d:         ${INC7}"
echo "  [guard] incidents_30d:        ${INC30}"
echo "  [guard] trivy_critical:       ${TRIVY_CRIT}"
echo "  [guard] trivy_high:           ${TRIVY_HIGH}"
echo "  [guard] semgrep_findings:     ${SEM_TOTAL}"
echo "  [guard] semgrep_high:         ${SEM_HIGH}"
echo "  [guard] checkov_failed:       ${CKV_TOTAL}"
echo "  [guard] checkov_critical:     ${CKV_CRIT}"
printf '  [guard] changed_paths:        %s\n' "${PATHS_PREVIEW:-(none)}" | sanitize
echo "  [guard] has_dockerfile:       ${HAS_DOCKERFILE}"
echo "  [guard] has_python_deps:      ${HAS_PYTHON_DEPS}"
echo "  [guard] has_node_deps:        ${HAS_NODE_DEPS}"
echo "  [guard] has_terraform:        ${HAS_TERRAFORM}"
echo "  [guard] has_setup_py:         ${HAS_SETUP_PY}"
echo "  [guard] git_metrics:          ${PM_AVAILABLE} (subsystems ${PM_SUBSYS}, dirs ${PM_DIRS}, entropy ${PM_ENTROPY}, developers ${PM_DEVS}, prior_changes ${PM_PRIOR}, author_commits ${PM_AUTHOR})"
echo "  [guard] reverts_7d/30d:       ${REV7}/${REV30}  hotfixes_7d/30d: ${HOT7}/${HOT30}"
echo "  [guard] reverts_in_push:      ${REVERTED_COUNT}  is_hotfix: ${IS_HOTFIX}"
echo "  [guard] gate_policy:          $([ "$POLICY_PRESENT" = "true" ] && echo "${POLICY_FILE} (${POLICY_REF:0:40})" || echo "Standardregeln")"
[ -n "$POLICY_NOTE" ] && echo "  [guard] gate_note:            ${POLICY_NOTE}"
echo "  [guard] agents_detected:      $(jq -r 'if length == 0 then "keine" else join(", ") end' "$AGENTS_FILE")"

# Bei Pull Requests ist GITHUB_SHA der temporaere Merge-Commit, der sich bei jedem
# Neuaufbau aendert. Fuer Dashboard-Link und Zaehlung (Wiederholung = gleicher Commit)
# den Head-Commit des PRs senden.
COMMIT_SHA="${GITHUB_SHA:-}"
if [[ "${GITHUB_EVENT_NAME:-}" == pull_request* ]] && [[ "${GITHUB_PR_HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
  COMMIT_SHA="$GITHUB_PR_HEAD_SHA"
fi

# ── Payload bauen (jq, keine String-Interpolation) ───────────────────────
new_tmp PAYLOAD_FILE
jq -n \
  --arg     repo                      "${GITHUB_REPO:-}" \
  --arg     branch                    "${GITHUB_BRANCH:-}" \
  --arg     commit_sha                "${COMMIT_SHA}" \
  --argjson diff_lines_added          "$ADDED" \
  --argjson diff_lines_removed        "$REMOVED" \
  --argjson diff_files_changed        "$FILES" \
  --argjson k8s_manifests_changed     "$K8S" \
  --argjson has_single_replica        "$SINGLE_REPLICA" \
  --argjson has_missing_pdb           "$MISSING_PDB" \
  --argjson helm_values_changed       "$HELM_VALUES" \
  --argjson helm_chart_bumped         "$HELM_CHART_BUMPED" \
  --argjson dependency_updates        "$DEP_FILES" \
  --argjson major_version_bumps       "$MAJOR_BUMPS" \
  --argjson incidents_last_7d         "$INC7" \
  --argjson incidents_last_30d        "$INC30" \
  --argjson trivy_critical_cves       "$TRIVY_CRIT" \
  --argjson trivy_high_cves           "$TRIVY_HIGH" \
  --argjson semgrep_findings          "$SEM_TOTAL" \
  --argjson semgrep_high_severity     "$SEM_HIGH" \
  --argjson checkov_failed_checks     "$CKV_TOTAL" \
  --argjson checkov_critical_failures "$CKV_CRIT" \
  --slurpfile diff_changed_paths      "$PATHS_FILE" \
  --argjson has_dockerfile            "$HAS_DOCKERFILE" \
  --argjson has_python_deps           "$HAS_PYTHON_DEPS" \
  --argjson has_node_deps             "$HAS_NODE_DEPS" \
  --argjson has_terraform             "$HAS_TERRAFORM" \
  --argjson has_setup_py              "$HAS_SETUP_PY" \
  --argjson pm_subsystems             "$PM_SUBSYS" \
  --argjson pm_directories            "$PM_DIRS" \
  --argjson pm_entropy_pct            "$PM_ENTROPY" \
  --argjson pm_developers             "$PM_DEVS" \
  --argjson pm_prior_changes          "$PM_PRIOR" \
  --argjson pm_author_commits         "$PM_AUTHOR" \
  --argjson reverts_7d                "$REV7" \
  --argjson reverts_30d               "$REV30" \
  --argjson hotfixes_7d               "$HOT7" \
  --argjson hotfixes_30d              "$HOT30" \
  --slurpfile reverted_shas           "$REVERTED_FILE" \
  --argjson is_hotfix                 "$IS_HOTFIX" \
  --arg     event_name                "$EVENT_NAME" \
  --rawfile policy_yaml               "$POLICY_TMP" \
  --argjson policy_present            "$POLICY_PRESENT" \
  --arg     policy_path               "$POLICY_FILE" \
  --argjson policy_unavailable        "$POLICY_UNAVAILABLE" \
  --slurpfile agent_names             "$AGENTS_FILE" \
  '{
    repo: $repo,
    branch: $branch,
    commit_sha: $commit_sha,
    diff_lines_added: $diff_lines_added,
    diff_lines_removed: $diff_lines_removed,
    diff_files_changed: $diff_files_changed,
    k8s_manifests_changed: $k8s_manifests_changed,
    has_single_replica: $has_single_replica,
    has_missing_pdb: $has_missing_pdb,
    helm_values_changed: $helm_values_changed,
    helm_chart_bumped: $helm_chart_bumped,
    dependency_updates: $dependency_updates,
    major_version_bumps: $major_version_bumps,
    incidents_last_7d: $incidents_last_7d,
    incidents_last_30d: $incidents_last_30d,
    trivy_critical_cves: $trivy_critical_cves,
    trivy_high_cves: $trivy_high_cves,
    semgrep_findings: $semgrep_findings,
    semgrep_high_severity: $semgrep_high_severity,
    checkov_failed_checks: $checkov_failed_checks,
    checkov_critical_failures: $checkov_critical_failures,
    diff_changed_paths: $diff_changed_paths[0],
    has_dockerfile: $has_dockerfile,
    has_python_deps: $has_python_deps,
    has_node_deps: $has_node_deps,
    has_terraform: $has_terraform,
    has_setup_py: $has_setup_py,
    pm_subsystems: $pm_subsystems,
    pm_directories: $pm_directories,
    pm_entropy_pct: $pm_entropy_pct,
    pm_developers: $pm_developers,
    pm_prior_changes: $pm_prior_changes,
    pm_author_commits: $pm_author_commits,
    reverts_7d: $reverts_7d,
    reverts_30d: $reverts_30d,
    hotfixes_7d: $hotfixes_7d,
    hotfixes_30d: $hotfixes_30d,
    reverted_shas: $reverted_shas[0],
    is_hotfix: $is_hotfix,
    event_name: $event_name,
    policy_yaml: (if $policy_present then $policy_yaml else null end),
    policy_path: $policy_path,
    policy_unavailable: $policy_unavailable,
    agent_names: $agent_names[0]
  }' > "$PAYLOAD_FILE" || die "Payload konnte nicht erzeugt werden."

# ── Fehlerbehandlung: fail-open vs. fail-closed ──────────────────────────
# fail-open=true  → nur echte Ausfälle: Netzwerk-/curl-Fehler, Timeout, HTTP 429, HTTP 5xx
#                   oder ungültiger Body bei HTTP 200 → Warnung, Deployment läuft weiter (Standard)
# fail-open=false → dieselben Fälle brechen ab
# Alle anderen HTTP-Codes (3xx-Redirects, 4xx inkl. 401/402/403/404/405/407/413/422) brechen IMMER ab.
# curl folgt Redirects bewusst NICHT (kein -L) — der API Key geht nie an ein Redirect-Ziel.
new_tmp RESP_FILE

print_body() {
  if [ -s "$RESP_FILE" ]; then
    echo "Response (gekürzt):"
    head -c 2000 "$RESP_FILE" | print_untrusted
    echo ""
  fi
}

# Immer abbrechen — unabhängig von fail-open (Konfigurations-/Anfragefehler, kein Ausfall)
hard_fail() {
  printf '❌ Deployment Guard: %s — Deployment wird gestoppt (gilt auch bei fail-open: '"'"'true'"'"').\n' "$1" | sanitize >&2
  print_body
  exit 1
}

# $1 kann Ausschnitte der API-Antwort enthalten → immer über sanitize ausgeben
soft_fail() {
  if [ "$FAIL_OPEN" = "true" ]; then
    printf '⚠️  Deployment Guard: %s — Deployment wird ohne Bewertung fortgesetzt (fail-open). Strenger: fail-open: '"'"'false'"'"'.\n' "$1" | sanitize
    print_body
    exit 0
  fi
  printf '❌ Deployment Guard: %s — Deployment wird gestoppt (fail-open ist deaktiviert).\n' "$1" | sanitize >&2
  echo "   Wenn Ausfälle der API das Deployment nicht blockieren sollen: fail-open: 'true' setzen." >&2
  print_body
  exit 1
}

# ── GitHub-API für Labels/Reviews vorbereiten ────────────────────────────
GH_PR_READY="false"
if [ -n "${GH_TOKEN_INPUT:-}" ] && [[ "${GITHUB_PR_NUMBER:-}" =~ ^[0-9]{1,9}$ ]] \
   && [[ "${GITHUB_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request_target" ]; then
    # pull_request_target checkt den Basis-Commit aus: bewertet würde nicht der PR-Code
    echo "::warning title=Deployment Guard::pull_request_target bewertet nicht den Code des Pull Requests — kein Label, keine Freigabe-Prüfung. Bitte pull_request verwenden."
    [ "$ENFORCE_REVIEWS" = "true" ] && die "enforce-reviews funktioniert nicht mit pull_request_target."
  else
    GH_API="${GITHUB_API_URL:-https://api.github.com}"
    if [[ "$GH_API" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]*)?$ ]]; then
      new_tmp GH_HDR
      printf 'Authorization: Bearer %s\n' "$GH_TOKEN_INPUT" > "$GH_HDR"
      ISSUE_URL="${GH_API%/}/repos/${GITHUB_REPO}/issues/${GITHUB_PR_NUMBER}/labels"
      GH_PR_READY="true"
      # Alte Entscheidung zuerst entfernen: Scheitert die Bewertung, bleibt kein veraltetes dg:auto-ok stehen
      if [ "$LABEL_PR" = "true" ]; then
        for old in dg%3Aauto-ok dg%3Areview dg%3Atwo-reviewers dg%3Ablocked; do
          curl -sS -o /dev/null --max-time 15 -X DELETE -H @"$GH_HDR" \
            -H "Accept: application/vnd.github+json" "${ISSUE_URL}/${old}" 2>/dev/null || true
        done
      fi
    elif [ "$ENFORCE_REVIEWS" = "true" ]; then
      die "GITHUB_API_URL ungültig — enforce-reviews nicht möglich."
    fi
  fi
elif [ "$ENFORCE_REVIEWS" = "true" ] && [[ "${GITHUB_EVENT_NAME:-}" == pull_request* ]]; then
  die "enforce-reviews: Pull-Request-Nummer oder Repository fehlt."
fi

# ── Senden (API Key per Header-Datei, nicht auf der Kommandozeile) ───────
new_tmp HDR_FILE
printf 'X-API-Key: %s\n' "$GUARD_API_KEY" > "$HDR_FILE"

set +e
HTTP_CODE=$(curl -sS -o "$RESP_FILE" -w '%{http_code}' -X POST "${API_URL}/analyze" \
  -H "Content-Type: application/json" \
  -H @"$HDR_FILE" \
  --max-time "$HTTP_TIMEOUT" \
  --data-binary @"$PAYLOAD_FILE")
CURL_EXIT=$?
set -e

if [ "$CURL_EXIT" -ne 0 ]; then
  soft_fail "API nicht erreichbar (curl exit ${CURL_EXIT})"
fi

case "$HTTP_CODE" in
  200) ;;
  401|403)
    hard_fail "API Key ungültig oder ohne Berechtigung (HTTP ${HTTP_CODE})" ;;
  400|422)
    hard_fail "Anfrage abgelehnt (HTTP ${HTTP_CODE}) — Eingaben prüfen" ;;
  429)
    soft_fail "Analyse-Limit erreicht (HTTP 429)" ;;
  5[0-9][0-9])
    soft_fail "API-Fehler (HTTP ${HTTP_CODE})" ;;
  3[0-9][0-9])
    hard_fail "API antwortet mit Redirect (HTTP ${HTTP_CODE}) — wird nicht verfolgt; api-url prüfen" ;;
  *)
    hard_fail "Unerwarteter HTTP-Status ${HTTP_CODE:0:3} — api-url, Proxy und Abo prüfen" ;;
esac

# ── Antwort parsen (jq) ──────────────────────────────────────────────────
if ! jq -e 'type == "object"' "$RESP_FILE" >/dev/null 2>&1; then
  soft_fail "Ungültige API-Antwort (kein JSON-Objekt)"
fi

STATUS=$(jq -r '.status // "" | tostring' "$RESP_FILE")
case "$STATUS" in
  PASS|WARN|BLOCKED) ;;
  *) soft_fail "Ungültige API-Antwort (status='${STATUS:0:40}')" ;;
esac

SCORE=$(jq -r '.score // "" | tostring' "$RESP_FILE")
if ! [[ "$SCORE" =~ ^[0-9]{1,3}(\.[0-9]+)?$ ]]; then
  soft_fail "Ungültige API-Antwort (score='${SCORE:0:40}')"
fi
VERDICT=$(jq -r '.verdict // "" | tostring' "$RESP_FILE")
EXPLANATION=$(jq -r '.explanation // "" | tostring' "$RESP_FILE")
BREAKDOWN=$(jq -r '.breakdown_text // "" | tostring' "$RESP_FILE")

set_output score "$SCORE"
set_output status "$STATUS"
set_output verdict "$VERDICT"
set_output explanation "$EXPLANATION"

# Freigabe-Gate (ab Backend mit Gate; ältere Backends liefern kein .gate)
GATE_DECISION=$(jq -r '.gate.decision // "" | tostring' "$RESP_FILE")
case "$GATE_DECISION" in
  auto_ok|review|two_reviewers|blocked|"") ;;
  *) GATE_DECISION="" ;;
esac
GATE_REASONS=$(jq -r '[.gate.reasons[]? | "\(.level // "" | tostring): \(.detail // "" | tostring)"] | .[:20] | join("\n")' "$RESP_FILE" 2>/dev/null || true)
GATE_POLICY_ERROR=$(jq -r '.gate.policy_error // "" | tostring' "$RESP_FILE" 2>/dev/null || true)
set_output gate-decision "$GATE_DECISION"
set_output gate-reasons "$GATE_REASONS"
case "$GATE_DECISION" in
  auto_ok) GATE_LABEL="dg:auto-ok"; GATE_TEXT="Automatisch freigegeben" ;;
  review) GATE_LABEL="dg:review"; GATE_TEXT="Review durch eine Person nötig" ;;
  two_reviewers) GATE_LABEL="dg:two-reviewers"; GATE_TEXT="Review durch zwei Personen nötig" ;;
  blocked) GATE_LABEL="dg:blocked"; GATE_TEXT="Blockiert" ;;
  *) GATE_LABEL=""; GATE_TEXT="" ;;
esac

# Auf GitHub zusätzlich Workflow-Commands für API-Text abschalten
STOP_TOKEN=""
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  STOP_TOKEN="dg$(rand_hex)$(rand_hex)"
  echo "::stop-commands::${STOP_TOKEN}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🛡️  Deployment Guard — Risk Analysis"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf '  Repo:    %s\n' "${GITHUB_REPO:-}" | sanitize
printf '  Branch:  %s\n' "${GITHUB_BRANCH:-}" | sanitize
printf '  Commit:  %s\n' "${COMMIT_SHA:0:7}"
echo "  ─────────────────────────────────────"
printf '  Score:   %s / 100\n' "$SCORE"
printf '  Verdict: %s\n' "$VERDICT" | sanitize
printf '  Status:  %s\n' "$STATUS"

if [ -n "$BREAKDOWN" ]; then
  echo "  ─────────────────────────────────────"
  printf '%s\n' "$BREAKDOWN" | sanitize
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -n "$EXPLANATION" ]; then
  echo ""
  echo "📋 KI-Analyse:"
  printf '%s\n' "$EXPLANATION" | sanitize | sed 's/^/   /'
  echo ""
fi

if [ -n "$GATE_DECISION" ]; then
  echo "🚦 Freigabe: ${GATE_TEXT} (${GATE_DECISION})"
  printf '%s\n' "$GATE_REASONS" | sanitize | sed 's/^/   • /'
  if [ -n "$GATE_POLICY_ERROR" ]; then
    printf '   ⚠️  Policy nicht verwendet: %s\n' "$GATE_POLICY_ERROR" | sanitize
  fi
  echo ""
fi

if [ -n "$STOP_TOKEN" ]; then
  echo "::${STOP_TOKEN}::"
fi

# Zusammenfassung im Job (Gründe als Codeblock: Dateipfade können Markdown enthalten)
if [ -n "$GATE_DECISION" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### 🛡️ Deployment Guard: ${GATE_TEXT}"
    echo ""
    echo "Entscheidung \`${GATE_DECISION}\` · Risiko-Score **${SCORE}/100** (${STATUS})"
    echo ""
    echo '```text'
    printf '%s\n' "$GATE_REASONS" | sanitize | tr -d '`'
    [ -n "$GATE_POLICY_ERROR" ] && printf 'Policy nicht verwendet: %s\n' "$GATE_POLICY_ERROR" | sanitize | tr -d '`'
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

# Ergebnis der Freigabe-Prüfung als eigene Zeile in der Job-Zusammenfassung,
# damit ein roter Check nicht neben einem grünen Score-Status unerklärt bleibt.
summary_result() {  # $1 = Text (nur feste Texte und Zahlen, keine Eingaben aus dem PR)
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  { echo ""; echo "$1"; } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
}

# Label am Pull Request setzen (alte dg:*-Labels wurden schon vor der API-Anfrage entfernt)
if [ -n "$GATE_LABEL" ] && [ "$GH_PR_READY" = "true" ] && [ "$LABEL_PR" = "true" ]; then
  LABEL_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X POST -H @"$GH_HDR" \
    -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" \
    --data "{\"labels\":[\"${GATE_LABEL}\"]}" "$ISSUE_URL" 2>/dev/null || echo "000")
  if [ "$LABEL_CODE" = "200" ]; then
    echo "🏷️  Label ${GATE_LABEL} gesetzt."
  else
    echo "::warning title=Deployment Guard::Label konnte nicht gesetzt werden (HTTP ${LABEL_CODE:0:3}). Der Token braucht 'pull-requests: write'; bei Pull Requests aus Forks ist das nicht möglich."
  fi
fi

# Freigaben durchsetzen (enforce-reviews): zählt den letzten Review-Stand je Person für
# genau diesen Commit. Gezählt werden nur Personen mit Schreibrecht, nicht der PR-Autor,
# keine Commit-Autoren des PRs und keine Bots. Fehlen Freigaben, schlägt der Check fehl.
gh_get_pages() {  # $1 = URL ohne page-Parameter, $2 = Zieldatei (JSON-Array aller Seiten)
  local url="$1" out="$2" page=1 code tmp
  new_tmp tmp
  echo '[]' > "$out"
  while [ "$page" -le 10 ]; do
    code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 20 -H @"$GH_HDR" \
      -H "Accept: application/vnd.github+json" "${url}&page=${page}" 2>/dev/null || echo "000")
    [ "$code" = "200" ] && jq -e 'type == "array"' "$tmp" >/dev/null 2>&1 || return 1
    jq -s '.[0] + .[1]' "$out" "$tmp" > "${tmp}.m" && mv "${tmp}.m" "$out"
    [ "$(jq 'length' "$tmp")" -lt 100 ] && return 0
    page=$((page + 1))
  done
  return 1  # mehr als 1000 Einträge: nicht sicher auswertbar
}

if [ "$ENFORCE_REVIEWS" = "true" ] && [[ "${GITHUB_EVENT_NAME:-}" == pull_request* ]]; then
  if [ "$GH_PR_READY" != "true" ]; then
    echo "❌ enforce-reviews: GitHub-API nicht nutzbar (Token, PR-Nummer oder API-URL fehlt)."
    summary_result "**❌ Check fehlgeschlagen:** Freigaben nicht prüfbar (Token oder PR-Daten fehlen)."
    exit 1
  fi
  case "$GATE_DECISION" in
    auto_ok) REQUIRED_APPROVALS=0 ;;
    review) REQUIRED_APPROVALS=1 ;;
    two_reviewers) REQUIRED_APPROVALS=2 ;;
    blocked)
      echo "❌ Freigabe-Regel: blockiert (enforce-reviews, unabhängig von fail-on-blocked)."
      summary_result "**❌ Check fehlgeschlagen:** Die Freigabe-Regel blockiert diese Änderung. Freigaben heben das nicht auf."
      exit 1 ;;
    *)
      echo "❌ enforce-reviews: keine Freigabe-Entscheidung von der API erhalten (Backend zu alt?) — Check schlägt fehl."
      summary_result "**❌ Check fehlgeschlagen:** Keine Freigabe-Entscheidung erhalten."
      exit 1 ;;
  esac
  if [ "$REQUIRED_APPROVALS" -gt 0 ]; then
    if ! [[ "${GITHUB_PR_HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
      echo "❌ enforce-reviews: Head-Commit des Pull Requests unbekannt — Freigaben nicht prüfbar."
      summary_result "**❌ Check fehlgeschlagen:** Freigaben nicht prüfbar (Commit unbekannt)."
      exit 1
    fi
    PR_API="${GH_API%/}/repos/${GITHUB_REPO}/pulls/${GITHUB_PR_NUMBER}"
    new_tmp REVIEWS_FILE
    new_tmp PR_COMMITS_FILE
    if ! gh_get_pages "${PR_API}/reviews?per_page=100" "$REVIEWS_FILE" \
       || ! gh_get_pages "${PR_API}/commits?per_page=100" "$PR_COMMITS_FILE"; then
      echo "❌ enforce-reviews: Reviews oder Commits konnten nicht gelesen werden — Check schlägt sicherheitshalber fehl."
      summary_result "**❌ Check fehlgeschlagen:** Reviews konnten nicht gelesen werden. Erneut ausführen."
      exit 1
    fi
    PR_AUTHOR_LC=$(printf '%s' "${GITHUB_PR_AUTHOR:-}" | tr '[:upper:]' '[:lower:]')
    # Kandidaten: letzter Stand je Person (nach Review-ID), APPROVED auf dem aktuellen Commit
    CANDIDATES=$(jq -r --arg sha "$GITHUB_PR_HEAD_SHA" --arg author "$PR_AUTHOR_LC" --slurpfile commits "$PR_COMMITS_FILE" '
      ([ $commits[0][] | (.author.login // empty), (.committer.login // empty) ]
        | map(ascii_downcase) | unique) as $coders
      | [ .[] | select(.user != null and (.user.type // "") != "Bot")
              | select((.state // "") != "COMMENTED" and (.state // "") != "PENDING") ]
      | sort_by(.id) | group_by(.user.login | ascii_downcase) | map(last)
      | map(select(.state == "APPROVED" and .commit_id == $sha))
      | map(.user.login) | map(select((ascii_downcase) != $author and (ascii_downcase | IN($coders[]) | not)))
      | .[] | select(test("^[A-Za-z0-9-]{1,39}$"))' "$REVIEWS_FILE")
    APPROVALS=0
    for login in $CANDIDATES; do
      new_tmp PERM_FILE
      PCODE=$(curl -sS -o "$PERM_FILE" -w '%{http_code}' --max-time 15 -H @"$GH_HDR" \
        -H "Accept: application/vnd.github+json" \
        "${GH_API%/}/repos/${GITHUB_REPO}/collaborators/${login}/permission" 2>/dev/null || echo "000")
      if [ "$PCODE" = "200" ] && jq -e '.permission == "admin" or .permission == "write" or .permission == "maintain" or (.role_name // "" | IN("admin","maintain","write"))' "$PERM_FILE" >/dev/null 2>&1; then
        APPROVALS=$((APPROVALS + 1))
      fi
    done
    if [ "$APPROVALS" -lt "$REQUIRED_APPROVALS" ]; then
      echo "❌ Freigabe-Regel verlangt ${REQUIRED_APPROVALS} Freigabe(n) für den aktuellen Commit von Personen mit Schreibrecht, vorhanden: ${APPROVALS}."
      echo "   Nicht gezählt: PR-Autor, Commit-Autoren des PRs, Bots, Freigaben älterer Commits."
      summary_result "**❌ Freigaben: ${APPROVALS} von ${REQUIRED_APPROVALS}.** Der Check wird grün, sobald genug Personen mit Schreibrecht den aktuellen Commit freigeben. Nicht gezählt: PR-Autor, Commit-Autoren dieses PRs, Bots, Freigaben älterer Commits."
      exit 1
    fi
    echo "✅ ${APPROVALS} von ${REQUIRED_APPROVALS} nötigen Freigabe(n) vorhanden."
    summary_result "**✅ Freigaben: ${APPROVALS} von ${REQUIRED_APPROVALS}.**"
  fi
fi

if [ "$STATUS" = "BLOCKED" ] && [ "$FAIL_ON_BLOCKED" = "true" ]; then
  echo "❌ Deployment blockiert — Risk Score zu hoch (${SCORE}/100)."
  exit 1
fi

if [ "$GATE_DECISION" = "blocked" ] && [ "$FAIL_ON_BLOCKED" = "true" ]; then
  echo "❌ Deployment blockiert — Freigabe-Regel greift (siehe Gründe oben)."
  exit 1
fi

if [ "$STATUS" = "BLOCKED" ]; then
  echo "⚠️  Status BLOCKED, aber fail-on-blocked ist deaktiviert (${SCORE}/100). Deployment wird fortgesetzt."
fi

if [ "$STATUS" = "WARN" ]; then
  echo "⚠️  Warnung — erhöhtes Risiko (${SCORE}/100). Deployment wird fortgesetzt."
fi

if [ "$STATUS" = "PASS" ]; then
  case "$GATE_DECISION" in
    review|two_reviewers)
      echo "✅ Score unkritisch (${SCORE}/100) — laut Freigabe-Regel: ${GATE_TEXT}." ;;
    *)
      echo "✅ Deployment freigegeben (${SCORE}/100)." ;;
  esac
fi
