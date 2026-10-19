#!/usr/bin/env bash
# DI排查清单 - Enumerate all Data Integration jobs in bdprd into a CSV
# Columns: 任务名,任务ID,来源数据源,来源库,来源表,去向类型,去向schema,去向表,同步过滤条件
#
# Usage:
#   ./DI排查清单.sh                 # print CSV to stdout
#   ./DI排查清单.sh -o di_all.csv   # write to CSV file
#   ./DI排查清单.sh -p 672230       # set workspace ID (default 672230=bdprd)
set -euo pipefail

PROJECT_ID=672230
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_ID="$2"; shift 2;;
    -o|--output)  OUT="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 [-p workspaceID] [-o output.csv]"; exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "[1/3] Fetching DI job list..." >&2
aliyun dataworks-public ListDIJobs --ProjectId "$PROJECT_ID" --PageSize 100 --PageNumber 1 2>/dev/null > "$TMPDIR/page1.json"
PAGES=$(python3 -c "
import json;d=json.load(open('$TMPDIR/page1.json'))
tc=d['PagingInfo']['TotalCount']; print((tc+99)//100)")

: > "$TMPDIR/jobs.tsv"
for p in $(seq 1 "$PAGES"); do
  aliyun dataworks-public ListDIJobs --ProjectId "$PROJECT_ID" --PageSize 100 --PageNumber "$p" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
for j in d['PagingInfo']['DIJobs']:
    print(j['DIJobId'], j.get('JobName',''), j.get('DestinationDataSourceType',''), sep='\t')
" >> "$TMPDIR/jobs.tsv" || true
done
JOBS=$(wc -l < "$TMPDIR/jobs.tsv" | tr -d ' ')
echo "      got $JOBS jobs" >&2
[ "$JOBS" -eq 0 ] && { echo "No jobs found - check credentials / workspace ID"; exit 1; }

echo "[2/3] Querying per-job source / target / filter..." >&2
# 任务ID | 来源数据源(join) | 过滤条件JSON | 来源库 | 来源表 | 去向schema | 去向表
: > "$TMPDIR/rows.tsv"
i=0
while IFS=$'\t' read -r jid jname dtype; do
  [ -z "$jid" ] && continue
  i=$((i+1))
  # GetDIJob: source datasource + filter condition (SourceObjectSelectionRules) + configured db/table
  FILTER=""; SRCDS=""; CFGDB=""; CFGTBL=""
  aliyun dataworks-public GetDIJob --DIJobId "$jid" --ProjectId "$PROJECT_ID" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)['PagingInfo']
sds=[s.get('DataSourceName','') for s in d.get('SourceDataSourceSettings',[])]
rules=[]; dbs=set(); tbls=set()
for m in d.get('TableMappings',[]):
    for r in m.get('SourceObjectSelectionRules',[]):
        rules.append(r.get('Action','')+':'+r.get('ObjectType','')+'='+r.get('Expression',''))
        ot=r.get('ObjectType'); ex=r.get('Expression'); act=r.get('Action')
        if act=='Include':
            if ot in ('Database','Schema'): dbs.add(ex)
            elif ot=='Table': tbls.add(ex)
for t in d.get('TransformationRules',[]):
    if t.get('RuleActionType')=='DefineIncrementalCondition':
        rules.append('Incr='+t.get('RuleName',''))
print('\t'.join([','.join(sds), '; '.join(rules), ','.join(sorted(dbs)), ','.join(sorted(tbls))]))
" > "$TMPDIR/jobcfg.txt" || true
  IFS=$'\t' read -r SRCDS FILTER CFGDB CFGTBL < "$TMPDIR/jobcfg.txt" || true
  FILTER="${FILTER%% ;}"

  # ListDIJobRunDetails: per actual synced table (source db/table, dest schema/table)
  aliyun dataworks-public ListDIJobRunDetails --DIJobId "$jid" --PageSize 200 2>/dev/null \
    | python3 -c "
import sys,json
try:
    infos=json.load(sys.stdin)['PagingInfo']['JobRunInfos']
    for x in infos:
        print('\t'.join([
            x.get('SourceDatasourceName','') or '',
            x.get('SourceDatabaseName','') or '',
            x.get('SourceTableName','') or '',
            x.get('DestinationSchemaName','') or '',
            x.get('DestinationTableName','') or '',
        ]))
except Exception: pass
" > "$TMPDIR/details.txt" || true

  if [ -s "$TMPDIR/details.txt" ]; then
    while IFS=$'\t' read -r rds rdb rtb dsch dtb; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$jid" "$jname" "${SRCDS:-$rds}" "$rdb" "$rtb" "$dtype" "$dsch" "$dtb" "$FILTER" >> "$TMPDIR/rows.tsv"
    done < "$TMPDIR/details.txt"
  else
    # no run-detail rows: fall back to configured source db/table from GetDIJob
    if [ -n "$CFGTBL" ]; then
      for tb in ${CFGTBL//,/ }; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t\t\t%s\n' "$jid" "$jname" "$SRCDS" "$CFGDB" "$tb" "$dtype" "$FILTER" >> "$TMPDIR/rows.tsv"
      done
    else
      printf '%s\t%s\t%s\t\t\t%s\t\t\t%s\n' "$jid" "$jname" "$SRCDS" "$dtype" "$FILTER" >> "$TMPDIR/rows.tsv"
    fi
  fi
  [ $((i % 20)) -eq 0 ] && echo "      progress $i/$JOBS" >&2
done < "$TMPDIR/jobs.tsv"

echo "[3/3] Writing CSV..." >&2
python3 - "$TMPDIR/rows.tsv" "$OUT" <<'PYEOF'
import sys, csv
tsv, out = sys.argv[1], (sys.argv[2] if len(sys.argv)>2 and sys.argv[2] else None)
rows=[]
for line in open(tsv):
    parts=line.rstrip('\n').split('\t')
    rows.append(parts)
rows.sort(key=lambda r:(r[1], r[0]))  # by job name
import io
buf=io.StringIO()
w=csv.writer(buf)
w.writerow(['任务名','任务ID','来源数据源','来源库','来源表','去向类型','去向schema','去向表','同步过滤条件'])
for r in rows:
    w.writerow(r)
csv_str=buf.getvalue()
if out:
    open(out,'w').write(csv_str)
    print(f'Written to {out}: {len(rows)} rows', file=sys.stderr)
else:
    sys.stdout.write(csv_str)
PYEOF
