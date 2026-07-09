"""Pinecone bulk-import parquet writer.

Schema (per https://docs.pinecone.io/guides/index-data/import-data):
  id        STRING       - "{fileName}_{pageNumber}_{chunkNumber}"
  values    LIST<FLOAT>  - 768-d float32 from EmbeddingGemma
  metadata  STRUCT { ... } - merged per-record fields

We collect per-record rows in memory through one document/slab (chunks are
small; per-task records cap at a few thousand) and write one parquet to
S3 at the end. One parquet per Batch task.
"""

from __future__ import annotations

import io
import os


def write_parquet(
    *,
    records: list[dict],
    s3,
    bucket: str,
    key: str,
) -> int:
    """Records: list of {id, values, metadata}. Writes parquet to s3://bucket/key. Returns row count."""
    import pyarrow as pa
    import pyarrow.parquet as pq

    if not records:
        return 0

    # Infer metadata struct fields from the first record. All records must share keys —
    # the upstream record-builder is responsible for filling missing fields with sensible defaults.
    meta_keys = list(records[0]["metadata"].keys())
    arrays = {
        "id": pa.array([r["id"] for r in records], type=pa.string()),
        "values": pa.array(
            [list(r["values"]) for r in records],
            type=pa.list_(pa.float32()),
        ),
    }
    meta_arrays = {k: _meta_array(records, k) for k in meta_keys}
    metadata_struct = pa.StructArray.from_arrays(
        list(meta_arrays.values()), names=list(meta_arrays.keys())
    )
    table = pa.table({**arrays, "metadata": metadata_struct})

    buf = io.BytesIO()
    pq.write_table(table, buf, compression="snappy")
    buf.seek(0)
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=buf.getvalue(),
        ContentType="application/x-parquet",
    )
    return len(records)


def _meta_array(records: list[dict], key: str):
    import pyarrow as pa
    vals = [r["metadata"].get(key) for r in records]
    sample = next((v for v in vals if v is not None), None)
    if isinstance(sample, bool):
        return pa.array(vals, type=pa.bool_())
    if isinstance(sample, int):
        return pa.array(vals, type=pa.int64())
    if isinstance(sample, float):
        return pa.array(vals, type=pa.float64())
    # Default: string. Coerce numbers/Nones cleanly.
    return pa.array([None if v is None else str(v) for v in vals], type=pa.string())


def build_record(
    *,
    file_stem: str,
    page_number: int,
    chunk_index: int,
    text: str,
    values,
    s3_path: str,
    file_name: str,
    uploaded_at: str | None,
    ocr_model: str,
    embedding_model: str,
    chunker: str,
    token_count: int,
) -> dict:
    return {
        "id": f"{file_stem}_{page_number}_{chunk_index}",
        "values": values,
        "metadata": {
            "text": text,
            "s3_path": s3_path,
            "file_name": file_name,
            "uploaded_at": uploaded_at or "",
            "ocr_model": ocr_model,
            "embedding_model": embedding_model,
            "chunker": chunker,
            "page_number": page_number,
            "chunk_index": chunk_index,
            "token_count": token_count,
        },
    }
