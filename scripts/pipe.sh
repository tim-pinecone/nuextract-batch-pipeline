#!/usr/bin/env bash
# One-command observability for the OCR-embed Batch pipeline.
#
# Modes:
#   pipe.sh              — snapshot: ingest files, EventBridge metrics, job
#                          counts + recent jobs, output parquets, reports
#   pipe.sh watch        — snapshot on a 5s loop (Ctrl-C to exit)
#   pipe.sh logs         — tail the latest RUNNING job's logs (else last one)
#   pipe.sh logs <jobId> — tail a specific job's logs
#   pipe.sh trace <file> — lifecycle of one ingest file: job → parquet → report
#
# All values (bucket, queue, region, rule) come from `terraform output`.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

if [[ ! -f "$TF_DIR/main.tf" ]]; then
  echo "ERROR: $TF_DIR/main.tf not found." >&2
  exit 1
fi
tf() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

BUCKET=$(tf s3_bucket)
QUEUE=$(tf job_queue)
RULE=$(tf eventbridge_rule)
REGION=$(tf region)
CONSOLE="https://${REGION}.console.aws.amazon.com"

if [[ -z "$BUCKET" || -z "$QUEUE" || -z "$REGION" ]]; then
  echo "ERROR: terraform output missing. Run \`./scripts/deploy.sh\` first." >&2
  exit 1
fi

bar() { printf '\n\033[1;36m═══ %s ═══\033[0m\n' "$1"; }
dim() { printf '\033[2m%s\033[0m\n' "$1"; }
grn() { printf '\033[32m%s\033[0m' "$1"; }
red() { printf '\033[31m%s\033[0m' "$1"; }
ylw() { printf '\033[33m%s\033[0m' "$1"; }

snapshot() {
  bar "Pipeline status  ·  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "  Bucket:  s3://$BUCKET"
  echo "  Queue:   $QUEUE"
  echo "  Region:  $REGION"
  echo "  Console: $CONSOLE/batch/home?region=$REGION#jobs"

  bar "Ingest (last 10 files)"
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "ingest/" --region "$REGION" \
    --query 'reverse(sort_by(Contents,&LastModified))[:10].[Key,Size,LastModified]' \
    --output table 2>/dev/null || dim "  (bucket empty or unreachable)"

  bar "EventBridge — last 15 min"
  start=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-15 min' +%Y-%m-%dT%H:%M:%SZ)
  end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for metric in Invocations FailedInvocations MatchedEvents; do
    val=$(aws cloudwatch get-metric-statistics --namespace AWS/Events \
          --metric-name "$metric" --dimensions Name=RuleName,Value="$RULE" \
          --start-time "$start" --end-time "$end" --period 900 --statistics Sum \
          --query 'Datapoints[0].Sum' --output text --region "$REGION" 2>/dev/null)
    printf "  %-20s %s\n" "$metric:" "${val:-0}"
  done

  bar "Batch jobs by state"
  total=0
  for s in SUBMITTED PENDING RUNNABLE STARTING RUNNING SUCCEEDED FAILED; do
    ids=$(aws batch list-jobs --job-queue "$QUEUE" --job-status "$s" --region "$REGION" \
          --query 'jobSummaryList[*].[jobId,jobName,createdAt,statusReason]' \
          --output json 2>/dev/null || echo '[]')
    n=$(echo "$ids" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
    total=$((total + n))
    case "$s" in
      RUNNING|STARTING) label=$(ylw "$s") ;;
      SUCCEEDED)        label=$(grn "$s") ;;
      FAILED)           label=$(red "$s") ;;
      *)                label="$s" ;;
    esac
    printf "  %-25b %d\n" "$label" "$n"
    if [[ "$n" -gt 0 ]]; then
      echo "$ids" | python3 -c '
import sys, json, datetime
rows = json.load(sys.stdin)[:3]
for r in rows:
    ts = datetime.datetime.fromtimestamp(r[2]/1000).strftime("%H:%M:%S")
    reason = (r[3] or "")[:60]
    print(f"      · {ts}  {r[1]:40s}  {r[0][:36]}  {reason}")' 2>/dev/null
    fi
  done
  printf "  %-25s %d\n" "TOTAL:" "$total"

  bar "Outputs — embeddings/  (last 5)"
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "embeddings/" --region "$REGION" \
    --query 'reverse(sort_by(Contents,&LastModified))[:5].[Key,Size,LastModified]' \
    --output table 2>/dev/null | grep -v '^$' || dim "  (none yet)"

  bar "Outputs — reports/  (last 5)"
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "reports/" --region "$REGION" \
    --query 'reverse(sort_by(Contents,&LastModified))[:5].[Key,Size,LastModified]' \
    --output table 2>/dev/null | grep -v '^$' || dim "  (none yet)"

  echo
}

logs() {
  local jobId="${1:-}"
  if [[ -z "$jobId" ]]; then
    for s in RUNNING STARTING SUCCEEDED FAILED; do
      jobId=$(aws batch list-jobs --job-queue "$QUEUE" --job-status "$s" --region "$REGION" \
              --query 'jobSummaryList[0].jobId' --output text 2>/dev/null || true)
      [[ "$jobId" != "None" && -n "$jobId" ]] && break
    done
    if [[ -z "$jobId" || "$jobId" == "None" ]]; then
      echo "No jobs found." >&2; exit 1
    fi
    echo "Latest job: $jobId"
  fi
  local desc status stream
  desc=$(aws batch describe-jobs --jobs "$jobId" --region "$REGION" \
         --query 'jobs[0].[status,container.logStreamName,statusReason]' \
         --output text 2>/dev/null)
  status=$(echo "$desc" | awk '{print $1}')
  stream=$(echo "$desc" | awk '{print $2}')
  if [[ -z "$stream" || "$stream" == "None" ]]; then
    echo "Job $jobId has no log stream yet."
    echo "Status: $status"
    exit 1
  fi
  echo "Stream: $stream   status=$status"
  echo "──────────────────────────────────────────────"
  if [[ "$status" == "RUNNING" || "$status" == "STARTING" ]]; then
    aws logs tail /aws/batch/job --follow --log-stream-names "$stream" --region "$REGION"
  else
    aws logs tail /aws/batch/job --since 24h --log-stream-names "$stream" --region "$REGION"
  fi
}

trace() {
  local file="$1"
  [[ -z "$file" ]] && { echo "usage: pipe.sh trace <s3-key-or-basename>"; exit 1; }
  local key="$file"
  [[ "$key" != ingest/* ]] && key=$(aws s3api list-objects-v2 --bucket "$BUCKET" \
    --prefix "ingest/" --region "$REGION" \
    --query "Contents[?ends_with(Key,\`$file\`)].Key" --output text 2>/dev/null | head -1)
  [[ -z "$key" || "$key" == "None" ]] && { echo "not found in ingest/: $file"; exit 1; }
  local stem=$(basename "${key%.*}")
  echo "═══ Trace: $key ═══"
  echo "  stem: $stem"
  echo
  echo "1. Ingest object:"
  aws s3api head-object --bucket "$BUCKET" --key "$key" --region "$REGION" \
    --query '{Size:ContentLength, Type:ContentType, Uploaded:LastModified}' --output table
  echo
  echo "2. Batch jobs (all states):"
  for s in SUBMITTED PENDING RUNNABLE STARTING RUNNING SUCCEEDED FAILED; do
    aws batch list-jobs --job-queue "$QUEUE" --job-status "$s" --region "$REGION" \
      --query 'jobSummaryList[*].[jobId,jobName,createdAt,statusReason]' \
      --output json 2>/dev/null | python3 -c "
import sys, json, datetime
state='$s'
try: rows=json.load(sys.stdin)
except: rows=[]
for r in rows:
    ts=datetime.datetime.fromtimestamp(r[2]/1000).strftime('%H:%M:%S')
    print(f'    [{state:9s}] {ts}  {r[0]}  {r[1]}  {(r[3] or \"\")[:80]}')" 2>/dev/null
  done
  echo
  echo "3. Output parquet(s):"
  aws s3 ls "s3://$BUCKET/embeddings/" --region "$REGION" 2>/dev/null | grep -F "$stem" || echo "    (none — job may still be running or failed)"
  echo
  echo "4. Report(s):"
  aws s3 ls "s3://$BUCKET/reports/" --region "$REGION" 2>/dev/null | grep -F "$stem" || echo "    (none)"
}

watch_loop() {
  trap 'echo; echo "exiting."; exit 0' INT
  while :; do
    clear
    snapshot
    dim "  (refreshing every 5s — Ctrl-C to exit)"
    sleep 5
  done
}

cmd="${1:-status}"
case "$cmd" in
  status) snapshot ;;
  watch)  watch_loop ;;
  logs)   logs "${2:-}" ;;
  trace)  trace "${2:-}" ;;
  help|-h|--help)
    grep -E '^# ' "$0" | head -30 | sed 's/^# //' ;;
  *) echo "unknown: $cmd. try: status | watch | logs [id] | trace <file>"; exit 1 ;;
esac
