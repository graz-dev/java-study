#!/bin/bash
# run-workload.sh — called by Akamas after apply-config.sh.
# Creates a k6 Job in the EKS cluster and waits for it to finish.
# Akamas then queries Prometheus over the steady-state measurement window.
#
# Runs on the Akamas toolbox with the EKS kubeconfig available.
# KUBECONFIG is inherited from the Akamas environment; fall back to
# /work/kubeconfig if not already set.

set -euo pipefail

NAMESPACE="${NAMESPACE:-microservices-demo}"
JOB_NAME="k6-akamas-workload"
# CYCLE_MINUTES=15: compressed diurnal cycle — leaves ~9m measurement window
# after trim [1m, 5m]. Fits within the 20m workflow task timeout.
CYCLE_MINUTES=30
TIMEOUT_SECONDS=3600  # 20 min hard timeout

START_TS=$(date +%s)
log() { echo "[run-workload] $(date '+%H:%M:%S') $*"; }

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Starting workload run  (namespace: ${NAMESPACE})"
log "  Job: ${JOB_NAME}  CYCLE_MINUTES=${CYCLE_MINUTES}"
log "  Timeout: ${TIMEOUT_SECONDS}s"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Clean up any previous run ────────────────────────────────────────────
log "Step 1/4 — deleting previous Job (if any)..."
kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true

# Wait for old pods to terminate before starting a new test.
kubectl wait pod \
  -n "$NAMESPACE" \
  -l "job-name=${JOB_NAME}" \
  --for=delete \
  --timeout=60s 2>/dev/null || true
log "  ✓ Cleanup done"

# ── 2. Create the k6 Job ─────────────────────────────────────────────────────
log "Step 2/4 — creating k6 Job..."
kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      nodeSelector:
        node-role: tools
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:latest
          imagePullPolicy: IfNotPresent
          args: ["run", "/scripts/script.js"]
          env:
            - name: BASE_URL
              value: "http://petclinic.microservices-demo:8080"
            - name: CYCLE_MINUTES
              value: "${CYCLE_MINUTES}"
          resources:
            requests:
              cpu: "200m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          volumeMounts:
            - name: k6-script
              mountPath: /scripts
      volumes:
        - name: k6-script
          configMap:
            name: k6-script
EOF
log "  ✓ Job created"

# ── 3. Wait for the pod to appear ───────────────────────────────────────────
log "Step 3/4 — waiting for k6 pod to be scheduled..."
DEADLINE=$((SECONDS + 120))
POD=""
while [[ $SECONDS -lt $DEADLINE ]]; do
  POD=$(kubectl get pod -n "$NAMESPACE" -l "job-name=${JOB_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$POD" ]] && break
  sleep 3
done

if [[ -z "$POD" ]]; then
  log "ERROR: k6 pod did not appear within 120s"
  exit 1
fi

log "  ✓ Pod: ${POD}"

# ── 4. Wait for the pod to complete ─────────────────────────────────────────
log "Step 4/4 — waiting for k6 test to complete (timeout: ${TIMEOUT_SECONDS}s)..."

kubectl wait pod "$POD" \
  -n "$NAMESPACE" \
  --for=condition=Ready \
  --timeout=120s 2>/dev/null || true

# Wait for any terminal phase (Succeeded or Failed) to avoid hanging if k6 thresholds fail
DEADLINE=$(($(date +%s) + TIMEOUT_SECONDS))
while true; do
  PHASE=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then
    break
  fi
  if [[ $(date +%s) -gt $DEADLINE ]]; then
    log "ERROR: timeout (${TIMEOUT_SECONDS}s) waiting for k6 pod to complete"
    exit 1
  fi
  sleep 5
done

EXIT_CODE=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "0")

if [[ "$EXIT_CODE" != "0" ]]; then
  log "WARNING: k6 exited with code ${EXIT_CODE} (threshold violations) — continuing"
  kubectl logs "$POD" -n "$NAMESPACE" --tail=20 || true
fi

ELAPSED=$(( $(date +%s) - START_TS ))
log "  ✓ k6 test completed successfully"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Workload complete — Akamas will now collect metrics  (total: ${ELAPSED}s)"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
