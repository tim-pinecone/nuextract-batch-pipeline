"""PDF parser: renders pages and runs NuExtract3 OCR.

Per-page checkpointing: each rendered page's markdown is written to
`staging/{stem}/page_{N:05d}.md` (local scratch, optionally mirrored to S3).
A Spot reclaim mid-document resumes on the next unparsed page rather than from
page 1 — keeps the worker self-fan-out for big PDFs (>PDF_SPLIT_PAGES) cheap.
"""

from __future__ import annotations

import io
import os
import time
from typing import Iterator

from ._ocr_model import OCRModel

RENDER_DPI = int(os.getenv("RENDER_DPI", "150"))


def page_count(pdf_path: str) -> int:
    import fitz
    doc = fitz.open(pdf_path)
    try:
        return doc.page_count
    finally:
        doc.close()


def iter_pages(
    pdf_path: str,
    *,
    page_start: int = 1,        # 1-indexed inclusive
    page_end: int | None = None,  # 1-indexed inclusive; None = last page
    staging_dir: str | None = None,
) -> Iterator[dict]:
    """Yield {page, markdown, seconds} per page. Resumes from staging_dir if set."""
    import fitz
    from PIL import Image

    model = OCRModel.get()

    doc = fitz.open(pdf_path)
    try:
        end = doc.page_count if page_end is None else min(page_end, doc.page_count)
        if page_start < 1:
            page_start = 1
        mat = fitz.Matrix(RENDER_DPI / 72.0, RENDER_DPI / 72.0)
        for pno in range(page_start - 1, end):
            page_num = pno + 1
            staged = _staged_text(staging_dir, page_num) if staging_dir else None
            if staged is not None:
                yield {"page": page_num, "markdown": staged, "seconds": 0.0, "cached": True}
                continue
            t0 = time.time()
            pix = doc.load_page(pno).get_pixmap(matrix=mat)
            img = Image.open(io.BytesIO(pix.tobytes("png"))).convert("RGB")
            md = model.ocr_page(img)
            secs = time.time() - t0
            if staging_dir:
                _stage_text(staging_dir, page_num, md)
            yield {"page": page_num, "markdown": md, "seconds": secs, "cached": False}
    finally:
        doc.close()


def _staged_text(staging_dir: str, page: int) -> str | None:
    p = os.path.join(staging_dir, f"page_{page:05d}.md")
    if os.path.exists(p):
        with open(p) as f:
            return f.read()
    return None


def _stage_text(staging_dir: str, page: int, md: str) -> None:
    os.makedirs(staging_dir, exist_ok=True)
    p = os.path.join(staging_dir, f"page_{page:05d}.md")
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        f.write(md)
    os.replace(tmp, p)  # atomic: kill mid-write leaves no half file
