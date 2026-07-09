"""EmbeddingGemma-300M loader + batched encoder.

Loaded lazily so the cost is paid only when there's at least one chunk to
embed. Uses sentence-transformers — the QAT-q8_0-unquantized variant ships
torch fp32 weights derived from QAT training, runs natively on ST. Designed
for resource-constrained inference; activations are not fp16-safe — we use
fp32 on CPU and bf16 on CUDA.

EmbeddingGemma expects a task-specific prefix on each input. For corpus
documents (what we're storing), Google's card prescribes:
    "title: {title | 'none'} | text: {chunk text}"
We don't have per-chunk titles, so use 'none'. Search queries (downstream,
not in this pipeline) would use a different prefix:
    "task: search result | query: {q}"
"""

from __future__ import annotations

import os

EMBEDDING_MODEL = os.getenv(
    "EMBEDDING_MODEL",
    "google/embeddinggemma-300m-qat-q8_0-unquantized",
)
EMBED_BATCH_SIZE = int(os.getenv("EMBED_BATCH_SIZE", "32"))
EMBED_DIM = 768


class Embedder:
    _instance: "Embedder | None" = None

    @classmethod
    def get(cls) -> "Embedder":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def __init__(self):
        import torch
        from sentence_transformers import SentenceTransformer

        if torch.cuda.is_available():
            device, dtype = "cuda", torch.bfloat16
        elif torch.backends.mps.is_available():
            device, dtype = "mps", torch.float32  # MPS bf16 patchy
        else:
            device, dtype = "cpu", torch.float32
        print(f"[load] {EMBEDDING_MODEL} on {device} ({dtype})", flush=True)
        self.model = SentenceTransformer(
            EMBEDDING_MODEL,
            device=device,
            model_kwargs={"torch_dtype": dtype},
        )

    def encode(self, texts: list[str]) -> "numpy.ndarray":
        """Return float32 (N, 768) numpy array. EmbeddingGemma doc-prefix applied."""
        import numpy as np

        if not texts:
            return np.zeros((0, EMBED_DIM), dtype="float32")
        prefixed = [f"title: none | text: {t}" for t in texts]
        vecs = self.model.encode(
            prefixed,
            batch_size=EMBED_BATCH_SIZE,
            convert_to_numpy=True,
            normalize_embeddings=False,
            show_progress_bar=False,
        )
        return vecs.astype("float32", copy=False)
