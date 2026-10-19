#!/usr/bin/env bash
# DI表清单.sh - 整理 DI 数据同步任务的表清单: 来源库 来源表 去向schema 去向表
# 数据来源:
#   - ListDIJobs 枚举所有 DI 任务
#   - GetDIJob    取来源 (SourceObjectSelectionRules: Datasource/Database/Table)
#   - ListDIJobRunDetails 取去向 (DestinationSchemaName/DestinationTableName)
#
# Usage:
#   ./DI表清单.sh                 # 打印到 stdout (markdown 表格)
#   ./DI表清单.sh -o ods_清单.md   # 写入 markdown
#   ./DI表清单.sh -p 672230        # 指定工作空间 (默认 672230=bdprd)

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

echo "[1/3] 枚举 DI 任务..." >&2
aliyun dataworks-public ListDIJobs --ProjectId "$PROJECT_ID" --PageSize 100 --PageNumber 1 2>/dev/null > "$TMPDIR/page1.json"
PAGES=$(python3 -c "
import json;d=json.load(open('$TMPDIR/page1.json'))
tc=d['PagingInfo']['TotalCount']; print((tc+99)//100)")

: > "$TMPDIR/job_ids.txt"
for p in $(seq 1 "$PAGES"); do
  aliyun dataworks-public ListDIJobs --ProjectId "$PROJECT_ID" --PageSize 100 --PageNumber "$p" \
    --cli-query 'PagingInfo.DIJobs[*].DIJobId' 2>/dev/null \
    | python3 -c "import sys;print('\n'.join(x.strip() for x in sys.stdin.read().strip().strip('[]').replace('\"','').split(',') if x.strip()))" \
    >> "$TMPDIR/job_ids.txt" || true
done
JOBS=$(wc -l < "$TMPDIR/job_ids.txt" | tr -d ' ')
echo "      共 $JOBS 个任务" >&2
[ "$JOBS" -eq 0 ] && { echo "未获取到任务 - 检查凭证/工作空间"; exit 1; }

echo "[2/3] 逐任务取来源(GetDIJob)与去向(RunDetails)..." >&2
: > "$TMPDIR/all.tsv"
i=0
while read -r jid; do
  [ -z "$jid" ] && continue
  i=$((i+1))
  # 去向: run details 的 destination schema/table
  DEST=$(aliyun dataworks-public ListDIJobRunDetails --DIJobId "$jid" --PageSize 200 2>/dev/null \
    | python3 -c "
import sys,json
try:
    infos=json.load(sys.stdin)['PagingInfo']['JobRunInfos']
    seen=set()
    for x in infos:
        s=x.get('DestinationSchemaName'); t=x.get('DestinationTableName')
        if s and t: seen.add((s,t))
    for s,t in sorted(seen): print(f'{s}\t{t}')
except Exception: pass")
  # 来源: GetDIJob TableMappings 的 Datasource/Database/Table
  SRC=$(aliyun dataworks-public GetDIJob --DIJobId "$jid" 2>/dev/null \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)['PagingInfo']
    ds=db=tb=None
    out=[]
    for tm in d['TableMappings']:
        row={}
        for r in tm['SourceObjectSelectionRules']:
            t=r.get('ObjectType'); e=r.get('Expression')
            if t=='Datasource': row['ds']=e
            elif t=='Database': row['db']=e
            elif t=='Table': row['tb']=e
        if 'tb' in row: out.append(row)
    for r in out:
        db=r.get('db','').split('?')[0]  # 去掉 ?currentschema= 噪声
        print(f\"{r.get('ds','')}\t{db}\t{r.get('tb','')}\")
except Exception: pass")
  if [ -z "$DEST" ] && [ -z "$SRC" ]; then continue; fi
  # 按来源表为基准对齐 (去向表名常与来源表名一致)
  # 生成: ds  db  src_tb  dest_schema  dest_tb
  python3 - "$jid" "$DEST" "$SRC" >> "$TMPDIR/all.tsv" <<'PYEOF'
import sys
jid, dest, src = sys.argv[1], sys.argv[2], sys.argv[3]
dest_rows=[l.split('\t') for l in dest.splitlines() if l.strip()]  # [[schema,tbl]...]
src_rows=[l.split('\t') for l in src.splitlines() if l.strip()]     # [[ds,db,tb]...]
# 用 dest 表名匹配 src 表名 (通常同名), 否则按顺序配对
for ds,db,tb in src_rows:
    match=[(s,t) for s,t in dest_rows if t==tb]
    if match:
        for s,t in match:
            print(f"{jid}\t{ds}\t{db}\t{tb}\t{s}\t{t}")
    else:
        print(f"{jid}\t{ds}\t{db}\t{tb}\t\t")
# dest 中未被来源覆盖的
for s,t in dest_rows:
    if not any(x[2]==t for x in src_rows):
        print(f"{jid}\t\t\t{t}\t{s}\t{t}")
PYEOF
  [ $((i % 20)) -eq 0 ] && echo "      进度 $i/$JOBS" >&2
done < "$TMPDIR/job_ids.txt"
echo "      明细行: $(wc -l < "$TMPDIR/all.tsv" | tr -d ' ')" >&2

echo "[3/3] 汇总清单..." >&2
python3 - "$TMPDIR/all.tsv" "$PROJECT_ID" "$OUT" <<'PYEOF'
import sys
from collections import defaultdict
tsv, proj, out = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv)>3 and sys.argv[3] else None)
rows=set()
for line in open(tsv):
    p=line.rstrip('\n').split('\t')
    if len(p)!=6: continue
    jid,ds,db,st,s,dt=p
    rows.add((db,st,s,dt))  # 来源库 来源表 去向schema 去向表
rows=sorted(r for r in rows if r[0] or r[2])  # 去掉全空
UNKNOWN='(未运行/API无去向)'
rows=[(db,st,(s or UNKNOWN),(dt or UNKNOWN)) for db,st,s,dt in rows]
by=defaultdict(list)
for db,st,s,dt in rows:
    by[db or s or '(未知)'].append((st, s, dt))
md=['# DI 数据同步表清单','',
    f'> 工作空间: {proj} · 来源: ListDIJobs + GetDIJob(来源) + ListDIJobRunDetails(去向)',
    f'> 共 {len(rows)} 行 · 去向未知 {sum(1 for r in rows if r[2]==UNKNOWN)} 行 (任务未运行, 平台无去向记录)', '',
    '| 来源库 | 来源表 | 去向schema | 去向表 |',
    '|---|---|---|---|']
for db in sorted(by):
    for st,s,dt in sorted(by[db]):
        md.append(f'| {db or ""} | {st or ""} | {s} | {dt} |')
text='\n'.join(md)
if out:
    open(out,'w').write(text+'\n')
    print(f'已写入 {out}: {len(rows)} 行')
else:
    print(text)
PYEOF
