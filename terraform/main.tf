# Vietnam OCR → chunk → embed pipeline — AWS infrastructure.
#
# Single Terraform script. All inputs live in terraform.tfvars (see
# terraform.tfvars.example for the documented template). What this provisions:
#
#   • S3 bucket             {prefix}-{account}     (ingest/ → embeddings/, reports/)
#   • EventBridge rule      S3 PUT on ingest/ → SubmitJob to Batch (no Lambda)
#   • Batch compute env     GPU Spot, max 5 g4dn.xlarge instances
#   • Batch job def         single-container OCR + chunk + embed worker
#   • ECR repo              for the worker image
#   • IAM                   batch service, ECS instance, Spot fleet, job role,
#                           task execution role, EventBridge→Batch target role
#
# Apply:  terraform init && terraform apply
# Tear down compute only (preserves S3 + ECR): see README "Teardown".

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}

locals {
  # Every resource name (S3 bucket, ECR repo, Batch queue, IAM roles,
  # EventBridge rule) derives from var.name_prefix. Change the var in
  # terraform.tfvars to run parallel stacks in the same AWS account.
  name_prefix = var.name_prefix
  common_tags = {
    Project     = var.project
    Component   = "ocr-embed-pipeline"
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}

# ─── Variables ───────────────────────────────────────────────────────────────
variable "name_prefix" {
  description = <<-EOT
    Prefix for every resource this module creates. Lowercase letters, digits,
    and hyphens only (must be a valid S3 bucket name component + IAM role name).
    Change per environment to run parallel stacks in one AWS account.
  EOT
  type        = string
  default     = "nuextract-batch"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 chars, lowercase letters/digits/hyphens, and cannot start or end with a hyphen."
  }
}

variable "project" {
  description = "Value for the Project tag on every resource."
  type        = string
  default     = "nuextract-batch-pipeline"
}

variable "aws_region" {
  description = "AWS region. us-east-1 has the deepest g4dn/g5 Spot pools."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI/SSO profile. Empty = default credential chain."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment tag applied to all resources."
  type        = string
  default     = "dev"
}

variable "instance_types" {
  description = <<-EOT
    GPU Spot instance types. g5.xlarge (A10G 24 GB) is the primary — real
    measurement showed NuExtract3 in bf16 uses ~13 GB VRAM and needs ~4 GB
    more for KV cache during multi-page generation, which OOMs on T4 (16 GB).
    A10G at 24 GB gives comfortable headroom. Spot price is ~$0.30-0.40/hr
    vs. $0.16-0.20 on g4dn, still cheap.

    g6.xlarge (L4 24 GB) is a secondary pool for Spot capacity diversity.
    g4dn.xlarge (T4 16 GB) intentionally dropped — insufficient VRAM.
  EOT
  type        = list(string)
  default     = ["g5.xlarge", "g6.xlarge"]
}

variable "max_vcpus" {
  description = <<-EOT
    Compute-environment vCPU ceiling = parallelism cap. 4 vCPU per job →
    20 vCPUs ≈ 5 GPU workers in flight, matching the "no more than 5
    instances" cap. Raise carefully; Spot capacity in small GPU pools is finite.
  EOT
  type        = number
  default     = 20
}

variable "image_tag" {
  description = "ECR image tag the job definition runs."
  type        = string
  default     = "latest"
}

variable "root_volume_gb" {
  description = "Worker root EBS (GB). Holds the ~18GB pulled image + Docker overhead + scratch."
  type        = number
  default     = 100
}

variable "container_vcpu" {
  description = "vCPU reserved per job. g4dn/g5.xlarge have 4."
  type        = number
  default     = 4
}

variable "container_memory_mib" {
  description = "Memory reserved per job (MiB). g4dn/g5.xlarge have 16GB; leave headroom for the ECS agent."
  type        = number
  default     = 14000
}

variable "job_retries" {
  description = "Job attempts. Per-page checkpoints make resumption cheap on Spot reclaim."
  type        = number
  default     = 5
}

variable "pdf_split_pages" {
  description = "PDF page-count threshold for worker self-fan-out into child slab jobs."
  type        = number
  default     = 50
}

variable "chunk_size" {
  description = "Chonkie RecursiveChunker chunk_size (characters at default tokenizer)."
  type        = number
  default     = 2048
}

variable "embedding_model" {
  description = "Hugging Face model id for the embedder."
  type        = string
  default     = "google/embeddinggemma-300m-qat-q8_0-unquantized"
}

variable "max_pages_per_job" {
  description = <<-EOT
    Smoke-test knob. "" (default) = process the whole document. Set to "1"
    to stop after page 1 — fast end-to-end signal (upload → OCR → embed →
    parquet) in ~2 min instead of ~10 min for a 20-page doc.
  EOT
  type        = string
  default     = ""
}

variable "hf_token_secret_arn" {
  description = <<-EOT
    Optional Secrets Manager ARN holding the HF read token. Empty = anonymous
    HF access (will hit 429s on multi-instance cold starts). Pre-create with:
      aws secretsmanager create-secret --name vietnam-ocr-ner/hf-token \
        --secret-string "$HF_TOKEN"
    and paste the returned ARN here.
  EOT
  type        = string
  default     = ""
}

# ─── Network — default VPC + Batch egress SG ─────────────────────────────────
data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "batch" {
  name_prefix = "${local.name_prefix}-batch-"
  description = "Egress-only SG for Batch GPU workers (ECR, S3, HuggingFace)"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.common_tags

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

# ─── ECR — worker image ──────────────────────────────────────────────────────
resource "aws_ecr_repository" "runner" {
  name                 = "${local.name_prefix}-runner"
  image_tag_mutability = "MUTABLE"
  tags                 = local.common_tags
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "runner" {
  repository = aws_ecr_repository.runner.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["latest", "v"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ─── S3 — pipeline bucket ────────────────────────────────────────────────────
# Layout:
#   ingest/{user-supplied-path}/{file}    PUT here → EventBridge fires Batch
#   embeddings/{job_id}.parquet           per-job Pinecone bulk-import parquet
#   reports/{job_id}.json                 per-job cost + speed telemetry
#   staging/                              reserved for per-page checkpoints (worker writes to /tmp here today)
resource "aws_s3_bucket" "pipeline" {
  bucket = "${local.name_prefix}-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags

  # Outputs are expensive to regenerate — never let `terraform destroy` take them.
  # Teardown only compute: terraform destroy -target aws_batch_compute_environment.gpu_spot
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline" {
  bucket                  = aws_s3_bucket.pipeline.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Native S3 → EventBridge notification — no SQS, no Lambda.
resource "aws_s3_bucket_notification" "pipeline" {
  bucket      = aws_s3_bucket.pipeline.id
  eventbridge = true
}

# ─── IAM ─────────────────────────────────────────────────────────────────────
# Shared bucket access policy used by instance + job + execution roles.
data "aws_iam_policy_document" "s3_access" {
  statement {
    sid       = "BucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.pipeline.arn]
  }
  statement {
    sid       = "ObjectRW"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.pipeline.arn}/*"]
  }
}

resource "aws_iam_policy" "s3_access" {
  name   = "${local.name_prefix}-s3-access"
  policy = data.aws_iam_policy_document.s3_access.json
  tags   = local.common_tags
}

# Shared "submit a Batch job" policy — used by EventBridge target role
# (S3 → Batch) and the worker job role (PDF self-fan-out).
data "aws_iam_policy_document" "submit_job" {
  statement {
    actions = ["batch:SubmitJob"]
    resources = [
      aws_batch_job_queue.main.arn,
      # Wildcard over revisions — TF only knows the revision it last applied,
      # so the unversioned ARN would point at e.g. :1 even after a manual or
      # subsequent TF-driven update creates :2, :3, etc. The `:*` suffix
      # covers all revisions of this job def.
      "${replace(aws_batch_job_definition.worker.arn, "/:[0-9]+$/", "")}:*",
    ]
  }
  statement {
    actions   = ["batch:DescribeJobQueues", "batch:DescribeJobDefinitions"]
    resources = ["*"]
  }
  # When EventBridge (or the worker self-fan-out path) calls SubmitJob, Batch
  # internally needs to pass the job role + execution role to ECS. The caller
  # must have iam:PassRole on those roles, or Batch will accept the submission
  # but the job will never start.
  statement {
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.job.arn,
      aws_iam_role.execution.arn,
    ]
  }
}

resource "aws_iam_policy" "submit_job" {
  name   = "${local.name_prefix}-submit-job"
  policy = data.aws_iam_policy_document.submit_job.json
  tags   = local.common_tags
}

# ── 1. Batch service role ──
data "aws_iam_policy_document" "batch_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "batch_service" {
  name               = "${local.name_prefix}-batch-service"
  assume_role_policy = data.aws_iam_policy_document.batch_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  role       = aws_iam_role.batch_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# ── 2. ECS instance role + profile ──
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_instance" {
  name               = "${local.name_prefix}-ecs-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_instance_managed" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Instance-level S3 access too (belt-and-suspenders alongside the job role).
resource "aws_iam_role_policy_attachment" "ecs_instance_s3" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${local.name_prefix}-ecs-instance"
  role = aws_iam_role.ecs_instance.name
  tags = local.common_tags
}

# ── 3. Spot fleet role ──
data "aws_iam_policy_document" "spotfleet_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["spotfleet.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "spot_fleet" {
  name               = "${local.name_prefix}-spot-fleet"
  assume_role_policy = data.aws_iam_policy_document.spotfleet_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "spot_fleet" {
  role       = aws_iam_role.spot_fleet.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
}

# ── 4. Job role (container task identity) ──
data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "job" {
  name               = "${local.name_prefix}-job"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "job_s3" {
  role       = aws_iam_role.job.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# Worker self-fan-out for big PDFs.
resource "aws_iam_role_policy_attachment" "job_submit_job" {
  role       = aws_iam_role.job.name
  policy_arn = aws_iam_policy.submit_job.arn
}

# ── 5. Task execution role (ECR pull, CloudWatch logs, secrets injection) ──
resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "execution_ecr_logs" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# GetSecretValue only when the HF token is configured.
data "aws_iam_policy_document" "execution_secrets" {
  count = var.hf_token_secret_arn == "" ? 0 : 1
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.hf_token_secret_arn]
  }
}

resource "aws_iam_policy" "execution_secrets" {
  count  = var.hf_token_secret_arn == "" ? 0 : 1
  name   = "${local.name_prefix}-execution-secrets"
  policy = data.aws_iam_policy_document.execution_secrets[0].json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "execution_secrets" {
  count      = var.hf_token_secret_arn == "" ? 0 : 1
  role       = aws_iam_role.execution.name
  policy_arn = aws_iam_policy.execution_secrets[0].arn
}

# ── 6. EventBridge → Batch target role ──
data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_to_batch" {
  name               = "${local.name_prefix}-events-to-batch"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "events_submit_job" {
  role       = aws_iam_role.events_to_batch.name
  policy_arn = aws_iam_policy.submit_job.arn
}

# ─── Batch ───────────────────────────────────────────────────────────────────
# Launch template bumps the root volume so the ~18GB pulled image + Docker
# overhead + scratch all fit (ECS GPU AMI default is too small).
resource "aws_launch_template" "gpu" {
  name_prefix = "${local.name_prefix}-"
  tags        = local.common_tags

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${local.name_prefix}-worker" })
  }
}

resource "aws_batch_compute_environment" "gpu_spot" {
  compute_environment_name = "${local.name_prefix}-gpu-spot"
  type                     = "MANAGED"
  service_role             = aws_iam_role.batch_service.arn

  compute_resources {
    type                = "SPOT"
    allocation_strategy = "SPOT_CAPACITY_OPTIMIZED" # spread across pools, dodge reclaims
    bid_percentage      = 100                       # cap at on-demand; Spot still ~60-70% off
    min_vcpus           = 0                         # $0 idle
    max_vcpus           = var.max_vcpus
    instance_type       = var.instance_types
    instance_role       = aws_iam_instance_profile.ecs_instance.arn
    spot_iam_fleet_role = aws_iam_role.spot_fleet.arn
    subnets             = data.aws_subnets.default.ids
    security_group_ids  = [aws_security_group.batch.id]

    launch_template {
      launch_template_id = aws_launch_template.gpu.id
      version            = "$Latest"
    }

    # GPU-optimized ECS AMI: NVIDIA drivers + container runtime so
    # resourceRequirements GPU=1 actually binds the T4/A10G.
    ec2_configuration { image_type = "ECS_AL2_NVIDIA" }

    tags = local.common_tags
  }

  tags       = local.common_tags
  depends_on = [aws_iam_role_policy_attachment.batch_service]
}

resource "aws_batch_job_queue" "main" {
  name     = "${local.name_prefix}-queue"
  state    = "ENABLED"
  priority = 1

  # New block form — replaces the deprecated `compute_environments` list.
  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.gpu_spot.arn
  }

  tags = local.common_tags
}

# Per-document worker.
#
# Injection path: Batch's Ref:: parameter substitution is only supported in
# the `command` field (NOT in environment). So EventBridge sends
# `parameters = { work_key = <s3-key> }`; the container's command below is
# `["Ref::work_key"]` which becomes `["ingest/foo/bar.pdf"]` at launch.
# entrypoint.sh reads that as $1 and exports it as WORK_KEY for process_doc.py.
#
# PDF self-fan-out uses the same parameter + submits page ranges via
# containerOverrides.environment for PAGE_START/PAGE_END (env vars don't
# support Ref:: but ARE overridable at submit time).
resource "aws_batch_job_definition" "worker" {
  name                  = "${local.name_prefix}-worker"
  type                  = "container"
  platform_capabilities = ["EC2"]

  # Default so ad-hoc SubmitJob works without --parameters.
  parameters = {
    work_key = "unset"
  }

  container_properties = jsonencode({
    image            = "${aws_ecr_repository.runner.repository_url}:${var.image_tag}"
    jobRoleArn       = aws_iam_role.job.arn
    executionRoleArn = aws_iam_role.execution.arn
    # Passed to /app/entrypoint.sh as $1. Ref::work_key is substituted at
    # launch time from the `parameters` map above / from SubmitJob overrides.
    command = ["Ref::work_key"]
    resourceRequirements = [
      { type = "VCPU", value = tostring(var.container_vcpu) },
      { type = "MEMORY", value = tostring(var.container_memory_mib) },
      { type = "GPU", value = "1" },
    ]
    # Host-volume model cache: the ~9GB HF download (NuExtract3 +
    # EmbeddingGemma) happens once per EC2 instance lifetime, not per job.
    volumes = [{
      name = "model-cache"
      host = { sourcePath = "/var/lib/model-cache" }
    }]
    mountPoints = [{
      sourceVolume  = "model-cache"
      containerPath = "/model-cache"
      readOnly      = false
    }]
    environment = [
      # WORK_KEY is NOT set here — EventBridge injects it via Ref::work_key
      # substitution into the command (see `command` above).
      { name = "S3_BUCKET", value = aws_s3_bucket.pipeline.id },
      # Reduce CUDA memory fragmentation during multi-page generation on
      # tight-VRAM instances. Harmless on larger GPUs.
      { name = "PYTORCH_CUDA_ALLOC_CONF", value = "expandable_segments:True" },
      # Smoke-test knob. Set to a small int (e.g. "1") via
      # containerOverrides.environment to bail after N pages instead of
      # processing the whole document. Unset in production for full processing.
      { name = "MAX_PAGES", value = var.max_pages_per_job },
      { name = "INPUT_PREFIX", value = "ingest" },
      { name = "EMBED_PREFIX", value = "embeddings" },
      { name = "REPORTS_PREFIX", value = "reports" },
      { name = "STAGING_PREFIX", value = "staging" },
      { name = "PDF_SPLIT_PAGES", value = tostring(var.pdf_split_pages) },
      { name = "CHUNK_SIZE", value = tostring(var.chunk_size) },
      { name = "EMBEDDING_MODEL", value = var.embedding_model },
      { name = "BATCH_JOB_QUEUE", value = aws_batch_job_queue.main.name },
      { name = "BATCH_JOB_DEFINITION", value = "${local.name_prefix}-worker" },
    ]
    # Optional HF token; container falls back to anonymous if not set.
    secrets = var.hf_token_secret_arn == "" ? [] : [
      { name = "HF_TOKEN", valueFrom = var.hf_token_secret_arn },
    ]
  })

  retry_strategy {
    attempts = var.job_retries
    evaluate_on_exit {
      action           = "RETRY"
      on_status_reason = "Host EC2*" # Spot reclamation
    }
  }

  timeout { attempt_duration_seconds = 14400 } # 4h/attempt safety cap

  tags = local.common_tags
}

# ─── EventBridge — S3 PUT → SubmitJob ────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "s3_object_created" {
  name        = "${local.name_prefix}-ingest"
  description = "Fire a Batch job for each new object under s3://${aws_s3_bucket.pipeline.id}/ingest/"
  tags        = local.common_tags

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.pipeline.id] }
      object = { key = [{ prefix = "ingest/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "to_batch" {
  rule      = aws_cloudwatch_event_rule.s3_object_created.name
  target_id = "${local.name_prefix}-to-batch"
  arn       = aws_batch_job_queue.main.arn
  role_arn  = aws_iam_role.events_to_batch.arn

  batch_target {
    job_definition = aws_batch_job_definition.worker.arn
    job_name       = "${local.name_prefix}-ingest"
  }

  # Pass the S3 key as a Batch job PARAMETER. The job def's command is
  # `["Ref::work_key"]`, which Batch substitutes at launch. This is the
  # documented pattern for injecting event data into Batch jobs. Case at
  # the top level: EventBridge maps `Parameters: parameters` (PascalCase in
  # the template → camelCase in the SubmitJob call).
  # https://docs.aws.amazon.com/batch/latest/userguide/cwe-input-transformer.html
  input_transformer {
    input_paths = {
      key = "$.detail.object.key"
    }
    input_template = <<EOF
{
  "Parameters": {"work_key": <key>}
}
EOF
  }
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "ecr_repository_url" {
  description = "Push the worker image here."
  value       = aws_ecr_repository.runner.repository_url
}

output "s3_bucket" {
  description = "Pipeline bucket. Drop inputs under ingest/; outputs land in embeddings/ + reports/."
  value       = aws_s3_bucket.pipeline.id
}

output "ingest_prefix" {
  description = "S3 prefix to upload to. Each PUT triggers one Batch job."
  value       = "s3://${aws_s3_bucket.pipeline.id}/ingest/"
}

output "embeddings_prefix" {
  description = "Where per-task Pinecone bulk-import parquets are written."
  value       = "s3://${aws_s3_bucket.pipeline.id}/embeddings/"
}

output "reports_prefix" {
  description = "Per-job cost + speed telemetry JSON."
  value       = "s3://${aws_s3_bucket.pipeline.id}/reports/"
}

output "job_queue" {
  description = "Batch job queue name."
  value       = aws_batch_job_queue.main.name
}

output "job_definition" {
  description = "Batch job definition name."
  value       = aws_batch_job_definition.worker.name
}

output "eventbridge_rule" {
  description = "EventBridge rule firing on new S3 uploads."
  value       = aws_cloudwatch_event_rule.s3_object_created.name
}

output "region" {
  value = var.aws_region
}
