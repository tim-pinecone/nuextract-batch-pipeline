# OCR → chunk → embed worker for AWS Batch GPU-Spot.
#
# Single GPU box does the whole pipeline for one S3 input:
#   1. NuExtract3            (qwen3_5)   PDF/image page → markdown    (GPU)
#   2. Chonkie RecursiveChunker(recipe="markdown")                    (CPU)
#   3. EmbeddingGemma-300M   (768-d)     chunks → vectors             (GPU/CPU)
#   4. Pinecone bulk-import parquet → S3                              (CPU)
#
# NuExtract3 still needs the qwen3_5-capable transformers-from-source
# (`@98eea72`); sentence-transformers can live alongside that pin if we install
# it with --no-deps so it doesn't drag a newer transformers over the top. If
# that ever turns brittle, fall back to a second venv-embed (CPU torch + ST)
# and orchestrate via subprocess — io_common.py already supports that pattern.
#
# Build for linux/amd64 — GPU instances are x86_64 (Apple-silicon wheels fail
# silently at runtime):
#   docker build --platform linux/amd64 -t vietnam-ocr-embed pipeline/

FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

LABEL org.opencontainers.image.title="vietnam-ocr-embed" \
      org.opencontainers.image.description="NuExtract3 OCR + Chonkie + EmbeddingGemma worker"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/model-cache \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# uv binary from the official image (matches ocr-bakeoff conventions).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
RUN uv python install 3.12

WORKDIR /app

# Single venv. Order matters:
#   1) torch from the CUDA 12.4 index (must match the base image).
#   2) transformers pinned to the exact NuExtract3 commit before anything
#      else can drag a newer one in.
#   3) sentence-transformers --no-deps so it can't override #2.
#   4) sentence-transformers' real runtime deps individually (it really only
#      needs huggingface_hub + safetensors + tqdm + Pillow + scipy; the rest
#      are already provided by torch/transformers).
#   5) the remaining pipeline deps.
RUN uv venv /opt/venv --python 3.12 \
 && uv pip install --python /opt/venv/bin/python \
      --index-url https://download.pytorch.org/whl/cu124 torch torchvision \
 && uv pip install --python /opt/venv/bin/python \
      "transformers @ git+https://github.com/huggingface/transformers.git@98eea7240670acfe8fbb2a0a9a4ce9edb25cd7d9" \
      accelerate sentencepiece pillow huggingface_hub safetensors \
 && uv pip install --python /opt/venv/bin/python --no-deps \
      sentence-transformers \
 && uv pip install --python /opt/venv/bin/python \
      "chonkie>=1.6.7" pymupdf python-docx \
      boto3 pyarrow pandas numpy scipy

# Best-effort fast-attention kernels (silently fall back to torch impl if wheels
# don't build) — mirrors ocr-bakeoff.
RUN uv pip install --python /opt/venv/bin/python --no-deps \
      causal-conv1d flash-linear-attention \
 || echo "WARN: fast-attention kernels not installed; using torch fallback"

# Make /opt/venv the default Python.
ENV PATH="/opt/venv/bin:${PATH}"

# ── source ────────────────────────────────────────────────────────────────────
COPY io_common.py process_doc.py doc_router.py pdf_splitter.py \
     chunker.py embedder.py bulk_writer.py cost_report.py \
     entrypoint.sh /app/
COPY parsers /app/parsers
RUN chmod +x /app/entrypoint.sh

# Model weights are fetched at runtime into HF_HOME (/model-cache) on first use,
# not baked in — the host-volume /model-cache mount in the Batch job def means
# each instance downloads once across its lifetime, not per array task.
ENTRYPOINT ["/app/entrypoint.sh"]
