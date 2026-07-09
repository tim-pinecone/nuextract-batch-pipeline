"""Worker-side PDF splitter: fans a big PDF out into child Batch jobs.

Mirrors the page-count heuristic from
https://github.com/aws-samples/amazon-textract-idp-cdk-constructs/blob/main/lambda/document_splitter/app/documentsplitter/documentsplitter.py
but executes inside the worker — keeps the S3 → EventBridge → Batch wiring
clean (no Lambda pre-step). The trigger job opens the PDF, counts pages, and
either:
  - submits N child jobs (one per page slab) and exits 0; or
  - returns False so the caller processes the PDF in-place.

Recursion guard: if PAGE_START/PAGE_END are already set in the env, splitting
is skipped (we're already inside a slab job).
"""

from __future__ import annotations

import os


PDF_SPLIT_PAGES = int(os.getenv("PDF_SPLIT_PAGES", "50"))


def maybe_fan_out(
    *,
    work_key: str,
    pdf_local_path: str,
    job_queue: str,
    job_definition: str,
    boto3_client,
) -> bool:
    """Return True if child jobs were submitted (caller should exit 0).
    Return False if the PDF is small enough to process in-place."""
    # If we're already in a slab job, never fan out again.
    if os.getenv("PAGE_START") or os.getenv("PAGE_END"):
        return False

    from parsers.pdf import page_count
    n_pages = page_count(pdf_local_path)
    if n_pages <= PDF_SPLIT_PAGES:
        return False

    slabs = _plan_slabs(n_pages, PDF_SPLIT_PAGES)
    print(f"[split] {work_key} has {n_pages} pages > {PDF_SPLIT_PAGES} "
          f"→ fanning out into {len(slabs)} slabs", flush=True)
    for start, end in slabs:
        job_name = _safe_job_name(work_key, start, end)
        # work_key rides through Batch parameters (substituted into the job
        # def's `command` via Ref::work_key). Page-range env vars go via
        # containerOverrides.environment because they're plain env vars —
        # Ref:: doesn't work there.
        boto3_client.submit_job(
            jobName=job_name,
            jobQueue=job_queue,
            jobDefinition=job_definition,
            parameters={"work_key": work_key},
            containerOverrides={
                "environment": [
                    {"name": "PAGE_START", "value": str(start)},
                    {"name": "PAGE_END", "value": str(end)},
                ],
            },
        )
    return True


def _plan_slabs(n_pages: int, cap: int) -> list[tuple[int, int]]:
    """Return [(start, end), ...] 1-indexed inclusive ranges covering 1..n_pages."""
    out = []
    start = 1
    while start <= n_pages:
        end = min(start + cap - 1, n_pages)
        out.append((start, end))
        start = end + 1
    return out


def _safe_job_name(work_key: str, start: int, end: int) -> str:
    """Batch job names must be [A-Za-z0-9_-], max 128 chars."""
    import re
    stem = re.sub(r"[^A-Za-z0-9_-]", "_", os.path.basename(work_key))[:80]
    return f"{stem}_p{start}-{end}"
