"""Aggregate per-doc reports into a $/page + pages/sec summary.

Usage:
    uv run scripts/cost_report.py
    uv run scripts/cost_report.py --bucket some-bucket --prefix reports
    uv run scripts/cost_report.py --out cost_report.md

Reads all `reports/{job_id}.json` from S3, joins with a static Spot/on-demand
rate table, prints a markdown summary, and optionally writes it to a file.
Resumable+observable: lists keys once, downloads in a flushed loop with ETA.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from collections import defaultdict


# Pricing snapshot for us-east-1, sampled 2026-06-28.
# Spot is a 7-day rolling average from the AWS Spot Instance Pricing page; if
# you want live spot rates per worker, run `aws ec2 describe-spot-price-history`
# once and replace the dict below.
INSTANCE_RATES_USD_PER_HOUR = {
    # type:           (on-demand, spot-7d-avg)
    "g4dn.xlarge":    (0.526, 0.18),
    "g4dn.2xlarge":   (0.752, 0.26),
    "g5.xlarge":      (1.006, 0.34),
    "g5.2xlarge":     (1.212, 0.42),
    "g6.xlarge":      (0.805, 0.28),
}


def fetch_reports(bucket: str, prefix: str) -> list[dict]:
    import boto3
    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")
    keys: list[str] = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix.rstrip("/") + "/"):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".json"):
                keys.append(obj["Key"])
    print(f"[{prefix}] {len(keys)} report objects", flush=True)
    out: list[dict] = []
    t0 = time.time()
    for i, key in enumerate(keys, 1):
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        try:
            obj = json.loads(body)
            obj["_key"] = key
            out.append(obj)
        except Exception as exc:
            print(f"  skip {key}: {exc}", file=sys.stderr, flush=True)
        if i % 50 == 0 or i == len(keys):
            el = time.time() - t0
            eta = (el / i) * (len(keys) - i)
            print(f"  {i}/{len(keys)} · {el:.0f}s · ETA {eta:.0f}s", flush=True)
    return out


def summarize(reports: list[dict]) -> str:
    productive = [r for r in reports if r.get("n_pages") and not r.get("fanned_out")]
    if not productive:
        return "(no completed processing reports — only fan-out / skipped records found)\n"

    lines: list[str] = ["# OCR → chunk → embed cost report\n"]
    lines.append(f"_{len(productive)} completed jobs across "
                 f"{len({r.get('instance_type','?') for r in productive})} instance types_\n")

    # Per-parser totals.
    by_parser: dict[str, list[dict]] = defaultdict(list)
    for r in productive:
        by_parser[r.get("parser", "?")].append(r)

    lines.append("## By parser\n")
    lines.append("| parser | docs | pages | chunks | median s/page | p90 s/page | pages/sec (median) |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for p, rs in sorted(by_parser.items()):
        pages = sum(r.get("n_pages", 0) for r in rs)
        chunks = sum(r.get("n_chunks", 0) for r in rs)
        spp = [r["seconds"]["total"] / max(1, r.get("n_pages", 1)) for r in rs if r.get("seconds")]
        med = statistics.median(spp) if spp else 0
        p90 = sorted(spp)[int(0.9 * (len(spp) - 1))] if spp else 0
        pps = 1.0 / med if med else 0
        lines.append(f"| {p} | {len(rs)} | {pages} | {chunks} | "
                     f"{med:.1f} | {p90:.1f} | {pps:.2f} |")
    lines.append("")

    # $/page by instance type.
    lines.append("## $/page by instance type (Spot rate)\n")
    lines.append("| instance | jobs | pages | hours | spot $/hr | total $ | $/page |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    grand_total = 0.0
    grand_pages = 0
    for itype, rs in sorted(by_parser_instance(productive).items()):
        total_secs = sum(r["seconds"]["total"] for r in rs if r.get("seconds"))
        pages = sum(r.get("n_pages", 0) for r in rs)
        hours = total_secs / 3600.0
        rate = INSTANCE_RATES_USD_PER_HOUR.get(itype, (None, None))[1]
        if rate is None:
            lines.append(f"| {itype} | {len(rs)} | {pages} | {hours:.2f} | ? | ? | ? |")
            continue
        dollars = hours * rate
        per_page = dollars / max(1, pages)
        grand_total += dollars
        grand_pages += pages
        lines.append(f"| {itype} | {len(rs)} | {pages} | {hours:.2f} | "
                     f"${rate:.3f} | ${dollars:.2f} | ${per_page:.5f} |")
    if grand_pages:
        lines.append(f"\n**Aggregate:** ${grand_total:.2f} over {grand_pages} pages "
                     f"= **${grand_total/grand_pages:.5f} / page**\n")

    # Stage breakdown.
    lines.append("## Per-stage seconds (median across jobs)\n")
    stages = ["ocr", "write", "total"]
    by_stage = defaultdict(list)
    for r in productive:
        for stage in stages:
            v = r.get("seconds", {}).get(stage)
            if v is not None:
                by_stage[stage].append(v)
    lines.append("| stage | median s | p90 s |")
    lines.append("|---|---:|---:|")
    for stage in stages:
        vals = sorted(by_stage[stage])
        if not vals:
            continue
        med = statistics.median(vals)
        p90 = vals[int(0.9 * (len(vals) - 1))]
        lines.append(f"| {stage} | {med:.1f} | {p90:.1f} |")
    lines.append("")
    return "\n".join(lines)


def by_parser_instance(reports: list[dict]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = defaultdict(list)
    for r in reports:
        out[r.get("instance_type", "unknown")].append(r)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bucket", default=os.getenv("S3_BUCKET"))
    ap.add_argument("--prefix", default="reports")
    ap.add_argument("--out", help="Write the markdown summary here (default: stdout)")
    args = ap.parse_args()
    if not args.bucket:
        raise SystemExit("--bucket required (or set S3_BUCKET)")

    reports = fetch_reports(args.bucket, args.prefix)
    md = summarize(reports)
    if args.out:
        with open(args.out, "w") as f:
            f.write(md)
        print(f"\n[wrote] {args.out}", flush=True)
    else:
        print("\n" + md)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
