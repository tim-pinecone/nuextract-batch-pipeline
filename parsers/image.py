"""Single-image (PNG/JPEG) and multi-frame TIFF parser.

PNG/JPEG: one "page".
TIFF: PIL's n_frames enumerates frames; each frame becomes a page.
"""

from __future__ import annotations

import os
import time
from typing import Iterator

from ._ocr_model import OCRModel


def page_count(image_path: str) -> int:
    from PIL import Image
    with Image.open(image_path) as im:
        return getattr(im, "n_frames", 1)


def iter_pages(
    image_path: str,
    *,
    page_start: int = 1,
    page_end: int | None = None,
    staging_dir: str | None = None,
) -> Iterator[dict]:
    from PIL import Image

    model = OCRModel.get()
    with Image.open(image_path) as im:
        n = getattr(im, "n_frames", 1)
        end = n if page_end is None else min(page_end, n)
        for frame in range(page_start - 1, end):
            page_num = frame + 1
            staged = _staged_text(staging_dir, page_num) if staging_dir else None
            if staged is not None:
                yield {"page": page_num, "markdown": staged, "seconds": 0.0, "cached": True}
                continue
            try:
                im.seek(frame)
            except EOFError:
                break
            img = im.convert("RGB")
            t0 = time.time()
            md = model.ocr_page(img)
            secs = time.time() - t0
            if staging_dir:
                _stage_text(staging_dir, page_num, md)
            yield {"page": page_num, "markdown": md, "seconds": secs, "cached": False}


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
    os.replace(tmp, p)
