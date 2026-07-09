#!/usr/bin/env bash
# OCR → chunk → embed worker. EventBridge fires one Batch job per S3 PUT.
#
# Injection contract: the S3 key arrives as the first CLI arg via Batch's
# `Ref::work_key` substitution in the job def's `command`. See main.tf for
# the wiring. We export it as WORK_KEY here so process_doc.py can read it
# from the environment (its long-standing contract).
#
# PAGE_START / PAGE_END for the self-fan-out slab jobs come in via
# containerOverrides.environment — those are plain env vars, no substitution.

set -euo pipefail
cd /app

# First arg is the work key (from Ref::work_key). Guard against the ad-hoc
# "no arg passed" case so the error is clear.
if [[ $# -lt 1 || "${1:-}" == "unset" || -z "${1:-}" ]]; then
  echo "ERROR: no work_key supplied (expected as \$1 via Ref::work_key)." >&2
  echo "       For ad-hoc runs, pass the S3 key as a positional argument."   >&2
  exit 64
fi
export WORK_KEY="$1"
shift

echo "=== OCR → chunk → embed (WORK_KEY=$WORK_KEY, PAGE_RANGE=${PAGE_START:-1}-${PAGE_END:-end}) ==="
exec /opt/venv/bin/python process_doc.py "$@"
