#!/usr/bin/env bash
# One-command deploy: terraform apply → docker build → docker push.
#
# Discovers everything from `terraform output` and `aws sts` — no hardcoded
# account IDs, region, or names. Every resource is prefixed with the value
# of var.name_prefix in terraform.tfvars.
#
# Usage:
#   ./scripts/deploy.sh                     # everything
#   ./scripts/deploy.sh --skip-terraform    # only build + push image (fast iteration)
#   ./scripts/deploy.sh --skip-docker       # only apply infra (no image push)
#   TAG=v2 ./scripts/deploy.sh              # push image as :v2 instead of :latest

set -euo pipefail

SKIP_TF=0
SKIP_DOCKER=0
for arg in "$@"; do
  case "$arg" in
    --skip-terraform) SKIP_TF=1 ;;
    --skip-docker)    SKIP_DOCKER=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

TAG="${TAG:-latest}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

# ─ Sanity: AWS creds valid?
echo "→ Verifying AWS credentials"
if ! aws sts get-caller-identity --output text >/dev/null 2>&1; then
  echo "ERROR: AWS credentials not valid. Run: aws sso login --profile <your-profile>" >&2
  exit 1
fi
aws sts get-caller-identity --query 'Arn' --output text

# ─ Sanity: main.tf exists?
if [[ ! -f "$TF_DIR/main.tf" ]]; then
  echo "ERROR: $TF_DIR/main.tf not found." >&2
  exit 1
fi

# ─ 1. Terraform
if [[ "$SKIP_TF" == "0" ]]; then
  echo
  echo "═══ 1/2  terraform apply ═══"
  ( cd "$TF_DIR" && terraform init -input=false && terraform apply -auto-approve )
else
  echo "→ Skipping terraform (--skip-terraform)"
fi

# ─ Read outputs
ECR=$(terraform -chdir="$TF_DIR" output -raw ecr_repository_url)
BUCKET=$(terraform -chdir="$TF_DIR" output -raw s3_bucket)
QUEUE=$(terraform -chdir="$TF_DIR" output -raw job_queue)
REGION=$(terraform -chdir="$TF_DIR" output -raw region)
REGISTRY="${ECR%/*}"

# ─ 2. Docker build + push
if [[ "$SKIP_DOCKER" == "0" ]]; then
  echo
  echo "═══ 2/2  docker build + push ═══"
  echo "  Registry: $REGISTRY"
  echo "  Image:    $ECR:$TAG"

  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY"

  ( cd "$REPO_ROOT" && \
    docker build --platform linux/amd64 -t "$ECR:$TAG" . )

  docker push "$ECR:$TAG"
else
  echo "→ Skipping docker (--skip-docker)"
fi

# ─ Done. Print what to do next.
cat <<EOF

═════════════════════════════════════════════════════════
  DEPLOYED
═════════════════════════════════════════════════════════

  Bucket:  s3://$BUCKET/ingest/
  Queue:   $QUEUE
  Region:  $REGION

Smoke test — upload one small file, watch it flow through:
  aws s3 cp <path/to/small.pdf> s3://$BUCKET/ingest/smoke/
  ./scripts/pipe.sh watch

Full monitoring:
  ./scripts/pipe.sh              # one-shot status
  ./scripts/pipe.sh logs         # tail latest job's logs

Cost + timing after a few jobs land:
  uv run scripts/cost_report_aggregate.py --bucket $BUCKET

EOF
