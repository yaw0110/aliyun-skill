# DI 数据集成脚本集

针对 `bdprd`（ProjectId=672230）的数据集成（Data Integration / DI）只读排查脚本。
全部基于 `aliyun dataworks-public` OpenAPI，不改动云端任何配置。

## 依赖

- `aliyun` CLI（已配置凭证，region `cn-hangzhou`）
- `jq`、`python3`
- 所需权限：DI 查询类 API（`ListDIJobs`/`GetDIJob`/`ListDIJobRunDetails`/`ListDIAlarmRules`/`ListDIJobEvents`）均有；
  数据源 API（`ListDataSources`/`GetDataSource`）**403030 无权限**，本目录脚本未使用。

## 脚本一览

| 脚本 | 用途 | 主要 API | 输出 |
|------|------|----------|------|
| `DI失败清单.sh` | 指定业务日的 DI 失败实例清单：错误分类 + 告警情况 + 任务配置 | `ListTaskInstances(Failure)` → `GetTaskInstanceLog` → `ListDIAlarmRules` / `ListDIJobEvents` / `GetDIJob` | `<outdir>/DI任务实例失败清单_<bizdate>.md` |
| `DI排查清单.sh` | 全量 DI 任务导出为逐任务 CSV（含源库表、去向、过滤条件） | `ListDIJobs` + `GetDIJob` + `ListDIJobRunDetails` | CSV（默认 stdout） |
| `DI表清单.sh` | 任务→表映射清单：来源库/表 → 去向 schema/表 | `ListDIJobs` + `GetDIJob`(SourceObjectSelectionRules) + `ListDIJobRunDetails` | Markdown（默认 stdout） |
| `DI求ODS_表.sh` | 只筛 `ods_*` 目标表，按 schema 去重汇总 | `ListDIJobs` + `ListDIJobRunDetails` | Markdown（默认 stdout） |

## 通用用法

所有脚本都支持 `-p/--project <ProjectId>`（默认 672230）。输出类脚本支持 `-o/--outdir`。

```bash
# 1) 当日（默认昨天）DI 失败清单 → ./di_fail_reports/
./DI失败清单.sh
./DI失败清单.sh -b 2026-10-12 -o ../di_fail_reports   # 指定业务日与输出目录

# 2) 全量 DI 任务排查 CSV
./DI排查清单.sh -o /tmp/di_all.csv

# 3) 任务→表映射
./DI表清单.sh -o /tmp/ods_清单.md

# 4) 只看 ods_* 目标表
./DI求ODS_表.sh -o /tmp/ods_all.md
```

## `DI失败清单.sh` 加工流程

```
[1] ListTaskInstances --Status Failure --Bizdate <当日0点ms> --ProjectEnv Prod
      → jq 过滤 TaskType=="DI" → (实例ID, 任务名, Owner)
[2] 逐个 GetTaskInstanceLog --RunNumber 1（空响应重试 3 次）
      → python 正则抽取 Code / Description / Dirty data / Caused by
      → 关键字分桶（命中即停）：
          JdbcUrlParser → OOM-Killed → DateTimeParseException → invalid column name
          → DBUtilErrorCode-04 / -15 / -06 → Framework-14 → 其他
      → 任务名尾部 `_<数字>` 解析为 DIJobId
      按 DIJobId 补查：ListDIAlarmRules(规则数) / ListDIJobEvents(当日事件数) / GetDIJob(来源→去向)
[3] python 汇总为 Markdown（归类一览 / 告警情况 / 任务配置 / 各类明细表）
[4] 写入 <outdir>/DI任务实例失败清单_<bizdate>.md
```

> 说明：脚本产出的模板仅含「归类一览 + 告警情况 + 任务配置 + 明细表」；
> 历史报告里的「根因 / 建议 / 脏数据条数」段落是脚本产出后人工补写的。

## 关系与重叠

- `DI求ODS_表.sh` 是 `DI表清单.sh` 的子集（后者额外含来源库/表/过滤条件）。
- `DI排查清单.sh` 与 `DI表清单.sh` 数据源相同，差异在输出格式（CSV vs Markdown）与列。
- 三者可合并为一个带 `--format` 的脚本；当前各约 100–140 行，暂按现状保留。

## 产物落点

失败清单默认写到仓库根的 `di_fail_reports/`（`run.log` + 每日 md）；
表清单类产物（`ods_清单.md`、`ODS_All_Table清单.md` 等）当前在仓库根，未随脚本移动。
