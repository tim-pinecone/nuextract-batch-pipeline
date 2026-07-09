"""Chonkie RecursiveChunker(recipe="markdown") wrapper.

Splits a markdown string into a list of `{text, start, end, token_count}` dicts
ordered by appearance. `chunk_index` is added by the caller (it has to know
the global index across pages).
"""

from __future__ import annotations

import os

CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "2048"))


_chunker = None


def _get_chunker():
    global _chunker
    if _chunker is None:
        from chonkie import RecursiveChunker
        # recipe="markdown" loads markdown-aware split rules from HF Hub
        # (heading boundaries, fenced code blocks, list items). Default
        # "character" tokenizer means chunk_size is character-counted; cheap
        # and good enough for downstream EmbeddingGemma which truncates at
        # 2048 tokens (~8k chars) anyway.
        _chunker = RecursiveChunker(chunk_size=CHUNK_SIZE, recipe="markdown", lang="en")
    return _chunker


def chunk_markdown(md: str) -> list[dict]:
    """Return [{text, start, end, token_count}, ...] for the given markdown."""
    if not md.strip():
        return []
    chunker = _get_chunker()
    chunks = chunker(md)
    return [
        {
            "text": c.text,
            "start": getattr(c, "start_index", 0),
            "end": getattr(c, "end_index", len(c.text)),
            "token_count": getattr(c, "token_count", len(c.text)),
        }
        for c in chunks
    ]
