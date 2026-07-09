"""Per-doc cost + speed telemetry.

Each worker writes one JSON to s3://{bucket}/{REPORTS_PREFIX}/{job_id}.json.
The local scripts/cost_report.py aggregator joins these with a Spot-rate
table to produce a $/page summary.

We avoid calling ec2.describe_spot_price_history from inside every worker
(IAM permission, extra cold-start latency); the aggregator looks rates up
once. The worker just records duration + instance type, which is plenty.
"""

from __future__ import annotations

import json
import os
import socket
import time
from typing import Any


def make_timer() -> dict:
    return {"start_wall": time.time(), "stages": {}, "_marks": {"_start": time.perf_counter()}}


def mark(timer: dict, label: str) -> None:
    timer["_marks"][label] = time.perf_counter()


def stage_seconds(timer: dict, label: str, *, since: str) -> None:
    """Record stage duration in seconds (label = stage name; since = prior mark)."""
    t = timer["_marks"][label] - timer["_marks"][since]
    timer["stages"][label.lstrip("_")] = round(t, 3)


def write_report(
    *,
    s3,
    bucket: str,
    key: str,
    timer: dict,
    payload: dict[str, Any],
) -> None:
    body = {
        **payload,
        "instance_type": _instance_type(),
        "hostname": socket.gethostname(),
        "seconds": {
            **timer["stages"],
            "total": round(time.time() - timer["start_wall"], 3),
        },
        "wall_start": timer["start_wall"],
        "wall_end": time.time(),
    }
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(body, default=str).encode(),
        ContentType="application/json",
    )


_instance_type_cache: str | None = None


def _instance_type() -> str:
    """Read the EC2 instance-type from IMDSv2; return 'unknown' off-EC2."""
    global _instance_type_cache
    if _instance_type_cache is not None:
        return _instance_type_cache
    val = os.getenv("AWS_BATCH_JOB_KUBE_NODE_NAME") or ""  # noop except on EKS
    if not val:
        try:
            import urllib.request
            req = urllib.request.Request(
                "http://169.254.169.254/latest/api/token",
                method="PUT",
                headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
            )
            with urllib.request.urlopen(req, timeout=0.5) as r:
                token = r.read().decode()
            req = urllib.request.Request(
                "http://169.254.169.254/latest/meta-data/instance-type",
                headers={"X-aws-ec2-metadata-token": token},
            )
            with urllib.request.urlopen(req, timeout=0.5) as r:
                val = r.read().decode()
        except Exception:
            val = "unknown"
    _instance_type_cache = val
    return val
