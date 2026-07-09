#!/usr/bin/env bash
# Focused IAM cleanup — use when `terraform apply` errors with
# "EntityAlreadyExists" for roles/policies because previous state was wiped
# but AWS still has the resources.
#
# Loud — every action is logged, every failure exits non-zero.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

PREFIX="nuextract-batch"
if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
  P=$(grep -E '^[[:space:]]*name_prefix[[:space:]]*=' "$TF_DIR/terraform.tfvars" \
      | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' | head -1)
  [[ -n "$P" ]] && PREFIX="$P"
fi
REGION="${REGION:-us-east-1}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

ROLES=(
  "${PREFIX}-batch-service"
  "${PREFIX}-ecs-instance"
  "${PREFIX}-spot-fleet"
  "${PREFIX}-job"
  "${PREFIX}-execution"
  "${PREFIX}-events-to-batch"
)
POLICIES=(
  "${PREFIX}-s3-access"
  "${PREFIX}-submit-job"
  "${PREFIX}-execution-secrets"
)
INSTANCE_PROFILE="${PREFIX}-ecs-instance"

echo "Account: $ACCOUNT  Prefix: $PREFIX"

err() { echo "  ✗ $*" >&2; }
ok()  { echo "  ✓ $*"; }
say() { echo "→ $*"; }

for role in "${ROLES[@]}"; do
  echo; echo "═══ ROLE: $role ═══"
  if ! aws iam get-role --role-name "$role" --output text --query 'Role.Arn' 2>/dev/null; then
    say "not found, skipping"; continue
  fi
  say "detaching managed policies"
  for arn in $(aws iam list-attached-role-policies --role-name "$role" \
               --query 'AttachedPolicies[*].PolicyArn' --output text); do
    say "detach $arn"
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" \
      && ok "detached" || { err "detach failed"; exit 1; }
  done
  say "deleting inline policies"
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
    say "delete inline $p"
    aws iam delete-role-policy --role-name "$role" --policy-name "$p" \
      && ok "deleted" || { err "delete-role-policy failed"; exit 1; }
  done
  say "removing from any instance profile"
  for ip in $(aws iam list-instance-profiles-for-role --role-name "$role" \
              --query 'InstanceProfiles[*].InstanceProfileName' --output text); do
    say "remove from $ip"
    aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$role" \
      && ok "removed" || { err "remove-role-from-instance-profile failed"; exit 1; }
  done
  say "deleting role"
  if aws iam delete-role --role-name "$role"; then
    ok "deleted"
  else
    err "delete-role failed — dump state"
    aws iam list-attached-role-policies --role-name "$role" || true
    aws iam list-role-policies --role-name "$role" || true
    aws iam list-instance-profiles-for-role --role-name "$role" || true
    exit 1
  fi
done

echo; echo "═══ INSTANCE PROFILE: $INSTANCE_PROFILE ═══"
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
  aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE" \
    && ok "deleted" || { err "delete failed"; exit 1; }
else
  say "not found, skipping"
fi

for pol in "${POLICIES[@]}"; do
  echo; echo "═══ POLICY: $pol ═══"
  arn="arn:aws:iam::${ACCOUNT}:policy/${pol}"
  if ! aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    say "not found, skipping"; continue
  fi
  say "detaching from any remaining roles"
  for r in $(aws iam list-entities-for-policy --policy-arn "$arn" \
             --query 'PolicyRoles[*].RoleName' --output text); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$arn" \
      && ok "detached from $r" || { err "detach failed"; exit 1; }
  done
  say "deleting non-default versions"
  for v in $(aws iam list-policy-versions --policy-arn "$arn" \
             --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" \
      && ok "deleted v$v" || { err "delete-policy-version failed"; exit 1; }
  done
  say "deleting policy"
  aws iam delete-policy --policy-arn "$arn" \
    && ok "deleted" || { err "delete-policy failed"; exit 1; }
done

echo
echo "IAM artifacts cleaned. Next:"
echo "  cd $TF_DIR && terraform apply -auto-approve"
