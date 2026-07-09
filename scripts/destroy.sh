#!/usr/bin/env bash
# Full teardown: every AWS resource this pipeline creates, then local TF state.
#
# Idempotent — safe to re-run after partial failure. Every step tolerates
# "already gone".
#
# Discovers the resource-name prefix from terraform.tfvars (or default).
# No hardcoded account IDs. Confirmation prompt up front.
#
# Ordering matters:
#   1. Terminate in-flight jobs   (else queue can't be disabled cleanly)
#   2. Disable + delete queue     (must precede CE delete — CE won't drop while queue exists)
#   3. Disable + delete CE        (retry on "being modified" — AWS eventual consistency)
#   4. Deregister job defs        (all revisions)
#   5. Delete EventBridge rule    (targets first, then rule)
#   6. Force-delete ECR repo      (includes all images)
#   7. Empty + delete S3 bucket   (versions + delete-markers first)
#   8. Detach + delete IAM roles + policies + instance profile
#   9. Wait for IAM eventual consistency
#  10. terraform destroy          (mops up anything left; expected to be a no-op)
#  11. Wipe local terraform state

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

# ─ Resolve config
if [[ ! -f "$TF_DIR/main.tf" ]]; then
  echo "ERROR: $TF_DIR/main.tf not found." >&2
  exit 1
fi

# Try to read the prefix from a tfvars; fall back to the default in main.tf.
PREFIX="nuextract-batch"
if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
  P=$(grep -E '^[[:space:]]*name_prefix[[:space:]]*=' "$TF_DIR/terraform.tfvars" \
      | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1)
  [[ -n "$P" ]] && PREFIX="$P"
fi

REGION="${REGION:-us-east-1}"
if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
  R=$(grep -E '^[[:space:]]*aws_region[[:space:]]*=' "$TF_DIR/terraform.tfvars" \
      | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1)
  [[ -n "$R" ]] && REGION="$R"
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)

QUEUE="${PREFIX}-queue"
CE="${PREFIX}-gpu-spot"
JOB_DEF="${PREFIX}-worker"
RULE="${PREFIX}-ingest"
ECR_REPO="${PREFIX}-runner"
BUCKET="${PREFIX}-${ACCOUNT}"

IAM_ROLES=(
  "${PREFIX}-batch-service"
  "${PREFIX}-ecs-instance"
  "${PREFIX}-spot-fleet"
  "${PREFIX}-job"
  "${PREFIX}-execution"
  "${PREFIX}-events-to-batch"
)
IAM_POLICIES=(
  "${PREFIX}-s3-access"
  "${PREFIX}-submit-job"
  "${PREFIX}-execution-secrets"
)
INSTANCE_PROFILE="${PREFIX}-ecs-instance"

cat <<EOF

════════════════════════════════════════════════════════════════
  DESTROY — irreversible
────────────────────────────────────────────────────────────────
  Identity:     $USER_ARN
  Account:      $ACCOUNT
  Region:       $REGION

  Will DELETE:
    • Batch queue           $QUEUE
    • Batch compute env     $CE
    • Batch job defs        $JOB_DEF (all revisions)
    • EventBridge rule      $RULE
    • IAM roles             ${IAM_ROLES[*]}
    • IAM policies          ${IAM_POLICIES[*]}
    • Instance profile      $INSTANCE_PROFILE
    • ECR repo + images     $ECR_REPO
    • S3 bucket + contents  $BUCKET
    • Local TF state        $TF_DIR/.terraform, terraform.tfstate*
════════════════════════════════════════════════════════════════

EOF
read -r -p "Type 'DESTROY' (uppercase) to proceed: " confirm
[[ "$confirm" == "DESTROY" ]] || { echo "aborted."; exit 1; }
echo

step() { echo; echo "═══ $* ═══"; }
sub()  { echo "  • $*"; }
ok()   { echo "    ✓ $*"; }
skip() { echo "    ⤍ skipped (not found)"; }

# ─── 1. Terminate any in-flight jobs ─────────────────────────────────────────
step "1/11  Terminate in-flight Batch jobs"
for s in SUBMITTED PENDING RUNNABLE STARTING RUNNING; do
  ids=$(aws batch list-jobs --job-queue "$QUEUE" --job-status "$s" --region "$REGION" \
        --query 'jobSummaryList[*].jobId' --output text 2>/dev/null || true)
  for id in $ids; do
    sub "terminate $id ($s)"
    aws batch terminate-job --job-id "$id" --reason "destroy.sh" --region "$REGION" >/dev/null 2>&1 || true
  done
done
ok "done"

# ─── 2. Disable + delete Batch job queue ─────────────────────────────────────
step "2/11  Batch job queue"
state=$(aws batch describe-job-queues --job-queues "$QUEUE" --region "$REGION" \
        --query 'jobQueues[0].state' --output text 2>/dev/null || echo MISSING)
if [[ "$state" == "MISSING" || "$state" == "None" ]]; then
  skip
else
  if [[ "$state" != "DISABLED" ]]; then
    sub "disabling"
    aws batch update-job-queue --job-queue "$QUEUE" --state DISABLED --region "$REGION" >/dev/null
    until [[ "$(aws batch describe-job-queues --job-queues "$QUEUE" --region "$REGION" \
              --query 'jobQueues[0].state' --output text 2>/dev/null)" == "DISABLED" ]]; do
      echo "    waiting for DISABLED…"; sleep 3
    done
    sleep 5  # extra settling — disable can be complete but still "being modified"
  fi
  sub "deleting"
  deleted=0
  for i in $(seq 1 12); do
    echo "    attempt $i/12…"
    if aws batch delete-job-queue --job-queue "$QUEUE" --region "$REGION" 2>/tmp/_err; then
      deleted=1; break
    fi
    if grep -q "being modified" /tmp/_err; then
      echo "      AWS: being modified — waiting 10s"; sleep 10; continue
    fi
    cat /tmp/_err >&2; exit 1
  done
  [[ "$deleted" == "1" ]] || { echo "    delete-job-queue exhausted retries" >&2; exit 1; }
  for _ in $(seq 1 36); do
    s=$(aws batch describe-job-queues --job-queues "$QUEUE" --region "$REGION" \
        --query 'jobQueues[0].status' --output text 2>/dev/null || echo None)
    [[ -z "$s" || "$s" == "None" ]] && break
    echo "    polling delete (status=$s)…"; sleep 5
  done
  ok "queue deleted"
fi

# ─── 3. Disable + delete Batch compute environment ───────────────────────────
step "3/11  Batch compute environment"
state=$(aws batch describe-compute-environments --compute-environments "$CE" --region "$REGION" \
        --query 'computeEnvironments[0].state' --output text 2>/dev/null || echo MISSING)
if [[ "$state" == "MISSING" || "$state" == "None" ]]; then
  skip
else
  if [[ "$state" != "DISABLED" ]]; then
    sub "disabling"
    aws batch update-compute-environment --compute-environment "$CE" --state DISABLED --region "$REGION" >/dev/null
    until [[ "$(aws batch describe-compute-environments --compute-environments "$CE" --region "$REGION" \
              --query 'computeEnvironments[0].status' --output text 2>/dev/null)" == "VALID" ]]; do
      echo "    waiting for VALID…"; sleep 5
    done
  fi
  sub "deleting"
  deleted=0
  for i in $(seq 1 12); do
    echo "    attempt $i/12…"
    if aws batch delete-compute-environment --compute-environment "$CE" --region "$REGION" 2>/tmp/_err; then
      deleted=1; break
    fi
    if grep -qE "being modified|JobQueue relationship" /tmp/_err; then
      echo "      AWS: $(head -1 /tmp/_err) — waiting 10s"; sleep 10; continue
    fi
    cat /tmp/_err >&2; exit 1
  done
  [[ "$deleted" == "1" ]] || { echo "    delete-compute-environment exhausted retries" >&2; exit 1; }
  for _ in $(seq 1 36); do
    s=$(aws batch describe-compute-environments --compute-environments "$CE" --region "$REGION" \
        --query 'computeEnvironments[0].status' --output text 2>/dev/null || echo None)
    [[ -z "$s" || "$s" == "None" ]] && break
    echo "    polling delete (status=$s)…"; sleep 5
  done
  ok "compute env deleted"
fi

# ─── 4. Deregister every job def revision ────────────────────────────────────
step "4/11  Batch job definitions"
sub "$JOB_DEF"
arns=$(aws batch describe-job-definitions --job-definition-name "$JOB_DEF" --status ACTIVE \
       --region "$REGION" --query 'jobDefinitions[*].jobDefinitionArn' --output text 2>/dev/null || true)
if [[ -z "$arns" || "$arns" == "None" ]]; then
  skip
else
  for arn in $arns; do
    aws batch deregister-job-definition --job-definition "$arn" --region "$REGION" >/dev/null
    ok "deregistered $arn"
  done
fi

# ─── 5. EventBridge rule ─────────────────────────────────────────────────────
step "5/11  EventBridge rule"
if aws events describe-rule --name "$RULE" --region "$REGION" >/dev/null 2>&1; then
  sub "removing targets"
  ids=$(aws events list-targets-by-rule --rule "$RULE" --region "$REGION" \
        --query 'Targets[*].Id' --output text 2>/dev/null || true)
  [[ -n "$ids" && "$ids" != "None" ]] && aws events remove-targets --rule "$RULE" --ids $ids --region "$REGION" >/dev/null
  sub "deleting rule"
  aws events delete-rule --name "$RULE" --region "$REGION"
  ok "rule deleted"
else
  skip
fi

# ─── 6. ECR repo (force — includes all images) ───────────────────────────────
step "6/11  ECR repo $ECR_REPO"
if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1; then
  aws ecr delete-repository --repository-name "$ECR_REPO" --region "$REGION" --force >/dev/null
  ok "deleted (images included)"
else
  skip
fi

# ─── 7. S3 bucket ────────────────────────────────────────────────────────────
step "7/11  S3 bucket $BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  sub "emptying current objects"
  aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" >/dev/null || true
  # Delete any versions / delete-markers (in case versioning was enabled)
  for kind in Versions DeleteMarkers; do
    j=$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" \
        --query "{Objects: ${kind}[].{Key:Key,VersionId:VersionId}}" --output json 2>/dev/null || echo '{}')
    if [[ "$j" != '{}' && "$j" != '{"Objects":null}' ]]; then
      echo "$j" > /tmp/_versions.json
      aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/_versions.json --region "$REGION" >/dev/null 2>&1 || true
    fi
  done
  sub "deleting bucket"
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
  ok "deleted"
else
  skip
fi

# ─── 8. IAM ─────────────────────────────────────────────────────────────────
step "8/11  IAM roles + policies + instance profile"

# Instance profile — remove roles first, then delete
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
  sub "instance profile $INSTANCE_PROFILE"
  for role in $(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" \
                --query 'InstanceProfile.Roles[*].RoleName' --output text); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --role-name "$role" || true
  done
  aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE"
  ok "deleted"
fi

# Roles — detach all attached + inline policies, remove from any instance
# profile they're still bound to, then delete.
for role in "${IAM_ROLES[@]}"; do
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    sub "role $role"; skip; continue
  fi
  sub "role $role"
  for arn in $(aws iam list-attached-role-policies --role-name "$role" \
               --query 'AttachedPolicies[*].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" || true
  done
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[*]' --output text); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p" || true
  done
  for ip in $(aws iam list-instance-profiles-for-role --role-name "$role" \
              --query 'InstanceProfiles[*].InstanceProfileName' --output text); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$role" || true
  done
  aws iam delete-role --role-name "$role"
  ok "deleted"
done

# Customer-managed policies — must come AFTER role detachment
for pol in "${IAM_POLICIES[@]}"; do
  arn="arn:aws:iam::${ACCOUNT}:policy/${pol}"
  if ! aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    sub "policy $pol"; skip; continue
  fi
  sub "policy $pol"
  for v in $(aws iam list-policy-versions --policy-arn "$arn" \
             --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" || true
  done
  aws iam delete-policy --policy-arn "$arn"
  ok "deleted"
done

# ─── 9. Wait for IAM eventual consistency ────────────────────────────────────
step "9/11  IAM propagation"
sub "verifying names are gone (read-after-delete can lag ~60s)"
for i in $(seq 1 18); do
  still=$(aws iam list-roles \
          --query "Roles[?contains(RoleName,\`${PREFIX}-\`)].RoleName" \
          --output text)
  still+=" $(aws iam list-policies --scope Local \
             --query "Policies[?contains(PolicyName,\`${PREFIX}-\`)].PolicyName" \
             --output text)"
  if [[ -z "${still// /}" ]]; then
    ok "gone after $((i*5))s"; break
  fi
  echo "    still visible: ${still}"; sleep 5
done

# ─── 10. terraform destroy (mop-up) ──────────────────────────────────────────
step "10/11  terraform destroy (expected no-op after manual cleanup)"
if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
  ( cd "$TF_DIR" && terraform destroy -auto-approve -input=false ) || \
    echo "    (terraform destroy nonzero — expected if all resources were already gone)"
else
  sub "no terraform.tfstate — skipping"
fi

# ─── 11. Wipe local TF state ─────────────────────────────────────────────────
step "11/11  Wipe local TF state"
cd "$TF_DIR"
rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup tfplan
ok "wiped"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  destroy complete."
echo "════════════════════════════════════════════════════════════════"
