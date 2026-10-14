# nuextract-batch-pipeline

Event-driven document ingestion for Pinecone. Drop a PDF, image, `.txt`, `.md`,
or `.docx` into an S3 prefix; a GPU worker OCRs it with NuExtract3, chunks the
markdown with Chonkie, embeds each chunk with EmbeddingGemma-300M, and writes a
Pinecone bulk-import parquet to S3. All auto-triggered — no scheduled polling,
no submit script. Runs on AWS Batch GPU Spot, scales to zero when idle.

```
             │
   S3 PUT    │  s3://<bucket>/ingest/anything.pdf
             ▼
      ┌─────────────┐   Object Created (native → EventBridge)
      │ EventBridge │───────────────────┐
      └─────────────┘                    │  parameters.work_key = <key>
                                         ▼
                           ┌──────────────────────────────┐
                           │  AWS Batch  (g5.xlarge Spot) │
                           │  ┌────────────────────────┐  │
                           │  │ 1. NuExtract3 OCR      │  │
                           │  │ 2. Chonkie chunk       │  │
                           │  │ 3. EmbeddingGemma embed│  │
                           │  │ 4. parquet + report    │  │
                           │  └────────────────────────┘  │
                           └───────────┬──────────────────┘
                                       ▼
                s3://<bucket>/embeddings/<job_id>.parquet
                s3://<bucket>/reports/<job_id>.json
```

## What it produces

Per Batch job, one Parquet in the [Pinecone bulk-import schema](https://docs.pinecone.io/guides/index-data/import-data):

```
id        STRING       = "{fileName}_{pageNumber}_{chunkIndex}"
values    LIST<FLOAT>  = 768-d float32 from EmbeddingGemma
metadata  STRUCT {
  text:              STRING
  s3_path:           STRING
  file_name:         STRING
  uploaded_at:       STRING     (ISO-8601)
  ocr_model:         STRING
  embedding_model:   STRING
  chunker:           STRING
  page_number:       INT        (0 for non-paginated inputs)
  chunk_index:       INT
  token_count:       INT
}
```

Plus a per-job JSON in `reports/` with the wall-time of each stage
(`ocr`, `chunk`, `embed`, `total`), the instance type, and page/chunk counts.
An aggregator script (`scripts/cost_report_aggregate.py`) rolls that up into
a $/page table.

## Supported inputs

| Content-Type | Extension | Parser |
|---|---|---|
| `application/pdf` | `.pdf` | pymupdf → NuExtract3 |
| `image/png`, `image/jpeg` | `.png`, `.jpg`, `.jpeg` | PIL → NuExtract3 |
| `image/tiff` | `.tif`, `.tiff` | PIL multi-frame → NuExtract3 |
| `text/plain` | `.txt` | passthrough |
| `text/markdown` | `.md` | passthrough |
| `application/vnd.openxmlformats-officedocument.wordprocessingml.document` | `.docx` | python-docx → markdown |

Unknown types are written to `reports/*.skipped.json` and the job exits clean.

## Prerequisites

- **AWS**: an account you can `aws sso login` into with permission to create
  IAM, ECR, S3, Batch, and EventBridge resources.
- **Tools**: `terraform >= 1.6`, `docker`, `aws` CLI, `python 3.12` + `uv`
  (for the local aggregator scripts).
- **Hugging Face**:
  - A read token from https://huggingface.co/settings/tokens (strongly
    recommended — avoids anonymous rate limits across parallel instances).
  - Accepted [Gemma license](https://huggingface.co/google/embeddinggemma-300m)
    on the HF account that owns the token.

## Deploy

Copy the tfvars template, fill in what you need:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit — the important knobs are aws_region, name_prefix, and hf_token_secret_arn.
```

If you want the HF token pre-provisioned (recommended):

```bash
aws secretsmanager create-secret \
  --name <name_prefix>/hf-token \
  --secret-string "$HF_TOKEN"
# Paste the returned ARN into terraform.tfvars as hf_token_secret_arn.
```

Then one command:

```bash
./scripts/deploy.sh
```

This runs `terraform init && terraform apply`, then builds the linux/amd64
Docker image and pushes it to the new ECR repo. Total time on a cold machine:
~15 min (image build dominates; subsequent deploys are much faster thanks to
Docker layer cache).

## Use

Just upload:

```bash
BUCKET=$(terraform -chdir=terraform output -raw s3_bucket)
aws s3 cp some_document.pdf s3://$BUCKET/ingest/
```

Watch it flow through:

```bash
./scripts/pipe.sh watch
```

You'll see the file appear in `ingest/`, EventBridge fire, a Batch job go
RUNNABLE → STARTING → RUNNING, and eventually a parquet + report land in
`embeddings/` and `reports/`.

Grab per-job logs:

```bash
./scripts/pipe.sh logs                   # latest RUNNING (else latest job)
./scripts/pipe.sh logs <jobId>           # specific job
./scripts/pipe.sh trace some_document.pdf   # full lifecycle of one file
```

## Configuration knobs

All in `terraform/terraform.tfvars`:

| Var | Default | What it does |
|---|---|---|
| `name_prefix` | `nuextract-batch` | Prefix for every AWS resource. Change to run parallel stacks in one account. |
| `aws_region` | `us-east-1` | Deepest g5/g6 Spot pools. |
| `instance_types` | `["g5.xlarge", "g6.xlarge"]` | A10G / L4 24 GB. **Don't drop to g4dn** — T4 (16 GB) OOMs on NuExtract3. |
| `max_vcpus` | `20` | 5 × 4 vCPU = 5 concurrent jobs max. |
| `pdf_split_pages` | `50` | PDFs over this count fan out into N-page slab jobs. |
| `chunk_size` | `2048` | Chonkie RecursiveChunker chunk size (characters). |
| `embedding_model` | `google/embeddinggemma-300m-qat-q8_0-unquantized` | 768-d embeddings. |
| `hf_token_secret_arn` | `""` | Secrets Manager ARN with your HF read token. Empty = anonymous (will 429 at scale). |
| `max_pages_per_job` | `""` | Set to `"1"` for fast end-to-end smoke tests. |
| `job_retries` | `5` | Retry attempts. Only `Host EC2*` (Spot reclaim) triggers retry. |

## Cost — order-of-magnitude

- **g5.xlarge Spot** in us-east-1: ~$0.30–0.40/hr.
- **Idle**: `$0` — `min_vcpus = 0` scales the fleet to zero when the queue drains.
- **Per page**: with the current fallback attention kernels and NuExtract3
  at ~10–15 s/page on A10G, ~$0.001–0.002 / page. Actual numbers land in
  `reports/`; run `scripts/cost_report_aggregate.py` after a few jobs.
- **Cold start**: ~10 min for the first job on a fresh instance (EC2 boot +
  ECR pull + HF download + model load). Subsequent jobs on the same instance
  reuse the `/model-cache` host volume and start in ~15 s.

## Troubleshooting

Failure modes we've hit and how to recognize them:

- **Job goes RUNNABLE → STARTING → FAILED with `Essential container in task
  exited`**. Container crashed. `./scripts/pipe.sh logs <jobId>` shows the
  Python traceback.
- **`torch.OutOfMemoryError` in the logs.** Instance too small. Confirm
  `instance_types` includes only `g5.xlarge` / `g6.xlarge` — g4dn.xlarge (T4)
  can't hold NuExtract3 + generation KV cache.
- **EventBridge fires but no job appears.** IAM. Check the
  `<name_prefix>-events-to-batch` role has `iam:PassRole` on the job + execution roles.
  This should be in `main.tf`; verify no manual edits drifted.
- **`WORK_KEY=Ref::work_key` in the log line (literal).** The
  `parameters` + `Ref::` wiring in the job def's `command` isn't hooked up.
  Confirm the job def has `parameters = { work_key = "..." }` and
  `command = ["Ref::work_key"]`, and the EventBridge input template writes
  `{"Parameters": {"work_key": <key>}}`.
- **`terraform apply` fails with `EntityAlreadyExists`.** IAM eventual
  consistency + wiped state. Run `bash scripts/recover/import_iam.sh` to
  import the leftover resources.
- **`terraform destroy` errors with `Cannot delete, existing JobQueue
  relationship`.** Queue → CE dependency out of order. Run
  `bash scripts/recover/unwedge_batch.sh`.

## Teardown

```bash
./scripts/destroy.sh
```

Interactive `DESTROY` prompt. Terminates in-flight jobs, drains the queue,
deletes CE + job defs + EventBridge rule + IAM + ECR + S3 bucket, then wipes
local Terraform state. Idempotent — safe to re-run after partial failure.

## Attribution

Extracted from an internal Vietnam War archive project
on 2026-07-08 so the pipeline can serve other document sources.
