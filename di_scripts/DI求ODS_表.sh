#!/usr/bin/env bash
# DI求ODS_*表 - Enumerate all ods_* tables produced by Data Integration jobs in bdprd
# How it works: ListDIJobs to get all jobs -> ListDIJobRunDetails per job to get target schema/table -> filter ods_* prefix -> dedupe & summarize
#
# Usage:
#   ./DI求ODS_表.sh                 # print to stdout
#   ./DI求ODS_表.sh -o ods_all.md   # write to a Markdown file
#   ./DI求ODS_表.sh -p 672230       # set workspace ID (default 672230=bdprd)
# Depends on: aliyun-cli (dataworks-public), credentials configured

set -euo pipefail

PROJECT_ID=672230
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_ID="$2"; shift 2;;
    -o|--output)  OUT="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 [-p workspaceID] [-o output.md]"; exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "[1/3] Fetching Data Integration job list..." >&2
# parse TotalCount with python to avoid shell quoting issues
aliyun dataworks-public ListDIJobs --ProjectId "$PROJECT_ID" --PageSize 100 --PageNumber 1 2>/dev/null > "$TMPDIR/page1.json"
PAGES=$(python3 -c "
import json;d=json.load(open('$TMPDIR/page1.json'))
tc=d['PagingInfo']['TotalCount']; print((tc+99)//100)")
echo "      paging through (100/page)" >&2

: > "$TMPDIR/job_ids.txt"
for p in $(seq 1 "$PAGES"); do
  aliyun dataworks-public ListDIJobs --ProjectId "$PROJECT_ID" --PageSize 100 --PageNumber "$p" \
    --cli-query 'PagingInfo.DIJobs[*].DIJobId' 2>/dev/null \
    | python3 -c "import sys;print('\n'.join(x.strip() for x in sys.stdin.read().strip().strip('[]').replace('\"','').split(',') if x.strip()))" \
    >> "$TMPDIR/job_ids.txt" || true
done
JOBS=$(wc -l < "$TMPDIR/job_ids.txt" | tr -d ' ')
echo "      got $JOBS jobs" >&2
[ "$JOBS" -eq 0 ] && { echo "No jobs found - check credentials / workspace ID"; exit 1; }

echo "[2/3] Querying target schema/table per job..." >&2
: > "$TMPDIR/all.tsv"
i=0
while read -r jid; do
  [ -z "$jid" ] && continue
  i=$((i+1))
  aliyun dataworks-public ListDIJobRunDetails --DIJobId "$jid" --PageSize 200 2>/dev/null \
    | python3 -c "
import sys,json
try:
    infos=json.load(sys.stdin)['PagingInfo']['JobRunInfos']
    for x in infos:
        sch=x.get('DestinationSchemaName'); tbl=x.get('DestinationTableName')
        if sch and tbl: print(f'$jid\t{sch}\t{tbl}')
except Exception: pass
" >> "$TMPDIR/all.tsv" || true
  [ $((i % 20)) -eq 0 ] && echo "      progress $i/$JOBS" >&2
done < "$TMPDIR/job_ids.txt"
echo "      raw records: $(wc -l < "$TMPDIR/all.tsv" | tr -d ' ')" >&2

echo "[3/3] Summarizing ods_* schemas (dedupe)..." >&2
python3 - "$TMPDIR/all.tsv" "$PROJECT_ID" "$OUT" <<'PYEOF'
import sys
from collections import defaultdict
tsv, proj, out = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv)>3 and sys.argv[3] else None)
tables=set()
for line in open(tsv):
    parts=line.rstrip('\n').split('\t')
    if len(parts)!=3: continue
    jid,sch,tbl=parts
    if sch.startswith('ods_'):
        tables.add((sch,tbl))
by=defaultdict(set)
for sch,tbl in sorted(tables):
    by[sch].add(tbl)
lines=[f'# ODS All Table Inventory (ods_* schema)','',
       f'> Workspace: {proj} · Source: ListDIJobs + ListDIJobRunDetails',
       f'> {len(tables)} tables / {len(by)} ods_* schemas','']
for sch in sorted(by):
    lines.append(f'## {sch} ({len(by[sch])} tables)'); lines.append('')
    for tbl in sorted(by[sch]):
        lines.append(f'- `{sch}.{tbl}`')
    lines.append('')
md='\n'.join(lines)
if out:
    open(out,'w').write(md)
    print(f'Written to {out}: {len(tables)} tables / {len(by)} schemas')
else:
    print(md)
PYEOF
