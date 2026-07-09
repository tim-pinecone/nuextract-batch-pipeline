#!/usr/bin/env bash
# Recover from the TF-Batch dependency-order error:
#   "Cannot delete, found existing JobQueue relationship"
#
# Disables + deletes the queue so the old compute env can be destroyed,
# then resumes `terraform apply`. TF refreshes state, sees the queue is
# gone, and creates a fresh one pointing at the new CE.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

PREFIX="nuextract-batch"
if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
  P=$(grep -E '^[[:space:]]*name_prefix[[:space:]]*=' "$TF_DIR/terraform.tfvars" \
      | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1)
  [[ -n "$P" ]] && PREFIX="$P"
fi
REGION="${REGION:-us-east-1}"
QUEUE="${PREFIX}-queue"

queue_state() {
  aws batch describe-job-queues --job-queues "$QUEUE" --region "$REGION" \
    --query 'jobQueues[0].state' --output text 2>/dev/null || echo "MISSING"
}
queue_status() {
  aws batch describe-job-queues --job-queues "$QUEUE" --region "$REGION" \
    --query 'jobQueues[0].status' --output text 2>/dev/null || echo "MISSING"
}

echo "[1/4] Checking queue state…"
state=$(queue_state)
echo "      state=$state"

if [[ "$state" == "MISSING" || "$state" == "None" ]]; then
  echo "      queue already gone; skipping disable/delete"
else
  if [[ "$state" != "DISABLED" ]]; then
    echo "[2/4] Disabling queue…"
    aws batch update-job-queue --job-queue "$QUEUE" --state DISABLED --region "$REGION" >/dev/null
    until [[ "$(queue_state)" == "DISABLED" ]]; do echo "      waiting…"; sleep 3; done
  else
    echo "[2/4] Already DISABLED"
  fi

  echo "[3/4] Deleting queue (retry on 'being modified')…"
  attempts=0
  while (( attempts < 12 )); do
    if aws batch delete-job-queue --job-queue "$QUEUE" --region "$REGION" 2>/tmp/_del.err; then
      break
    fi
    if grep -q "being modified" /tmp/_del.err; then
      echo "      AWS: being modified — waiting 10s"; sleep 10; ((attempts++)); continue
    fi
    cat /tmp/_del.err >&2; exit 1
  done
  until [[ "$(queue_status)" == "MISSING" || "$(queue_status)" == "None" ]]; do
    echo "      polling delete (status=$(queue_status))…"; sleep 5
  done
  echo "      queue deleted"
fi

echo "[4/4] Resuming terraform apply in $TF_DIR …"
cd "$TF_DIR"
terraform apply
