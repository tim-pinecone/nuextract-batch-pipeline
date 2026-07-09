#!/usr/bin/env bash
# Build the worker container and push to ECR.
#
# Reads ECR URL from `terraform output` — no hardcoded account/region.
# Builds for linux/amd64 (GPU instances are x86_64; Apple-silicon wheels
# fail silently at runtime).
#
# Usage:
#   ./scripts/build_push.sh
#   TAG=v2 ./scripts/build_push.sh        # override the image tag (default: latest)

set -euo pipefail

TAG="${TAG:-latest}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

if [[ ! -f "$TF_DIR/main.tf" ]]; then
  echo "ERROR: $TF_DIR/main.tf not found." >&2
  exit 1
fi

# Verify creds — fail fast with a clear message rather than a cryptic empty-password error at docker login.
echo "→ Verifying AWS credentials"
if ! aws sts get-caller-identity --output text >/dev/null 2>&1; then
  echo "ERROR: AWS credentials not valid. Run: aws sso login --profile <your-profile>" >&2
  exit 1
fi
aws sts get-caller-identity --query 'Arn' --output text

ECR=$(terraform -chdir="$TF_DIR" output -raw ecr_repository_url)
REGION=$(terraform -chdir="$TF_DIR" output -raw region)
REGISTRY="${ECR%/*}"

echo
echo "  ECR:      $ECR"
echo "  Tag:      $TAG"
echo "  Region:   $REGION"
echo "  Context:  $REPO_ROOT"
echo

echo "→ Logging in to ECR"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "→ Building (linux/amd64, ~10–15 min first time)"
docker build --platform linux/amd64 -t "$ECR:$TAG" "$REPO_ROOT"

echo "→ Pushing"
docker push "$ECR:$TAG"

echo
echo "✓ Pushed $ECR:$TAG"
