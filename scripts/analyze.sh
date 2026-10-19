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
# Zeilen, die (nach Leerzeichen) mit "::" oder "##[" beginnen, bekommen ein Präfix.
sanitize() {
  sed -E 's/^([[:space:]]*)(::|##\[)/\1> \2/'
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
NUMSTAT=$(git diff --numstat "$DIFF_BASE" HEAD) || die "git diff --numstat ${DIFF_BASE}..HEAD fehlgeschlagen."
ADDED=$(printf '%s\n' "$NUMSTAT" | awk '$1 ~ /^[0-9]+$/ {sum += $1} END {print sum+0}')
REMOVED=$(printf '%s\n' "$NUMSTAT" | awk '$2 ~ /^[0-9]+$/ {sum += $2} END {print sum+0}')

new_tmp NAMES_FILE
git -c core.quotePath=false diff --name-only -z "$DIFF_BASE" HEAD > "$NAMES_FILE" \
  || die "git diff --name-only ${DIFF_BASE}..HEAD fehlgeschlagen."

CHANGED_FILES=()
while IFS= read -r -d '' f; do
  [ -n "$f" ] && CHANGED_FILES+=("$f")
done < "$NAMES_FILE"
FILES=${#CHANGED_FILES[@]}

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
  PKG_MAJOR=$(git diff "$DIFF_BASE" HEAD -- package.json 2>/dev/null | \
    grep '^[+-]' | grep -v '^---\|^+++' | \
    grep -oE '"[0-9]+\.' | grep -oE '[0-9]+' | \
    sort -n | uniq -d | wc -l | tr -d ' ')
  [ -z "$PKG_MAJOR" ] && PKG_MAJOR=0
  MAJOR_BUMPS=$((MAJOR_BUMPS + PKG_MAJOR))
fi

if printf '%s' "$CHANGED_LIST" | grep -q 'requirements\.txt'; then
  REQ_MAJOR=$(git diff "$DIFF_BASE" HEAD -- requirements.txt 2>/dev/null | \
    grep '^[+-][a-zA-Z]' | grep -oE '==[0-9]+' | grep -oE '[0-9]+' | \
    sort | uniq -d | wc -l | tr -d ' ')
  [ -z "$REQ_MAJOR" ] && REQ_MAJOR=0
  MAJOR_BUMPS=$((MAJOR_BUMPS + REQ_MAJOR))
fi

if printf '%s' "$CHANGED_LIST" | grep -q 'go\.mod'; then
  GO_MAJOR=$(git diff "$DIFF_BASE" HEAD -- go.mod 2>/dev/null | \
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
    '$s | split(",") | map(select(length > 0)) | .[:500] | map(.[:300])' > "$PATHS_FILE" \
    || die "diff-changed-paths konnte nicht verarbeitet werden."
else
  jq -Rs 'split("\u0000") | map(select(length > 0)) | .[:500] | map(.[:300])' < "$NAMES_FILE" > "$PATHS_FILE" \
    || die "Geänderte Pfade konnten nicht verarbeitet werden."
fi
PATHS_COUNT=$(jq 'length' "$PATHS_FILE")
PATHS_PREVIEW=$(jq -r '.[:20] | join(",")' "$PATHS_FILE")
[ "$PATHS_COUNT" -gt 20 ] && PATHS_PREVIEW="${PATHS_PREVIEW},… (${PATHS_COUNT} gesamt)"

# Alle Zähler sind intern berechnet — trotzdem prüfen, bevor sie als JSON-Zahl gehen
for v in "$ADDED" "$REMOVED" "$FILES" "$K8S" "$HELM_VALUES" "$DEP_FILES" "$MAJOR_BUMPS"; do
  [[ "$v" =~ ^[0-9]+$ ]] || die "Interner Fehler: ungültiger Zählerwert '${v}'."
done

# ── Debug Output ─────────────────────────────────────────────────────────
echo "  [guard] diff_lines_added:     ${ADDED}"
echo "  [guard] diff_lines_removed:   ${REMOVED}"
echo "  [guard] diff_files_changed:   ${FILES}"
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

# ── Payload bauen (jq, keine String-Interpolation) ───────────────────────
new_tmp PAYLOAD_FILE
jq -n \
  --arg     repo                      "${GITHUB_REPO:-}" \
  --arg     branch                    "${GITHUB_BRANCH:-}" \
  --arg     commit_sha                "${GITHUB_SHA:-}" \
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
    has_setup_py: $has_setup_py
  }' > "$PAYLOAD_FILE" || die "Payload konnte nicht erzeugt werden."

# ── Fehlerbehandlung: fail-open vs. fail-closed ──────────────────────────
# fail-open=true  → API nicht erreichbar / 429 / 5xx / ungültige Antwort: Warnung, Deployment läuft weiter (Standard)
# fail-open=false → dieselben Fälle brechen ab
# 400/401/403/422 (falscher Key, fehlerhafte Anfrage) brechen IMMER ab.
new_tmp RESP_FILE

print_body() {
  if [ -s "$RESP_FILE" ]; then
    echo "Response (gekürzt):"
    head -c 2000 "$RESP_FILE" | sanitize
    echo ""
  fi
}

soft_fail() {
  if [ "$FAIL_OPEN" = "true" ]; then
    echo "⚠️  Deployment Guard: $1 — Deployment wird ohne Bewertung fortgesetzt (fail-open). Strenger: fail-open: 'false'."
    print_body
    exit 0
  fi
  echo "❌ Deployment Guard: $1 — Deployment wird gestoppt (fail-open ist deaktiviert)." >&2
  echo "   Wenn Ausfälle der API das Deployment nicht blockieren sollen: fail-open: 'true' setzen." >&2
  print_body
  exit 1
}

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
    echo "❌ Deployment Guard: API Key ungültig oder ohne Berechtigung (HTTP ${HTTP_CODE})." >&2
    print_body
    exit 1 ;;
  400|422)
    echo "❌ Deployment Guard: Anfrage abgelehnt (HTTP ${HTTP_CODE}) — Eingaben prüfen." >&2
    print_body
    exit 1 ;;
  429)
    soft_fail "Analyse-Limit erreicht (HTTP 429)" ;;
  5??)
    soft_fail "API-Fehler (HTTP ${HTTP_CODE})" ;;
  *)
    soft_fail "Unerwartete API-Antwort (HTTP ${HTTP_CODE})" ;;
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
printf '  Commit:  %s\n' "${GITHUB_SHA:0:7}"
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

if [ -n "$STOP_TOKEN" ]; then
  echo "::${STOP_TOKEN}::"
fi

if [ "$STATUS" = "BLOCKED" ] && [ "$FAIL_ON_BLOCKED" = "true" ]; then
  echo "❌ Deployment blockiert — Risk Score zu hoch (${SCORE}/100)."
  exit 1
fi

if [ "$STATUS" = "BLOCKED" ]; then
  echo "⚠️  Status BLOCKED, aber fail-on-blocked ist deaktiviert (${SCORE}/100). Deployment wird fortgesetzt."
fi

if [ "$STATUS" = "WARN" ]; then
  echo "⚠️  Warnung — erhöhtes Risiko (${SCORE}/100). Deployment wird fortgesetzt."
fi

if [ "$STATUS" = "PASS" ]; then
  echo "✅ Deployment freigegeben (${SCORE}/100)."
fi
