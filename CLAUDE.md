# nuextract-batch-pipeline

Event-driven OCR → chunk → embed pipeline on AWS Batch. Each S3 upload to
`ingest/` fires one Batch job that produces a Pinecone bulk-import parquet.

## Stack at a glance

- **Container**: single-venv Docker image on `nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04`.
- **Models**:
  - `numind/NuExtract3` — page → clean Markdown (GPU, ~9 GB VRAM in bf16)
  - `google/embeddinggemma-300m-qat-q8_0-unquantized` — 768-d embeddings (GPU or CPU)
- **Chunking**: Chonkie `RecursiveChunker(recipe="markdown", chunk_size=2048)`
- **Infra**: S3 (input + output) → EventBridge → AWS Batch (GPU Spot, g5.xlarge)
- **Output**: Pinecone bulk-import parquet (`id`, `values`, `metadata` struct)
- **Language**: Python 3.12 (uv for local dev)
- **IaC**: Terraform, single `main.tf`

## Repo layout

```
Dockerfile / entrypoint.sh    Container definition + one-arg entrypoint
process_doc.py                Worker: dispatch → parse → chunk → embed → parquet
doc_router.py                 Content-Type → parser dispatch
parsers/                      PDF, image (PNG/JPEG/TIFF), text/md, docx
chunker.py                    Chonkie RecursiveChunker wrapper
embedder.py                   SentenceTransformer(EmbeddingGemma) with doc prefix
bulk_writer.py                Pinecone bulk-import parquet writer
pdf_splitter.py               Big-PDF self-fan-out via batch.submit_job
cost_report.py                Per-job telemetry writer (S3)
io_common.py                  Local + S3 layer helpers, resumable run loop
terraform/main.tf             Everything AWS
terraform/terraform.tfvars.example  Documented config template
scripts/deploy.sh             One-command deploy (terraform apply + docker push)
scripts/destroy.sh            Full teardown (interactive DESTROY prompt)
scripts/build_push.sh         Docker build + ECR push only
scripts/pipe.sh               Observability (status | watch | logs | trace)
scripts/cost_report_aggregate.py  Rolls up reports/ into a $/page table
scripts/recover/              Emergency utilities (IAM nuke/import, queue unwedge)
```

## Common tasks

- **Deploy**: `./scripts/deploy.sh`
- **Full teardown**: `./scripts/destroy.sh` (prompts for `DESTROY` confirmation)
- **Push a code change**: `./scripts/build_push.sh` (skips terraform)
- **Watch a live upload**: `./scripts/pipe.sh watch`
- **Debug a specific job**: `./scripts/pipe.sh logs <jobId>` or `./scripts/pipe.sh trace <filename>`
- **When TF apply fails with `EntityAlreadyExists` for IAM**: `bash scripts/recover/import_iam.sh` (imports existing AWS resources into state)
- **When TF says `Cannot delete, existing JobQueue relationship`**: `bash scripts/recover/unwedge_batch.sh` (manually breaks the queue→CE link, resumes apply)

## Working principles (from ~/.claude/skills/tims-best-practices)

Any long-running work in this repo MUST be:
1. **Resumable** — checkpoint progress so a crash, kill, or Spot reclaim doesn't discard completed work. `process_doc.py` checkpoints per-page markdown to disk; parsers skip already-cached pages.
2. **Observable** — emit live, flushed progress (item X of N, percent, elapsed/ETA) so you can see how far along a loop is without guessing. `process_doc.py` prints `page i/N · chars · chunks · s/page · ETA` per page.

## Gotchas we've hit (so you don't re-learn them)

1. **`Ref::` parameter substitution works only in `command`, NOT in `environment`.** WORK_KEY has to ride through the container as `$1` from `command = ["Ref::work_key"]`, then get exported by entrypoint.sh. Don't set `WORK_KEY = Ref::...` in the job def's `environment` — it will pass through as a literal string.
2. **T4 (g4dn.xlarge, 16 GB VRAM) is not enough.** NuExtract3 in bf16 is ~13 GB steady, plus KV cache growth during multi-page generation → OOM. Use g5.xlarge (A10G, 24 GB) or larger. `variable "instance_types"` defaults to `["g5.xlarge", "g6.xlarge"]`.
3. **IAM read-after-delete eventual consistency (~60 s).** `destroy.sh` deletes IAM synchronously (200 OK) but AWS may still list the resource for up to a minute. `deploy.sh` waits for propagation before running `terraform apply`. Manual cleanup + immediate apply can hit `EntityAlreadyExists` — use `scripts/recover/import_iam.sh` if that happens.
4. **`terraform destroy` can't drop the compute env while the queue references it.** Disable the queue first, delete it, then delete the CE. `destroy.sh` handles this in the correct order.
5. **`sentence-transformers` is installed with `--no-deps`** to avoid pulling a newer `transformers` that would break NuExtract3's pinned `qwen3_5` commit. If ST ever fails to import, check its declared runtime deps — we may need to add one we missed.
6. **HF anonymous downloads 429 with >1 concurrent instance.** Set `hf_token_secret_arn` in `terraform.tfvars` for anything past a single-instance smoke test.
7. **EventBridge → Batch parameter substitution requires `PascalCase` at the top level** (`Parameters`, `ContainerOverrides`) but the SubmitJob API uses camelCase. EventBridge maps only the top-level keys. Use `parameters` + `Ref::work_key` in `command` for robust injection.
8. **The `flash-linear-attention` + `causal-conv1d` fast-path is off.** Our runtime base image lacks `nvcc`; wheels don't match cu124 exactly. The torch fallback works but is 5–10x slower on OCR generation. If we ever need the speedup, switch to a multi-stage build with a `-devel` base for compilation. See `Dockerfile` comments.

## Where to look first for outages

- **No jobs firing after S3 upload** → `./scripts/pipe.sh` shows EventBridge Invocations. If 0 → bucket notification not enabled (`aws_s3_bucket_notification.eventbridge = true` in main.tf). If FailedInvocations > 0 → IAM (`iam:PassRole` on the events-to-batch role).
- **All jobs FAILED with "Essential container in task exited"** → `./scripts/pipe.sh logs <jobId>` almost always shows a Python traceback in the first 20 lines. Common culprits: OOM, HF 403 (Gemma license not accepted), missing env var.
- **First job takes ~10 min end-to-end** → normal for a cold instance: EC2 provision (~2 min) + ECR image pull (~2 min) + HF model download (~2–3 min) + model load (~15 s). Subsequent jobs on the same instance hit the `/model-cache` host volume and skip the download.

## History

Extracted from `tim-pinecone/vietnam-wiki-national-archive` on 2026-07-08 —
the pipeline is generic (any of PDF / PNG / JPEG / TIFF / TXT / MD / DOCX),
so it's factored out into its own repo. The parent repo used it to embed
Vietnam War archive documents into Pinecone.
