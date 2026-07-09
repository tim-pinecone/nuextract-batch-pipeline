"""Route an S3 object to the right parser based on Content-Type / extension.

Returns a tuple of (parser_module, parser_name). Each parser exposes:
  page_count(path) -> int
  iter_pages(path, *, page_start=1, page_end=None, staging_dir=None) -> Iterator[dict]

If the object's S3 Content-Type is set, we trust it. If not (uploads via
some tools omit it), we fall back to the file extension. Unknown types raise
UnknownContentType so the caller can write a *.skipped.json report.
"""

from __future__ import annotations

import os

from parsers import docx as docx_parser
from parsers import image as image_parser
from parsers import pdf as pdf_parser
from parsers import text as text_parser


class UnknownContentType(Exception):
    pass


_BY_TYPE = {
    "application/pdf": (pdf_parser, "pdf"),
    "image/png": (image_parser, "image"),
    "image/jpeg": (image_parser, "image"),
    "image/jpg": (image_parser, "image"),
    "image/tiff": (image_parser, "image"),
    "image/tif": (image_parser, "image"),
    "text/plain": (text_parser, "text"),
    "text/markdown": (text_parser, "text"),
    "text/x-markdown": (text_parser, "text"),
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": (docx_parser, "docx"),
}

_BY_EXT = {
    ".pdf": (pdf_parser, "pdf"),
    ".png": (image_parser, "image"),
    ".jpg": (image_parser, "image"),
    ".jpeg": (image_parser, "image"),
    ".tif": (image_parser, "image"),
    ".tiff": (image_parser, "image"),
    ".txt": (text_parser, "text"),
    ".md": (text_parser, "text"),
    ".markdown": (text_parser, "text"),
    ".docx": (docx_parser, "docx"),
}


def route(s3_key: str, content_type: str | None) -> tuple[object, str]:
    """Return (parser_module, parser_name). Trusts Content-Type, falls back to ext."""
    if content_type:
        ct = content_type.split(";", 1)[0].strip().lower()
        hit = _BY_TYPE.get(ct)
        if hit:
            return hit
    ext = os.path.splitext(s3_key)[1].lower()
    hit = _BY_EXT.get(ext)
    if hit:
        return hit
    raise UnknownContentType(
        f"no parser for content_type={content_type!r} ext={ext!r} key={s3_key!r}"
    )
