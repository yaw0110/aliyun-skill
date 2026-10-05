---
name: etl-migration
description: 新旧 ETL SQL / Python / Shell 任务迁移：把旧版 Hive SQL（ETL v1）迁移为新版 MaxCompute/ODPS SQL（ETL v2），以及把旧平台 Python/Shell 任务中的数据计算抽取转换为 DataWorks ODPS_SQL 节点，遵循《开发规范》（任务命名、任务头、库表空间、调度参数与写数）。当需要把存量 Hive/Python/Shell 任务迁移到 DataWorks，或把旧库表/旧命名改造成新版规范时使用。
---

# etl-migration

新旧版 ETL 任务迁移：**旧版** = Hive SQL（`ddl.*` 库、`inc_day` 分区、`set mapred.*`/`set hive.*` 参数）及旧平台 Python/Shell 任务。**新版** = DataWorks MaxCompute/ODPS（`bdprd.{schema}.{table}` 三段式、`dt` 分区、`set odps.*` 参数），统一落 **ODPS_SQL** 节点。一次迁移产出单个目标表对应的新版任务 + 任务头。

## 适用范围

- 把仓库/存量平台里的 **Hive SQL 任务**迁移为 **DataWorks ODPS(MaxCompute) SQL**（`ODPS_SQL` 节点）。
- 把旧平台的 **Python / Shell 任务**中的数据计算抽取为 **DataWorks ODPS_SQL** 节点。
- 迁移后产物交给 datastudio skill 创建/更新 DataWorks 节点，或作为 `etl/{layer}/` 下的 `.sql` 文件入库。

## 迁移目标模板（新版 SQL 标准头）

每个迁移产物**顶部必须**有任务头，第一行标引擎，随后补齐规范头：

```sql
--MaxCompute SQL
--********************************************************************--
--author: {负责人}
--create time: {yyyy-MM-dd HH:mm:ss}
--desc: {中文说明}
--changelog: {yyyy-MM-dd} {负责人} {变更说明}
--********************************************************************--

set odps.namespace.schema=true;
set odps.task.name={目标表名};
```

要点（铁律，缺一不可）：

- `author` / `create time` / `desc` / `changelog` **不得留空**。旧版头信息（作者、日期、说明）迁移时继承过来；迁移这一版要在 `changelog` 追加一行，如 `2026-09-30 负责人 Hive SQL 改为 ODPS(MaxCompute) SQL`。
- `set odps.namespace.schema=true;` 开启 schema 命名空间。
- `set odps.task.name={目标表名};` 与任务名一致，**不含库名**。如 `set odps.task.name=dwd_mem_group_log_da;`。
- `desc` 用中文，可继承旧版「任务功能说明」并补迁移说明。
- 旧版 Hive 的队列配置直接删除（ODPS 默认有队列，无需设置 `set odps.task.wlm.quota`）。

## 新旧版映射表

迁移时按下表逐条替换：

| 旧版 (Hive v1) | 新版 (MaxCompute v2) | 说明 |
|---|---|---|
| `--Hive SQL` / 无引擎标注 | `--MaxCompute SQL` | 第一行标明引擎 |
| `set mapred.job.name=ddl.xxx` | `set odps.task.name={目标表名}` | 任务名与目标表名一致，不含库名 |
| `set mapred.job.queue.name=root.etl` | 删除 | 队列 ODPS 默认有，无需设置 |
| `set hive.exec.dynamic.partition=true;` 等 hive 参数 | 删除，注释说明 | ODPS 无对应或不需要 |
| `set hive.execution.engine=mr;` / mapjoin / 目录递归等 | 删除 | ODPS 默认引擎，无对应项 |
| `{schema}.{table}`（如 `ods_wechat_app_db.t_corp_group_chat`） | `bdprd.{schema}.{table}` | 补 project 前缀，三段式全名 |
| `insert overwrite table ddl.ddl_xxx partition(inc_day='${bizdate}')` | `insert overwrite table {schema}.{table} partition(dt='${bizdate}')` | 目标库 `dwd`，分区 `dt` |
| 分区列 `inc_day = '${bizdate}'` | `dt = '${bizdate}'` | 全表/条件里的分区改 `dt` |
| `substr(join_time, 1, 10)` | `substr(cast(join_time as string), 1, 10)` | 时间列需先 cast 为 string |

## 迁移步骤

1. **读旧版 SQL**：确认引擎、目标库表、分区列、调度参数、依赖表。
2. **改任务头**：生成新版规范头（见「迁移目标模板」），`changelog` 追加迁移记录。
3. **改命名**：目标表/任务名按《开发规范》第 1 节命名规则（`{layer}_{biz}_{entity}[_suffix]`）；库前缀 `ddl.*` 改为 `dwd.*`；源表补 `bdprd.` project 前缀；任务名 = 目标表名。
4. **改分区**：`inc_day` → `dt`，写数用 `partition(dt='${bizdate}')`，业务日期只用 `\${bizdate}`。
5. **清理 Hive 参数**：删 `set mapred.*` / `set hive.*`，删动态分区/目录递归/执行引擎/mapjoin 等无对应项，必要时注释说明。
6. **改语法**：时间列 `substr(...)` 前补 `cast(列 as string)`；保留 `set odps.namespace.schema=true;` 与 `set odps.task.name=...;`。
7. **自查**：对照下方「迁移清单」逐项核对，产出新版 SQL 文件（`etl/{layer}/{目标表名}.sql`）。

## 迁移清单（自查）

- [ ] 第一行是 `--MaxCompute SQL`
- [ ] 任务头完整：author / create time / desc / changelog 均非空，changelog 含本次迁移记录
- [ ] `set odps.namespace.schema=true;` 与 `set odps.task.name={目标表名};` 存在且任务名=目标表名（无库名）
- [ ] 无 `ddl.*` 库前缀、无旧任务名（目标表名不再是 `ddl.ddl_xxx`）
- [ ] 源表均写 `bdprd.{schema}.{table}` 三段式全名
- [ ] 写数分区用 `partition(dt='${bizdate}')`，分区列 `dt`，无 `inc_day`
- [ ] 无 `set mapred.*` / `set hive.*` / `set hive.execution.engine` 等旧参数
- [ ] 时间列 cast 为 string 后再 substr
- [ ] 目标表名/任务名不含版本号、`_new/_v2/_copy`、库前缀、`test` 等禁止项

## Python / Shell 任务转换

旧平台的 Python/Shell 任务**统一转为 DataWorks ODPS_SQL 节点**（不建 PyODPS/Shell 节点）。**转换不改业务逻辑**：把 Python/Shell 里真正做数据计算的部分还原成 ODPS SQL，跑数、建临时表、写目标表全在 SQL 里完成。

转换原则：

- **抽数逻辑转 SQL**：Python 里的 `hive -e`/`o.execute_sql`、Shell 里的 `hive -e`/`mysql -e` 等跑数逻辑，还原为 ODPS SQL 写入 ODPS_SQL 节点。
- **纯命令/文件/调用类操作**：不属于数据计算，迁移时剔除，改由 DataWorks 数据集成或其它节点承载，不进 ODPS_SQL。
- **任务名 = 目标表名**：一个任务只产一张表，任务名即目标表名（不含库名）。

### 转换目标模板（ODPS_SQL 节点任务头）

```sql
--MaxCompute SQL
--********************************************************************--
--author: {负责人}
--create time: {yyyy-MM-dd HH:mm:ss}
--desc: {中文说明}
--changelog: {yyyy-MM-dd} {负责人} {变更说明}
--********************************************************************--

set odps.namespace.schema=true;
set odps.task.name={目标表名};
```

- 第一行 `--MaxCompute SQL`。
- `author` / `create time` / `desc` / `changelog` **不得留空**，`changelog` 追加本次转换记录（如 `2026-09-30 负责人 旧平台 Python 改为 DataWorks ODPS_SQL`）。
- 两行 `set`（`odps.namespace.schema` / `odps.task.name`）与 SQL 迁移一致，任务名=目标表名。

### Python / Shell → ODPS_SQL 转换规则

| 旧版（Python/Shell） | 新版（ODPS_SQL 节点） | 说明 |
|---|---|---|
| `hive -e "SQL"` / 调用 Hive CLI 跑 SQL | 直接写成 ODPS SQL | 还原为 SQL 正文，删 CLI 包裹 |
| Python 跑数逻辑（读库/算数/写表） | 还原成 INSERT OVERWRITE 的 ODPS SQL | 业务逻辑等价改写为 SQL |
| 数据库直连（JDBC / pymysql / `mysql -e`） | 移除，改由数据集成或 SQL 读写 ODPS | 任务内不复刻数据库直连 |
| 业务日期变量 | `\${bizdate}` | 业务日期只用 `\${bizdate}` |
| 写 `ddl.ddl_xxx` 表 / `inc_day` 分区 | 写 `dwd.{目标表名}` / `partition(dt='${bizdate}')` | 命名与分区按《开发规范》2.x |
| 源表 `ods_wechat_app_db.t_xxx` | `bdprd.ods_wechat_app_db.t_xxx` | 补 project 三段式全名 |
| 旧队列/集群配置 | 删除 | ODPS 默认队列，无需设置 |

### 转换步骤

1. **读旧脚本**：区分「数据计算逻辑」与「命令/文件/调度壳」，识别对库表/分区的依赖。
2. **还原 SQL**：把跑数逻辑（读源、处理、写目标）改写成一条 INSERT OVERWRITE 的 ODPS SQL，保留业务逻辑与注释。
3. **改任务头**：生成 ODPS_SQL 节点任务头，`changelog` 追加转换记录。
4. **改库表命名**：目标库 `dwd.{目标表名}`，源表补 `bdprd.` 前缀，任务名=目标表名（不含库名）。
5. **改分区与日期**：`inc_day` → `dt`，写数 `partition(dt='${bizdate}')`，业务日期统一 `\${bizdate}`。
6. **清理运行时**：删 Hive CLI 包裹、数据库直连、队列集群配置。
7. **自查**：对照下方「转换清单」核对，产出 ODPS SQL 交 datastudio skill 建 ODPS_SQL 节点。

### 转换清单（自查）

- [ ] 第一行 `--MaxCompute SQL`
- [ ] 任务头完整：author / create time / desc / changelog 均非空，changelog 含本次转换记录
- [ ] 无 Hive CLI 调用、无 JDBC/数据库直连、无 `mysql -e`/`hive -e`/`pymysql`
- [ ] 数据计算逻辑已还原为 INSERT OVERWRITE 的 ODPS SQL
- [ ] 源表 `bdprd.{schema}.{table}` 三段式；目标库 `dwd.{目标表名}`
- [ ] 写数分区 `partition(dt='${bizdate}')`，分区列 `dt`，业务日期只用 `\${bizdate}`，无 `inc_day`
- [ ] `set odps.namespace.schema=true;` 与 `set odps.task.name={目标表名};` 存在，任务名=目标表名
- [ ] 无旧队列/集群配置
- [ ] 任务名=目标表名，无版本号/库前缀/`test` 等禁止项

## 与其它 skill 衔接

- 迁移产物的**新 SQL 文件**：落 `etl/{layer}/{目标表名}.sql`（如 `etl/dwd/dwd_mem_group_log.sql`）。
- 迁移产物的**云端节点**：交给 datastudio skill（`CreateNode`/`UpdateNode`），统一建 **ODPS_SQL** 节点，用转换后的 script content。
- 涉及表权限/审批：见 datastudio skill 的表权限申请与审批章节。

## 铁律

1. 迁移不改业务逻辑，只做引擎/命名/分区/参数迁移，SELECT/脚本逻辑逐条保留（含注释掉的列）。
2. 任务名=目标表名，一一对应，禁止加版本号/环境词。
3. `author`/`create time`/`desc`/`changelog` 任何一项缺失都要补全，不得留空。
4. 目标表/任务名含 `test`/`测试` 或为 Q 测试系统任务的，**剔除不迁移**。
5. 所有迁移产物（Hive SQL、Python、Shell）统一落 **ODPS_SQL** 节点，两行 `set`（`odps.namespace.schema` / `odps.task.name`）适用所有迁移任务。
