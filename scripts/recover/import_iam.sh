#!/usr/bin/env bash
# Import existing IAM resources into terraform state, then apply.
#
# Use when `terraform apply` fails with EntityAlreadyExists because AWS
# has the resources but local state was wiped. After importing, the next
# apply is a no-op for IAM and finishes the rest of the deploy.
#
# Idempotent: safe to re-run (skips already-imported, skips missing-in-AWS).

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
cd "$TF_DIR"

PREFIX="nuextract-batch"
if [[ -f "terraform.tfvars" ]]; then
  P=$(grep -E '^[[:space:]]*name_prefix[[:space:]]*=' terraform.tfvars \
      | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1)
  [[ -n "$P" ]] && PREFIX="$P"
fi
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "Account: $ACCOUNT  Prefix: $PREFIX  TF dir: $TF_DIR"; echo

import_if_needed() {
  local addr=$1 awsid=$2
  if terraform state show "$addr" >/dev/null 2>&1; then
    echo "  ⤍ $addr already in state"
    return
  fi
  if terraform import "$addr" "$awsid" 2>/dev/null; then
    echo "  ✓ imported $addr"
  else
    echo "  ⤍ $awsid not in AWS — skipping"
  fi
}

echo "═══ Roles ═══"
import_if_needed aws_iam_role.batch_service   "${PREFIX}-batch-service"
import_if_needed aws_iam_role.ecs_instance    "${PREFIX}-ecs-instance"
import_if_needed aws_iam_role.spot_fleet      "${PREFIX}-spot-fleet"
import_if_needed aws_iam_role.job             "${PREFIX}-job"
import_if_needed aws_iam_role.execution       "${PREFIX}-execution"
import_if_needed aws_iam_role.events_to_batch "${PREFIX}-events-to-batch"

echo; echo "═══ Instance profile ═══"
import_if_needed aws_iam_instance_profile.ecs_instance "${PREFIX}-ecs-instance"

echo; echo "═══ Customer-managed policies ═══"
import_if_needed aws_iam_policy.s3_access  "arn:aws:iam::${ACCOUNT}:policy/${PREFIX}-s3-access"
import_if_needed aws_iam_policy.submit_job "arn:aws:iam::${ACCOUNT}:policy/${PREFIX}-submit-job"

echo; echo "═══ Role policy attachments ═══"
import_if_needed aws_iam_role_policy_attachment.batch_service \
  "${PREFIX}-batch-service/arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
import_if_needed aws_iam_role_policy_attachment.ecs_instance_managed \
  "${PREFIX}-ecs-instance/arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
import_if_needed aws_iam_role_policy_attachment.ecs_instance_s3 \
  "${PREFIX}-ecs-instance/arn:aws:iam::${ACCOUNT}:policy/${PREFIX}-s3-access"
import_if_needed aws_iam_role_policy_attachment.spot_fleet \
  "${PREFIX}-spot-fleet/arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
import_if_needed aws_iam_role_policy_attachment.job_s3 \
  "${PREFIX}-job/arn:aws:iam::${ACCOUNT}:policy/${PREFIX}-s3-access"
import_if_needed aws_iam_role_policy_attachment.job_submit_job \
  "${PREFIX}-job/arn:aws:iam::${ACCOUNT}:policy/${PREFIX}-submit-job"
import_if_needed aws_iam_role_policy_attachment.execution_ecr_logs \
  "${PREFIX}-execution/arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
import_if_needed aws_iam_role_policy_attachment.events_submit_job \
  "${PREFIX}-events-to-batch/arn:aws:iam::${ACCOUNT}:policy/${PREFIX}-submit-job"

echo; echo "Imports done. Running terraform apply…"; echo
terraform apply -auto-approve
