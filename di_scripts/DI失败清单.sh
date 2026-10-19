#!/usr/bin/env bash
# DI任务实例失败清单导出 - Export daily DI failed instance report for bdprd
# How it works: ListTaskInstances(Failure) for the day -> filter TaskType=DI ->
#   GetTaskInstanceLog per instance -> classify error -> query alarm rules/events
#   and job config (source->destination) per DIJobId -> build Markdown
#
# Usage:
#   ./DI失败清单.sh                     # bizdate = yesterday, output ../di_fail_reports/
#   ./DI失败清单.sh -b 2026-10-12       # specific business date
#   ./DI失败清单.sh -o /path/dir        # custom output dir
# Depends on: aliyun-cli (dataworks-public), python3, credentials configured

set -euo pipefail

PROJECT_ID=672230
BIZDATE="$(python3 -c "import datetime;print((datetime.date.today()-datetime.timedelta(days=1)).isoformat())")"
OUTDIR="$(dirname "$0")/../di_fail_reports"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--bizdate) BIZDATE="$2"; shift 2;;
    -o|--outdir)  OUTDIR="$2"; shift 2;;
    -p|--project) PROJECT_ID="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 [-b YYYY-MM-DD] [-o outdir] [-p projectId]"; exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# bizdate -> millisecond timestamp (00:00:00 of that day)
BIZTS="$(python3 -c "
import datetime,sys
y,m,d=map(int,sys.argv[1].split('-'))
print(int(datetime.datetime(y,m,d).timestamp()*1000))" "$BIZDATE")"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$OUTDIR"

echo "[1/4] Listing failed instances for $BIZDATE (Prod)..." >&2
aliyun dataworks-public ListTaskInstances --ProjectId "$PROJECT_ID" --Bizdate "$BIZTS" \
  --Status Failure --PageSize 500 --ProjectEnv Prod 2>/dev/null \
  | jq -r '.PagingInfo.TaskInstances[]? | select(.TaskType=="DI") | "\(.Id)\t\(.TaskName)\t\(.Owner)"' \
  > "$TMPDIR/fail.txt" || true
TOTAL=$(wc -l < "$TMPDIR/fail.txt" | tr -d ' ')
echo "      DI failed instances: $TOTAL" >&2
if [ "$TOTAL" -eq 0 ]; then
  echo "No DI failures on $BIZDATE." >&2
  echo "$BIZDATE : 0 DI failed instances" > "$OUTDIR/DI失败清单_${BIZDATE}.txt"
  exit 0
fi

echo "[2/4] Fetching logs & classifying ($TOTAL instances)..." >&2
: > "$TMPDIR/rows.tsv"
n=0
while IFS=$'\t' read -r iid tname owner; do
  n=$((n+1))
  # fetch log with retry (transient empty/failed responses cause mis-classification)
  : > "$TMPDIR/one.log"
  for _try in 1 2 3; do
    aliyun dataworks-public GetTaskInstanceLog --Id "$iid" --RunNumber 1 2>/dev/null \
      | jq -r '.. | strings' 2>/dev/null > "$TMPDIR/one.log" || true
    [ -s "$TMPDIR/one.log" ] && break
    sleep 2
  done
  # classify: pick error code + message, dirty count, and root cause keywords
  python3 - "$TMPDIR/one.log" "$iid" "$tname" <<'PYEOF' >> "$TMPDIR/rows.tsv" || true
import sys,re
log,iid,tname=sys.argv[1],sys.argv[2],sys.argv[3]
txt=open(log,encoding='utf-8',errors='ignore').read()
def find(pat):
    m=re.search(pat,txt,re.S)
    return m.group(1).strip() if m else ''
code=find(r'Code:\[([^\]]+)\]')
desc=find(r'Description:\[([^\]]+)\]')
dirty=find(r'Dirty data: (\d+)')
caused=find(r'Caused by:\s*(.+)')
# root cause buckets (order matters)
group=''
if 'JdbcUrlParser' in txt: group='JdbcUrlParser 错误（数据源URL解析失败）'
elif 'OOM-Killed' in txt: group='OOM 被 kill（资源不足，需增CU）'
elif 'DateTimeParseException' in txt or "could not be parsed" in txt: group='时间字段解析失败'
elif 'invalid column name' in txt: group='源端无效列名（SQL引用不存在列）'
elif code=='DBUtilErrorCode-04': group='SQLServer 主键列非法 / "AND" 语法错误'
elif code=='DBUtilErrorCode-15': group='SQLServer 异步 ResultSet 失败'
elif code=='DBUtilErrorCode-06' and "附近有语法错误" in txt: group='SQLServer where 条件空 -> ")" 语法错误'
elif code=='Framework-14': group='脏数据超限（类型转换错误）'
else: group='其他'
detail=desc or caused or code or '见日志'
# collapse newlines/tabs so TSV stays single-row
detail=' '.join(detail.split())
# trailing numeric segment of node name = DIJobId (e.g. ..._78562 -> 78562)
m=re.search(r'_(\d+)$', tname)
jobid=m.group(1) if m else ''
print(f"{group}\t{iid}\t{tname}\t{dirty or ''}\t{detail}\t{jobid}")
PYEOF
  [ $((n%10)) -eq 0 ] && echo "      progress $n/$TOTAL" >&2
done < "$TMPDIR/fail.txt"

# Query alert rules + alarm events + job config per unique DIJobId
jobids=$(awk -F'\t' '{print $6}' "$TMPDIR/rows.tsv" | grep -E '^[0-9]+$' | sort -u)
echo "      checking config/alarms for $(echo $jobids | wc -w | tr -d ' ') DIJobs..." >&2
: > "$TMPDIR/alarms.tsv"
: > "$TMPDIR/configs.tsv"
STARTTS=$(( BIZTS ))
ENDTS=$(( BIZTS + 86400000 ))
for jid in $jobids; do
  rules=$(aliyun dataworks-public ListDIAlarmRules --JobId $jid --PageSize 100 2>/dev/null | jq -r '.PagingInfo.TotalCount // 0')
  events=$(aliyun dataworks-public ListDIJobEvents --DIJobId $jid --EventType Alarm --StartTime $STARTTS --EndTime $ENDTS --PageSize 100 2>/dev/null | jq -r '.PagingInfo.TotalCount // 0')
  echo -e "$jid\t${rules:-0}\t${events:-0}" >> "$TMPDIR/alarms.tsv"
  # job config: source -> destination datasource
  aliyun dataworks-public GetDIJob --DIJobId $jid --ProjectId "$PROJECT_ID" 2>/dev/null \
    | jq -r --arg jid "$jid" '.PagingInfo as $p | [$jid, $p.SourceDataSourceType, ($p.SourceDataSourceSettings[]?.DataSourceName|tostring), $p.DestinationDataSourceType, ($p.DestinationDataSourceSettings[]?.DataSourceName|tostring), $p.MigrationType] | @tsv' \
    >> "$TMPDIR/configs.tsv" || true
done

echo "[3/4] Building markdown..." >&2
OUTFILE="$OUTDIR/DI任务实例失败清单_${BIZDATE}.md"
python3 - "$TMPDIR/rows.tsv" "$BIZDATE" "$PROJECT_ID" "$TOTAL" "$OUTFILE" "$TMPDIR/alarms.tsv" "$TMPDIR/configs.tsv" <<'PYEOF'
import sys
from collections import OrderedDict, defaultdict
rowsf,bizdate,proj,total,outfile,alarmsf,configsf=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5],sys.argv[6],sys.argv[7]
groups=OrderedDict()
for line in open(rowsf):
    p=line.rstrip('\n').split('\t')
    if len(p)<5: continue
    g,iid,tname,dirty,detail=p[0],p[1],p[2],p[3],p[4]
    groups.setdefault(g,[]).append((iid,tname,dirty,detail))
total=sum(len(v) for v in groups.values())
# alarm summary: jobid -> (rules, events)
alarms={}
for line in open(alarmsf):
    p=line.rstrip('\n').split('\t')
    if len(p)==3: alarms[p[0]]=(p[1],p[2])
# job config: jobid -> (srcType, srcName, dstType, dstName, migration)
configs={}
for line in open(configsf):
    p=line.rstrip('\n').split('\t')
    if len(p)>=6: configs[p[0]]=(p[1],p[2],p[3],p[4],p[5])

def alarm_label(jobid):
    r,e=alarms.get(jobid,('?','?'))
    if r=='0' and e=='0': return '❌ 无告警'
    if r=='0' and e!='0': return f'⚠ 无规则但有{e}次告警事件'
    if r!='0' and e=='0': return f'⚠ 有{r}条规则但无触发事件'
    return f'✅ 有告警（{r}条规则 / {e}次事件）'
L=[f'# DI 数据集成任务实例失败清单','',
   f'- 项目空间：`{proj}`（Prod）','',
   f'- 业务日期（Bizdate）：{bizdate}','',
   f'- 失败实例总数：{total}','',
   f'- 生成时间：{__import__("datetime").datetime.now().strftime("%Y-%m-%d %H:%M")}','']
L+=['---','','## 失败原因归类一览','']
L+=['| 失败原因 | 实例数 |','|---|---|']
for g,rows in groups.items():
    L.append(f'| {g} | {len(rows)} |')
L+=['','---','','## 告警情况','']
if alarms:
    L+=['| DIJobId | 任务级报警规则 | 当日 Alarm 事件 | 结论 |','|---|---|---|---|']
    for jid in sorted(alarms):
        r,e=alarms[jid]
        L.append(f'| {jid} | {r} | {e} | {alarm_label(jid)} |')
else:
    L.append('_未能解析到 DIJobId，未查询告警。_')
L+=['','---','','## 任务配置','']
if configs:
    L+=['| DIJobId | 源 | 目标 | 迁移类型 |','|---|---|---|---|']
    for jid in sorted(configs):
        st,sn,dt,dn,mig=configs[jid]
        L.append(f'| {jid} | {st} `{sn}` | {dt} `{dn}` | {mig} |')
else:
    L.append('_无配置信息。_')
L+=['','---']
idx=0
for g,rows in groups.items():
    idx+=1
    L+=['',f'## {idx}. {g}（{len(rows)} 个）','']
    L+=['| 任务 | 实例 ID | 任务配置 | 告警 | 详情 |','|---|---|---|---|---|']
    for iid,tname,dirty,detail in rows:
        tn=tname.replace('offline_odps_cyc_sync_','')
        m=__import__('re').search(r'_(\d+)$', tname)
        jid=m.group(1) if m else ''
        cfg='-'
        if jid in configs:
            st,sn,dt,dn,mig=configs[jid]
            cfg=f'{st}→{dt} `{sn}→{dn}`'
        d=detail[:50]+('…' if len(detail)>50 else '')
        L.append(f'| {tn} | {iid} | {cfg} | {alarm_label(jid) if jid in alarms else "-"} | `{d}` |')
    L.append('')
md='\n'.join(L)+'\n'
open(outfile,'w').write(md)
print(f"Written {outfile} : {total} instances / {len(groups)} groups / {len(alarms)} jobs")
PYEOF

echo "[4/4] Done. Report: $OUTFILE" >&2
