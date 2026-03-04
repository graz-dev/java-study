#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# Deploy petclinic: delete existing resources and re-apply with new config
# ===========================================================================

NAMESPACE="microservices-demo"
DEPLOYMENT_NAME="petclinic"
HPA_NAME="petclinic"
DRY_RUN=false

TEMPL_DEPLOY="/work/code/java-study/app/resources/petclinic_templ.yaml"
ACTUAL_DEPLOY="/work/code/java-study/app/resources/petclinic_actual.yaml"
TEMPL_HPA="/work/code/java-study/app/kube/petclinic-hpa_templ.yaml"
ACTUAL_HPA="/work/code/java-study/app/kube/petclinic-hpa_actual.yaml"

CPU_REQUEST=""
CPU_LIMIT=""
MEMORY_REQUEST=""
MEMORY_LIMIT=""
JVM_OPTS=""
HPA_CPU_TARGET=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Delete and re-apply petclinic Deployment with new resource values,
JDK_JAVA_OPTIONS, and HPA CPU target.

Required:
  --cpu-request <value>       CPU request (e.g. 750m)
  --cpu-limit <value>         CPU limit (e.g. 10000m)
  --memory-request <value>    Memory request (e.g. 2048Mi)
  --memory-limit <value>      Memory limit (e.g. 8192Mi)
  --jvm-opts <value>          JDK_JAVA_OPTIONS string
  --hpa-cpu-target <value>    HPA CPU target percentage (e.g. 50)

Optional:
  --namespace <ns>            Namespace (default: microservices-demo)
  --dry-run                   Print actions without executing
  -h, --help                  Show this help message
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu-request)    CPU_REQUEST="$2";    shift 2 ;;
    --cpu-limit)      CPU_LIMIT="$2";      shift 2 ;;
    --memory-request) MEMORY_REQUEST="$2"; shift 2 ;;
    --memory-limit)   MEMORY_LIMIT="$2";   shift 2 ;;
    --jvm-opts)       JVM_OPTS="$2";       shift 2 ;;
    --hpa-cpu-target) HPA_CPU_TARGET="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2";      shift 2 ;;
    --dry-run)        DRY_RUN=true;        shift   ;;
    -h|--help)        usage ;;
    *)
      echo "[ERROR] Unknown option: $1"
      echo "Use --help for usage."
      exit 1
      ;;
  esac
done

MISSING=()
[[ -z "$CPU_REQUEST" ]]    && MISSING+=("--cpu-request")
[[ -z "$CPU_LIMIT" ]]      && MISSING+=("--cpu-limit")
[[ -z "$MEMORY_REQUEST" ]] && MISSING+=("--memory-request")
[[ -z "$MEMORY_LIMIT" ]]   && MISSING+=("--memory-limit")
[[ -z "$JVM_OPTS" ]]       && MISSING+=("--jvm-opts")
[[ -z "$HPA_CPU_TARGET" ]] && MISSING+=("--hpa-cpu-target")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "[ERROR] Missing required arguments: ${MISSING[*]}"
  echo "Use --help for usage."
  exit 1
fi

run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] $*"
  else
    "$@"
  fi
}

# ===========================================================================
# 1. Genera manifest da template
# ===========================================================================
echo "=================================================="
echo "  Generazione manifest"
echo "=================================================="
echo "  cpu request:      $CPU_REQUEST"
echo "  cpu limit:        $CPU_LIMIT"
echo "  memory request:   $MEMORY_REQUEST"
echo "  memory limit:     $MEMORY_LIMIT"
echo "  JDK_JAVA_OPTIONS: $JVM_OPTS"
echo "  HPA CPU target:   ${HPA_CPU_TARGET}%"
echo ""

awk \
  -v cpu_req="$CPU_REQUEST" \
  -v cpu_lim="$CPU_LIMIT" \
  -v mem_req="$MEMORY_REQUEST" \
  -v mem_lim="$MEMORY_LIMIT" \
  -v jvm="$JVM_OPTS" \
'
/name: JDK_JAVA_OPTIONS/ {
  print
  getline
  match($0, /^[[:space:]]+/)
  print substr($0, 1, RLENGTH) "value: \"" jvm "\""
  next
}
/^[[:space:]]+requests:/ { section="requests" }
/^[[:space:]]+limits:/   { section="limits" }
section == "requests" && /^[[:space:]]+cpu:/ {
  match($0, /^[[:space:]]+/)
  print substr($0, 1, RLENGTH) "cpu: " cpu_req
  next
}
section == "requests" && /^[[:space:]]+memory:/ {
  match($0, /^[[:space:]]+/)
  print substr($0, 1, RLENGTH) "memory: " mem_req
  next
}
section == "limits" && /^[[:space:]]+cpu:/ {
  match($0, /^[[:space:]]+/)
  print substr($0, 1, RLENGTH) "cpu: " cpu_lim
  next
}
section == "limits" && /^[[:space:]]+memory:/ {
  match($0, /^[[:space:]]+/)
  print substr($0, 1, RLENGTH) "memory: " mem_lim
  next
}
{ print }
' "$TEMPL_DEPLOY" > "$ACTUAL_DEPLOY"

awk -v target="$HPA_CPU_TARGET" '
/averageUtilization:/ {
  match($0, /^[[:space:]]+/)
  print substr($0, 1, RLENGTH) "averageUtilization: " target
  next
}
{ print }
' "$TEMPL_HPA" > "$ACTUAL_HPA"

echo "  Manifest generati:"
echo "    $ACTUAL_DEPLOY"
echo "    $ACTUAL_HPA"
echo ""

# ===========================================================================
# 2. Delete risorse esistenti
# ===========================================================================
echo "=================================================="
echo "  Delete risorse esistenti"
echo "=================================================="

run_cmd kubectl delete deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --ignore-not-found --wait
run_cmd kubectl delete hpa "$HPA_NAME" -n "$NAMESPACE" --ignore-not-found

echo ""

# ===========================================================================
# 3. Apply nuove risorse
# ===========================================================================
echo "=================================================="
echo "  Apply nuove risorse"
echo "=================================================="

run_cmd kubectl apply -f "$ACTUAL_DEPLOY"
run_cmd kubectl apply -f "$ACTUAL_HPA"

echo ""

# ===========================================================================
# 4. Attendi rollout
# ===========================================================================
echo "=================================================="
echo "  Attendi rollout: $DEPLOYMENT_NAME"
echo "=================================================="

run_cmd kubectl rollout status deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout=300s

echo ""

# ===========================================================================
# Riepilogo
# ===========================================================================
echo "=================================================="
echo "  DONE"
echo "=================================================="
if [[ "$DRY_RUN" == true ]]; then
  echo "  [DRY RUN] Nessuna modifica applicata."
else
  echo "  Deployment: $DEPLOYMENT_NAME"
  echo "  Namespace:  $NAMESPACE"
  echo "  Verificare con:"
  echo "    kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE"
  echo "    kubectl get hpa -n $NAMESPACE"
fi
