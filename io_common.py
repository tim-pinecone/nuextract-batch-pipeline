"""Shared I/O for the two-stage OCR+NER pipeline.

Pure stdlib + boto3 — NO ML deps — so it imports cleanly in *both* container
venvs (venv-ocr with transformers-from-source, venv-ner with transformers<5.2).
NuExtract3 (qwen3_5) and GLiNER pin incompatible transformers versions, so the
two model stages can't share one interpreter; they share this module instead.

A `Layer` is a keyed blob store — a local directory or an S3 prefix — exposing
the same list/exists/read/write surface. Each stage wires an input layer to an
output layer and hands `run_stage` a per-doc function. `run_stage` owns the two
non-negotiables (see ~/.claude/skills/tims-best-practices):

  - resumable:  an existing output blob is that doc's checkpoint -> skipped.
  - observable: a flushed `i/N · stem · detail · s/doc · ETA` line per doc.
"""

from __future__ import annotations

import json
import os
import sys
import time


def env_shard() -> tuple[int, int]:
    """(index, count) for this worker. AWS Batch sets ARRAY index; SHARD_* for
    local multi-process testing. count<=1 means 'this worker does everything'."""
    idx = int(os.getenv("AWS_BATCH_JOB_ARRAY_INDEX", os.getenv("SHARD_INDEX", "0")))
    count = int(os.getenv("AWS_BATCH_JOB_ARRAY_SIZE", os.getenv("SHARD_COUNT", "1")))
    return idx, max(1, count)


def shard(items: list, idx: int, count: int) -> list:
    """Deterministic stride-shard: worker `idx` of `count` takes every count-th
    item. Same input set -> same partition on every worker and every retry."""
    return items[idx::count] if count > 1 else list(items)


def _stem(key: str) -> str:
    return os.path.splitext(os.path.basename(key))[0]


# ── layers ───────────────────────────────────────────────────────────────────


class LocalLayer:
    """Keyed blobs in a local directory."""

    def __init__(self, root: str):
        self.root = root
        os.makedirs(root, exist_ok=True)

    def _path(self, stem: str, ext: str) -> str:
        return os.path.join(self.root, f"{stem}{ext}")

    def list_stems(self, ext: str) -> list[str]:
        import glob
        return sorted(_stem(p) for p in glob.glob(os.path.join(self.root, f"*{ext}")))

    def exists(self, stem: str, ext: str) -> bool:
        return os.path.exists(self._path(stem, ext))

    def local_path(self, stem: str, ext: str) -> str:
        """A real on-disk path for `stem` (no-op for local)."""
        return self._path(stem, ext)

    def cleanup(self, path: str) -> None:
        """No-op: local source files are not ours to delete."""

    def read_json(self, stem: str) -> dict:
        with open(self._path(stem, ".json")) as f:
            return json.load(f)

    def write_json(self, stem: str, obj: dict) -> None:
        p = self._path(stem, ".json")
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, p)  # atomic: a kill mid-write never leaves a half file


class S3Layer:
    """Keyed blobs under an S3 prefix."""

    def __init__(self, client, bucket: str, prefix: str, scratch: str = "/tmp"):
        self.s3 = client
        self.bucket = bucket
        self.prefix = prefix.rstrip("/") + "/"
        self.scratch = scratch

    def _key(self, stem: str, ext: str) -> str:
        return f"{self.prefix}{stem}{ext}"

    def list_stems(self, ext: str) -> list[str]:
        paginator = self.s3.get_paginator("list_objects_v2")
        out = []
        for page in paginator.paginate(Bucket=self.bucket, Prefix=self.prefix):
            for obj in page.get("Contents", []):
                if obj["Key"].endswith(ext):
                    out.append(_stem(obj["Key"]))
        return sorted(out)

    def exists(self, stem: str, ext: str) -> bool:
        try:
            self.s3.head_object(Bucket=self.bucket, Key=self._key(stem, ext))
            return True
        except self.s3.exceptions.ClientError:
            return False

    def local_path(self, stem: str, ext: str) -> str:
        """Download `stem` to scratch and return the local path. Caller deletes."""
        dest = os.path.join(self.scratch, f"{stem}{ext}")
        self.s3.download_file(self.bucket, self._key(stem, ext), dest)
        return dest

    def cleanup(self, path: str) -> None:
        """Drop the scratch copy downloaded by local_path."""
        try:
            os.remove(path)
        except OSError:
            pass

    def read_json(self, stem: str) -> dict:
        body = self.s3.get_object(Bucket=self.bucket, Key=self._key(stem, ".json"))["Body"].read()
        return json.loads(body)

    def write_json(self, stem: str, obj: dict) -> None:
        self.s3.put_object(
            Bucket=self.bucket, Key=self._key(stem, ".json"),
            Body=json.dumps(obj).encode(), ContentType="application/json",
        )


def s3_client():
    import boto3
    from botocore.config import Config
    return boto3.client("s3", config=Config(retries={"max_attempts": 10, "mode": "adaptive"}))


# ── driver ─────────────────────────────────────────────────────────────────────


def run_stage(
    *,
    name: str,
    in_layer,
    out_layer,
    in_ext: str,
    process,          # (stem, in_layer) -> dict   (the per-doc work)
    detail,           # (result_dict) -> str        (one-line progress suffix)
    max_items: int | None = None,
) -> int:
    """Resumable + observable per-doc loop, shared by both stages."""
    idx, count = env_shard()
    stems = shard(in_layer.list_stems(in_ext), idx, count)
    if max_items:
        stems = stems[:max_items]
    total = len(stems)
    print(f"[{name}] shard {idx}/{count}: {total} docs", flush=True)

    start = time.time()
    done = 0
    for i, stem in enumerate(stems, 1):
        if out_layer.exists(stem, ".json"):
            print(f"  {i}/{total} cached {stem}", flush=True)
            continue
        try:
            result = process(stem, in_layer)
        except Exception as exc:  # one bad doc must not sink the shard
            print(f"  {i}/{total} ERROR {stem}: {exc}", file=sys.stderr, flush=True)
            continue
        result["stem"] = stem
        out_layer.write_json(stem, result)
        done += 1
        el = time.time() - start
        eta = (el / done) * (total - i) if done else 0
        print(f"  {i}/{total} {stem} · {detail(result)} · {el/done:.0f}s/doc · "
              f"ETA {eta/60:.0f}m", flush=True)
    print(f"[{name}] shard {idx} done ({done} new / {total})", flush=True)
    return 0
