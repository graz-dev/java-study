#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# Patch Deployment petclinic: risorse, JDK_JAVA_OPTIONS e HPA
# ===========================================================================

NAMESPACE="microservices-demo"
DEPLOYMENT_NAME="petclinic"
DRY_RUN=false

# Parametri obbligatori (inizializzati vuoti)
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

Patch the petclinic Deployment with new resource values,
JDK_JAVA_OPTIONS, and HPA CPU target.

Required:
  --cpu-request <value>       CPU request (e.g. 500m)
  --cpu-limit <value>         CPU limit (e.g. 2000m)
  --memory-request <value>    Memory request (e.g. 2048Mi)
  --memory-limit <value>      Memory limit (e.g. 8192Mi)
  --jvm-opts <value>          JDK_JAVA_OPTIONS string (e.g. "-Xmx4096m -XX:+UseG1GC")
  --hpa-cpu-target <value>    HPA CPU target percentage (e.g. 70)

Optional:
  --namespace <ns>            Namespace (default: microservices-demo)
  --dry-run                   Print kubectl commands without executing
  -h, --help                  Show this help message

Examples:
  # Dry run
  $(basename "$0") --dry-run \\
    --cpu-request 500m --cpu-limit 2000m \\
    --memory-request 2048Mi --memory-limit 8192Mi \\
    --jvm-opts "-Xmx4096m -XX:+UseG1GC" \\
    --hpa-cpu-target 70

  # Live
  $(basename "$0") \\
    --cpu-request 750m --cpu-limit 2000m \\
    --memory-request 2048Mi --memory-limit 8192Mi \\
    --jvm-opts "-Xmx4096m -XX:+UseG1GC -XX:MinHeapFreeRatio=10" \\
    --hpa-cpu-target 50
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

# Validazione parametri obbligatori
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

# Wrapper per dry-run
run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] $*"
  else
    "$@"
  fi
}

# ===========================================================================
# 1. Verifica Deployment
# ===========================================================================
echo "=================================================="
echo "  Verifica Deployment: $DEPLOYMENT_NAME"
echo "=================================================="

if ! kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "[ERROR] Deployment '$DEPLOYMENT_NAME' non trovato nel namespace '$NAMESPACE'"
  exit 1
fi

echo "  Deployment trovato: $DEPLOYMENT_NAME"
echo ""

# Ricava l'HPA che punta al deployment
HPA_NAME=$(kubectl get hpa -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.scaleTargetRef.name}{"\n"}{end}' \
  | awk -v dep="$DEPLOYMENT_NAME" '$2 == dep {print $1}' \
  | head -1 || true)

if [[ -z "$HPA_NAME" ]]; then
  echo "[WARNING] Nessun HPA trovato per '$DEPLOYMENT_NAME'. Salto patch HPA."
  HPA_FOUND=false
else
  echo "  HPA trovato: $HPA_NAME"
  HPA_FOUND=true
fi
echo ""

# ===========================================================================
# 2. Stato attuale
# ===========================================================================
echo "=================================================="
echo "  Stato attuale"
echo "=================================================="

echo "  Resources:"
kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" \
  -o jsonpath='    cpu request:    {.spec.template.spec.containers[0].resources.requests.cpu}
    cpu limit:      {.spec.template.spec.containers[0].resources.limits.cpu}
    memory request: {.spec.template.spec.containers[0].resources.requests.memory}
    memory limit:   {.spec.template.spec.containers[0].resources.limits.memory}
'
echo ""

echo "  JDK_JAVA_OPTIONS:"
JVM_CURRENT=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JDK_JAVA_OPTIONS")].value}')
echo "    ${JVM_CURRENT:-<non impostato>}"
echo ""

if [[ "$HPA_FOUND" == true ]]; then
  echo "  HPA CPU target:"
  HPA_CURRENT=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.metrics[?(@.resource.name=="cpu")].resource.target.averageUtilization}' 2>/dev/null || true)
  echo "    ${HPA_CURRENT:-<non trovato>}%"
  echo ""
fi

# ===========================================================================
# 3. Patch Deployment (resources + JDK_JAVA_OPTIONS)
# ===========================================================================
echo "=================================================="
echo "  Patch Deployment: $DEPLOYMENT_NAME"
echo "=================================================="
echo "  Nuovi valori:"
echo "    cpu request:      $CPU_REQUEST"
echo "    cpu limit:        $CPU_LIMIT"
echo "    memory request:   $MEMORY_REQUEST"
echo "    memory limit:     $MEMORY_LIMIT"
echo "    JDK_JAVA_OPTIONS: $JVM_OPTS"
echo ""

CONTAINER_NAME=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].name}')

PATCH_JSON=$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "$CONTAINER_NAME",
          "resources": {
            "requests": {
              "cpu": "$CPU_REQUEST",
              "memory": "$MEMORY_REQUEST"
            },
            "limits": {
              "cpu": "$CPU_LIMIT",
              "memory": "$MEMORY_LIMIT"
            }
          },
          "env": [{
            "name": "JDK_JAVA_OPTIONS",
            "value": "$JVM_OPTS"
          }]
        }]
      }
    }
  }
}
EOF
)

run_cmd kubectl patch deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" \
  --type strategic \
  -p "$PATCH_JSON"

echo ""
echo "  Deployment patchato."
echo ""

# ===========================================================================
# 4. Attendi completamento rollout
# ===========================================================================
echo "=================================================="
echo "  Attendi rollout: $DEPLOYMENT_NAME"
echo "=================================================="

run_cmd kubectl rollout status deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout=300s

echo ""
echo "  Rollout completato."
echo ""

# ===========================================================================
# 5. Patch HPA
# ===========================================================================
if [[ "$HPA_FOUND" == true ]]; then
  echo "=================================================="
  echo "  Patch HPA: $HPA_NAME"
  echo "=================================================="
  echo "  Nuovo CPU target: ${HPA_CPU_TARGET}%"
  echo ""

  run_cmd kubectl patch hpa "$HPA_NAME" -n "$NAMESPACE" \
    --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/metrics/0/resource/target/averageUtilization\",\"value\":${HPA_CPU_TARGET}}]"

  echo ""
  echo "  HPA patchato."
  echo ""
fi

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
  echo "    kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].resources}'"
  echo "    kubectl get hpa -n $NAMESPACE"
fi
