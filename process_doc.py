"""Worker entry: process one S3 input → Pinecone bulk-import parquet.

Invoked by EventBridge → Batch with WORK_KEY in the env (the S3 key of the
new file). For large PDFs (page_count > PDF_SPLIT_PAGES), self-fans-out into
child slab jobs and exits 0 — child jobs come back through here with
PAGE_START/PAGE_END set.

Env contract (set by the Batch job def + EventBridge input transformer):
  WORK_KEY            full S3 key, e.g. "ingest/2026-06/foo.pdf"
  S3_BUCKET           the pipeline bucket
  EMBED_PREFIX        e.g. "embeddings"
  REPORTS_PREFIX      e.g. "reports"
  STAGING_PREFIX      e.g. "staging"  (per-page checkpoints during OCR)
  PDF_SPLIT_PAGES     int, default 50
  CHUNK_SIZE          int, default 2048 (forwarded to chunker.py)
  EMBEDDING_MODEL     HF model id, default google/embeddinggemma-300m-qat-q8_0-unquantized
  BATCH_JOB_QUEUE     queue name (for self-fan-out)
  BATCH_JOB_DEFINITION job def name (for self-fan-out)
  PAGE_START / PAGE_END  optional 1-indexed inclusive page slab (recursion guard)

Resumable & observable per ~/.claude/skills/tims-best-practices:
  - per-page markdown is checkpointed to local /tmp/staging/{stem}/page_NNNNN.md
    (a Spot reclaim mid-doc resumes on the next page, not page 1)
  - one-line progress per page: `page i/N · chars · s/page · ETA`
"""

from __future__ import annotations

import os
import sys
import time
import uuid

import io_common as iox
from chunker import chunk_markdown
from cost_report import make_timer, mark, stage_seconds, write_report
from doc_router import UnknownContentType, route
from embedder import Embedder
from bulk_writer import build_record, write_parquet
from pdf_splitter import maybe_fan_out


def _env(name: str, default: str | None = None, *, required: bool = False) -> str:
    val = os.getenv(name, default)
    if required and val is None:
        raise SystemExit(f"missing required env: {name}")
    return val or ""


def main() -> int:
    work_key = _env("WORK_KEY", required=True)
    bucket = _env("S3_BUCKET", required=True)
    embed_prefix = _env("EMBED_PREFIX", "embeddings").rstrip("/")
    reports_prefix = _env("REPORTS_PREFIX", "reports").rstrip("/")
    staging_prefix = _env("STAGING_PREFIX", "staging").rstrip("/")
    job_queue = _env("BATCH_JOB_QUEUE", required=False)
    job_def = _env("BATCH_JOB_DEFINITION", required=False)
    page_start_env = os.getenv("PAGE_START")
    page_end_env = os.getenv("PAGE_END")
    job_id = os.getenv("AWS_BATCH_JOB_ID", f"local-{uuid.uuid4().hex[:8]}")

    timer = make_timer()
    mark(timer, "_load_start")

    s3 = iox.s3_client()

    # 1. head_object → content type + LastModified.
    head = s3.head_object(Bucket=bucket, Key=work_key)
    content_type = head.get("ContentType")
    uploaded_at = head["LastModified"].isoformat() if head.get("LastModified") else None

    try:
        parser, parser_name = route(work_key, content_type)
    except UnknownContentType as exc:
        print(f"[skip] {exc}", flush=True)
        s3.put_object(
            Bucket=bucket,
            Key=f"{reports_prefix}/{job_id}.skipped.json",
            Body=_json({"work_key": work_key, "reason": str(exc), "job_id": job_id}).encode(),
            ContentType="application/json",
        )
        return 0

    file_name = os.path.basename(work_key)
    file_stem = os.path.splitext(file_name)[0]
    label = f"{file_stem}[{parser_name}]"
    if page_start_env or page_end_env:
        label += f" pages {page_start_env or '1'}-{page_end_env or '?'}"
    print(f"[start] {label} key={work_key}", flush=True)

    # 2. Download to scratch.
    scratch = "/tmp"
    local_path = os.path.join(scratch, file_name)
    s3.download_file(bucket, work_key, local_path)
    mark(timer, "_download_end")
    stage_seconds(timer, "_download_end", since="_load_start")

    # 3. For PDFs only: maybe self-fan-out.
    if parser_name == "pdf" and job_queue and job_def:
        try:
            import boto3
            batch = boto3.client("batch")
            if maybe_fan_out(
                work_key=work_key,
                pdf_local_path=local_path,
                job_queue=job_queue,
                job_definition=job_def,
                boto3_client=batch,
            ):
                # Children submitted; record a slim report and exit.
                mark(timer, "_fan_end")
                write_report(
                    s3=s3, bucket=bucket,
                    key=f"{reports_prefix}/{job_id}.fanout.json",
                    timer=timer,
                    payload={
                        "job_id": job_id,
                        "work_key": work_key,
                        "parser": parser_name,
                        "fanned_out": True,
                    },
                )
                print(f"[done] {label} fanned out, exiting", flush=True)
                return 0
        except Exception as exc:
            # Fall back to in-place processing if fan-out fails; better than
            # dropping the doc.
            print(f"[warn] fan-out failed ({exc!r}); processing in-place", flush=True)

    # 4. Iterate pages (parser handles its own caching).
    staging_dir = os.path.join(scratch, "staging", file_stem)
    page_start = int(page_start_env) if page_start_env else 1
    page_end = int(page_end_env) if page_end_env else None

    n_total = parser.page_count(local_path)
    eff_end = n_total if page_end is None else min(page_end, n_total)
    # MAX_PAGES lets a smoke test bail after N pages instead of the whole doc —
    # end-to-end signal (S3 → EventBridge → Batch → OCR → embed → parquet) in
    # a fraction of the wall time. Unset = process the whole slab.
    max_pages_env = os.getenv("MAX_PAGES")
    if max_pages_env:
        try:
            cap = int(max_pages_env)
            if cap > 0:
                eff_end = min(eff_end, page_start + cap - 1)
                print(f"[smoke] MAX_PAGES={cap} — will stop after page {eff_end}", flush=True)
        except ValueError:
            print(f"[warn] ignoring invalid MAX_PAGES={max_pages_env!r}", flush=True)
    eff_total = max(0, eff_end - page_start + 1)
    mark(timer, "_ocr_start")

    # Embedder + Chonkie are heavyweight; lazy-load on first chunk.
    embedder = None
    records: list[dict] = []
    n_chunks = 0
    chunker_label = f"chonkie.RecursiveChunker(recipe=markdown, chunk_size={os.getenv('CHUNK_SIZE','2048')})"
    embedding_model = os.getenv("EMBEDDING_MODEL", "google/embeddinggemma-300m-qat-q8_0-unquantized")
    ocr_model = os.getenv("NUEXTRACT_MODEL", "numind/NuExtract3")

    t_loop = time.time()
    for i, page in enumerate(parser.iter_pages(
        local_path,
        page_start=page_start,
        page_end=page_end,
        staging_dir=staging_dir,
    ), 1):
        page_num = page["page"]
        md = page["markdown"]
        chunks = chunk_markdown(md)
        if chunks:
            if embedder is None:
                embedder = Embedder.get()
            vecs = embedder.encode([c["text"] for c in chunks])
            for ci, (c, v) in enumerate(zip(chunks, vecs)):
                records.append(build_record(
                    file_stem=file_stem,
                    page_number=page_num,
                    chunk_index=ci,
                    text=c["text"],
                    values=v,
                    s3_path=f"s3://{bucket}/{work_key}",
                    file_name=file_name,
                    uploaded_at=uploaded_at,
                    ocr_model=ocr_model if parser_name in ("pdf", "image") else "n/a",
                    embedding_model=embedding_model,
                    chunker=chunker_label,
                    token_count=c["token_count"],
                ))
            n_chunks += len(chunks)
        elapsed = time.time() - t_loop
        avg = elapsed / max(1, i)
        eta = avg * max(0, eff_total - i)
        cached = " (cached)" if page.get("cached") else ""
        print(
            f"  page {page_num} ({i}/{eff_total}){cached} · "
            f"{len(md)} chars · {len(chunks)} chunks · "
            f"{page['seconds']:.1f}s/page · ETA {eta/60:.1f}m",
            flush=True,
        )

    mark(timer, "_ocr_end")
    stage_seconds(timer, "_ocr_end", since="_ocr_start")

    # 5. Write per-task parquet (Pinecone bulk-import schema).
    mark(timer, "_write_start")
    job_tag = job_id
    if page_start_env or page_end_env:
        job_tag = f"{job_id}_p{page_start_env or 1}-{page_end_env or eff_end}"
    parquet_key = f"{embed_prefix}/{job_tag}.parquet"
    n_rows = write_parquet(records=records, s3=s3, bucket=bucket, key=parquet_key)
    mark(timer, "_write_end")
    stage_seconds(timer, "_write_end", since="_write_start")

    # 6. Cost+speed report.
    write_report(
        s3=s3, bucket=bucket,
        key=f"{reports_prefix}/{job_id}.json",
        timer=timer,
        payload={
            "job_id": job_id,
            "work_key": work_key,
            "parser": parser_name,
            "page_start": page_start,
            "page_end": eff_end,
            "n_pages": eff_total,
            "n_chunks": n_chunks,
            "n_rows": n_rows,
            "parquet_key": parquet_key,
            "ocr_model": ocr_model if parser_name in ("pdf", "image") else None,
            "embedding_model": embedding_model,
            "chunker": chunker_label,
        },
    )

    print(
        f"[done] {label}: {eff_total} pages → {n_chunks} chunks → "
        f"{n_rows} rows → s3://{bucket}/{parquet_key}",
        flush=True,
    )
    # Best-effort: nuke per-page staging once parquet is durably written.
    try:
        import shutil
        shutil.rmtree(staging_dir, ignore_errors=True)
        os.remove(local_path)
    except OSError:
        pass
    return 0


def _json(obj: dict) -> str:
    import json
    return json.dumps(obj, default=str)


if __name__ == "__main__":
    raise SystemExit(main())
