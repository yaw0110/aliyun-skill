# 单表离线同步（MySQL → MaxCompute）操作手册

> 适用：DataStudio DI 节点 · wizard 模式 · SingleTableOffline（单表全量/增量离线）
> 参考样例：`sync_mysql_to_odps_YH_yh_filling_db.dal_manage_store_group_mamager_quality_goal_info_di`
> 已完成实例：`sync_mysql_to_odps_YH_yh_filling_db.offline_manual_report_store_article_order_data_di`（节点 6863893469751146305）

---

## 一、任务命名规范

统一用 `sync_mysql_to_odps_<源数据源名>.<源表名>_di`

```
sync_mysql_to_odps_YH_yh_filling_db.offline_manual_report_store_article_order_data_di
         │                      └ 源数据源名（DataWorks 数据源）
         └ 固定前缀                └ 源表名 + _di
```

- 数据源名示例：`YH_yh_filling_db`（MySQL，库 `yh_filling_db`）
- 目标 schema：`ods_<源库名>`（如 `ods_yh_filling_db`）
- 目标表名：通常与源表同名

## 二、同步方式与分区

| 项 | 值 |
|---|---|
| migrationType | `SingleTableOffline`（单表离线） |
| jobType | `SingleTableOfflineMigration` |
| 同步方式 | 全量（`truncate=true`） |
| 分区字段 | `dt` |
| 分区值 | `dt=${bizdate}`（T-1） |

> 分区字段要跟目标表 DDL 的 PARTITIONED BY 严格一致（`dt` 或 `pt`，取决于目标表），否则写分区失败。

## 三、列映射（mapping）

**核心约束：离线类型不支持 ColumnMapping 改名，只能靠 reader 源列 ↔ writer 目标列「顺序对应」实现。**

- reader 列：源 MySQL 的**真实列名**（中文就照抄，含特殊字符如 `+`、空格）
- writer 列：目标 ODPS 列名
- 两边列**数量、顺序一一对应**

示例（源/目标列名一致）：

| # | reader 列（MySQL） | writer 列（ODPS） |
|---|---|---|
| 1 | store_id | store_id |
| 2 | article_id | article_id |
| 3 | order_qty | order_qty |
| 4 | order_date | order_date |
| 5 | NOW() | ts |

> ⚠️ 源列名必须是 MySQL 表里的真实列名，差一个字符同步会失败。

## 四、时间参数（bizdate）

节点脚本参数定义：

| name | type | value |
|---|---|---|
| bizdate | System | `$[yyyy-mm-dd-1]`（T-1） |

- 分区用 `${bizdate}` 引用（如 `dt=${bizdate}`）
- 常用可加：`ts_date=$[yyyy-MM-dd]`、`ts_time=$[hh24:mi:ss]`

## 五、ts（数据接入时间）

目标表加一列 `ts TIMESTAMP COMMENT '数据接入时间'`，由 reader 的 `NOW()` 取 MySQL 当前时间，顺序对到 writer 的 `ts` 列。

- reader 列末位：`NOW()`
- writer 列末位：`ts`
- 目标表 DDL 需含 `ts TIMESTAMP`

## 六、目标表建表

**⚠️ 单表 wizard 节点不带自动建表/结构迁移能力**（无 AddColumn/DDL 配置，也不生成 DIJob）。
前端"一键生成目标表结构"是界面操作，生成的 DDL 不持久化到节点，CLI 取不到。
因此必须**手工建目标表**，DDL 严格对齐 writer 列与分区：

```sql
CREATE TABLE IF NOT EXISTS ods_yh_filling_db.offline_manual_report_store_article_order_data(
  store_id   STRING  COMMENT '门店中台编号',
  article_id STRING  COMMENT '商品订购编号',
  order_qty  DECIMAL(38,18) COMMENT '订购量',
  order_date TIMESTAMP COMMENT '订购日期',   -- 或 STRING，按源实际
  ts         TIMESTAMP COMMENT '数据接入时间'
)
COMMENT '线下手工报量门店商品明细数据'
PARTITIONED BY (dt STRING)
LIFECYCLE 36500;
```

## 七、节点 FlowSpec 脚本（content 结构）

```jsonc
{
  "extend": { "mode": "wizard", "resourceGroup": "Serverless_res_group_xxx", "cu": 0.5, "__new__": true, "formatType": "filespec" },
  "externalCode": {
    "type": "job", "version": "2.0",
    "steps": [
      {
        "stepType": "mysql", "name": "Reader", "category": "reader",
        "parameter": {
          "datasource": "YH_yh_filling_db",
          "column": ["store_id","article_id","order_qty","order_date","NOW()"],
          "where": "", "splitPk": "", "encoding": "UTF-8",
          "table": "offline_manual_report_store_article_order_data"
        }
      },
      {
        "stepType": "odps", "name": "Writer", "category": "writer",
        "parameter": {
          "schema": "ods_yh_filling_db",
          "partition": "dt=${bizdate}",
          "isCompress": false, "truncate": true,
          "datasource": "BD_MaxCompute", "tunnelQuota": "default",
          "column": ["store_id","article_id","order_qty","order_date","ts"],
          "emptyAsNull": false, "consistencyCommit": false,
          "table": "offline_manual_report_store_article_order_data"
        }
      }
    ],
    "setting": { "errorLimit": { "record": "0" }, "locale": "zh_CN", "speed": { "throttle": false, "concurrent": 2 } }
  },
  "migrationType": "SingleTableOffline",
  "jobType": "SingleTableOfflineMigration"
}
```

## 八、节点其他配置

| 项 | 值 |
|---|---|
| 命令 | DI（commandTypeId 23，engine Data Integration） |
| 调度 | cron `00 11 00 * * ?`（每天 11:00）cycleType Daily |
| 资源组 | 公共调度资源组（group_212862176241921） |
| 重跑 | rerunMode Allowed，rerunTimes 3，rerunInterval 300000 |
| inputs | `bdprd_root`（手动） |

## 九、创建/更新操作（CLI）

```bash
# 创建
aliyun dataworks-public CreateNode --ProjectId 672230 --Scene DATAWORKS_PROJECT --Spec '<FlowSpec JSON>'

# 更新（先 GetNode 拿当前 spec 再改，别从零编）
aliyun dataworks-public GetNode --Id <节点ID>
aliyun dataworks-public UpdateNode --Id <节点ID> --ProjectId 672230 --Spec '<FlowSpec JSON>'
```

**铁律**：
- 改节点前先 `GetNode` 拿现有 FlowSpec
- 禁止 `DeleteNode`（生产环境）
- 创建前确认：源数据源名、源表列名（真实）、目标表已建且分区/列对齐

## 十、Checklist

- [ ] 任务命名符合 `sync_mysql_to_odps_<源DS>.<源表>_di`
- [ ] 源数据源名正确（如 `YH_yh_filling_db`）
- [ ] reader 列 = 源表真实列名（中文/特殊字符照抄）
- [ ] writer 列与 reader **顺序一一对应**
- [ ] 分区字段 `dt` 与目标表 DDL 一致
- [ ] 时间参数 bizdate 已定义
- [ ] `ts` 列：reader `NOW()` ↔ writer `ts`，目标表含 `ts TIMESTAMP`
- [ ] 目标表已手工建好（单表 wizard 不自动建表）
- [ ] 节点已创建、发布上线

---

## 十一、SQL Server 分库分表变体（sharding_sqlserver）

> 适用：源为 **SQL Server 分库分表**（多库/多区已合并到同一个分库分表数据源）。
> 参考样例：`sync_sharding_sqlserver_to_odps_EBWMS_gwall_qdm_btin`
> 已完成实例：`..._stquo` / `..._v_dateclose_stock_all` / `..._v_stock_bi_all`

与 MySQL 版的差异：**源 step 用 `sharding_sqlserver`，一个数据源已合并所有分库分表**，所以一张源表只需一个任务。

### 11.1 数据源（关键）

- 用一个**分库分表 wrapper** 数据源即可，如 `t_EBWMS_gwall_qdm`（涵盖华南/西南/华中所有区）。
- `parentShardingDatasource` / `datasource` 都填该 wrapper 名。
- `connection` 指定逻辑库下的物理表：`[{"datasource":"t_EBWMS_gwall_qdm","table":["dbo.stquo"]}]`（`dbo.<表>`）。

### 11.2 源 step 专有参数

```jsonc
{
  "stepType": "sharding_sqlserver", "name": "Reader", "category": "reader",
  "parameter": {
    "parentShardingDatasource": "t_EBWMS_gwall_qdm",
    "datasource": "t_EBWMS_gwall_qdm",
    "column": ["cotl","inco","whid","btno","btdt","whco","qty","kqty","lqty","oqty","uqty","aqty","jqty","exqt","CURRENT_TIMESTAMP"],
    "selectTableMode": "meta",
    "connection": [{"datasource":"t_EBWMS_gwall_qdm","table":["dbo.stquo"]}],
    "tableMissingStrategy": "fail",
    "splitPk": "cotl",
    "columnMissingStrategy": "fail"
  }
}
```

### 11.3 源列名要真实

- reader `column` 必须用**源真实列名**（含驼峰，如 `purGroup`），顺序对应 writer 目标列。
- 目标表列名可大小写不同（如源 `purGroup` ↔ 目标 `purgroup`），靠**顺序**对齐。
- `splitPk` 选一个分布好的列（如主键/编码类），用于并行切分。

### 11.4 目标表类型映射

| 源类型 | 目标类型 |
|---|---|
| int / 整型 | `BIGINT` |
| datetime / 时间字段 | `TIMESTAMP` |
| decimal / float / double | `DECIMAL(18,6)` |
| varchar / char / 字符串 | `STRING` |

> 注意：源里**存字符串的“时间”字段**（老管道是 varchar，下游还做 `substr` 截取）仍映射为 `STRING`，不要臆断成 `TIMESTAMP`。

### 11.5 ts 接入时间

- 目标表末尾加 `ts TIMESTAMP COMMENT '数据接入时间'`。
- reader 列末位用 **`CURRENT_TIMESTAMP`**（不是 `NOW()`，SQL Server 语法），顺序对到 writer 末位 `ts`。
- 若目标表已建好且含 `ts` 列，DI 列清单要把 `ts` 加上才能填充。

### 11.6 writer 目标 step

```jsonc
{
  "stepType": "odps", "name": "Writer", "category": "writer",
  "parameter": {
    "schema": "ods_dbo",
    "partition": "dt=${yestoday}",
    "isCompress": false, "truncate": true,
    "datasource": "BD_MaxCompute", "tunnelQuota": "default",
    "column": ["cotl","inco","whid","btno","btdt","whco","qty","kqty","lqty","oqty","uqty","aqty","jqty","exqt","ts"],
    "emptyAsNull": false, "consistencyCommit": false,
    "table": "stquo"
  }
}
```

### 11.7 其他配置（与 MySQL 版一致）

- 分区 `dt=${yestoday}`，调度参数 `yestoday=$[yyyy-mm-dd-1]`（T-1）。
- 全量 `truncate=true`，cron `00 03 00 * * ?`，公共调度资源组 `group_212862176241921`，cu 0.5。
- inputs `bdprd_root`（手动）。创建/更新命令同「九」，克隆参考节点改表名/列名/ID 即可。

### 11.8 SQL Server 版 Checklist

- [ ] 源用一个分库分表 wrapper 数据源（`t_EBWMS_gwall_qdm`）
- [ ] `connection[].table` 用 `dbo.<源表>`
- [ ] reader 列 = 源真实列名（含驼峰如 `purGroup`）
- [ ] writer 列与 reader 顺序一一对应（目标列名可不同大小写）
- [ ] 目标表类型按 bigint/timestamp/decimal(18,6)/string 映射
- [ ] `ts` 列：reader 末位 `CURRENT_TIMESTAMP` ↔ writer 末位 `ts`
- [ ] 分区 `dt=${yestoday}`，全量 truncate，cron 03:00
- [ ] 目标表已建、节点已创建
