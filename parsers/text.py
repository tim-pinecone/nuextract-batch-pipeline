"""Plain-text and Markdown passthrough.

UTF-8 first; falls back to latin-1 (archive scans sometimes ship cp1252-ish).
Single "page" (page=0 downstream).
"""

from __future__ import annotations

from typing import Iterator


def page_count(_path: str) -> int:
    return 1


def iter_pages(
    path: str,
    *,
    page_start: int = 1,
    page_end: int | None = None,
    staging_dir: str | None = None,
) -> Iterator[dict]:
    del page_start, page_end, staging_dir  # single-page, no checkpoint needed
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
    except UnicodeDecodeError:
        with open(path, encoding="latin-1") as f:
            content = f.read()
    yield {"page": 0, "markdown": content, "seconds": 0.0, "cached": False}
