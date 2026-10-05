# 开发规范（引用：新旧 SQL 迁移）

本文档收录迁移相关《开发规范》，作为 etl-migration skill 的依据。完整规范以团队正式文档为准。

## 1. 任务命名规范

一个任务只产出一张表，任务名 = 目标表名（不含库名），一一对应，不加版本号/环境词。

| 任务类型 | 命名 | 示例 |
|---|---|---|
| ODS 接入 | `sync_...`（见 1.3 表） | `sync_saphana_to_odps_SAP_hr_saphanadb.zmt001` |
| 出数推送 | `exp_...`（见 1.4 表） | `exp_dwd_trd_order_item_di` |
| 离线 / 实时任务 | 目标表名 | `dwd_trd_order_item_di` |

### 1.1 命名规则

1. 离线任务名遵循 `{layer}_{biz}_{entity}[_suffix]`，与目标表名完全一致；ODS 接入用 `sync_`、出数推送用 `exp_`。
2. 中文字段/目录名保持仓库约定，不英文化。
3. 所有任务（离线、实时、数据集成）都要加任务头，统一写在文件最上方：

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

- 第一行标明引擎/任务类型，如 `--MaxCompute SQL` / `--DorisSQL` / `--数据集成`。
- `author` / `create time` / `desc` / `changelog` 不得留空。
- `changelog` 逐行记录每次改动，不覆盖历史。
- `set odps.namespace.schema=true;` 开启 schema 命名空间。
- `set odps.task.name={目标表名};` 与任务名一致（不含库名）。
- 两行 `set` 只对 SQL 任务（离线、实时）适用；数据集成节点无 SQL 文件，写在节点描述里。

### 1.2 禁止项

- 禁止用 `_new` / `_v2` / `2` / `_copy` / `_copy_{时间戳}` / `-today` / `_dev` / `_test` 做版本或环境区分。
- 禁止库前缀 `{库}.{表}`、`{库}~{表}` 作为任务名。
- 测试任务不迁移：任务名/目标表含 `test` / `测试`、Q 测试系统、测试环境数据源，一律剔除。

### 1.3 ODS 接入任务命名（`sync_`）

| 同步方式 | 命名模板 | 示例 |
|---|---|---|
| 整库实时 | `sync_<源库>_to_<目标库>_<数据源>_rt` | `sync_polardb_to_odps_ZT_order_db_rt` |
| 整库离线 | `sync_<源库>_to_<目标库>_<数据源>` | `sync_polardb_to_odps_ZT_order_db` |
| 整库增全量 | `sync_<源库>_to_<目标库>_<数据源>_merge` | `sync_polardb_to_odps_ZT_order_db_merge` |
| 单表离线 | `sync_<源库>_to_<目标库>_<数据源>.<表名>` | `sync_saphana_to_odps_SAP_hr_saphanadb.zmt001` |

- `<源数据库>` / `<目标数据库>` 用小写；`<同步数据源>` 保持数据源登记名原样。
- 单表离线以 `.<数据表名>` 定位到具体表；其余为整库级任务。
- 新接入一律用本模板，不用旧平台 `ext_{源系统}~{表名}`。

### 1.4 出数任务命名（`exp_`）

出数源恒为 odps，不进名字：

| 场景 | 命名模板 | 示例 |
|---|---|---|
| 单表 | `exp_{数据表名}` | `exp_dwd_trd_order_item_di` |
| 多目标重名 | `exp_{数据表名}_{目标库标示}` | `exp_dwd_trd_order_item_di_DORIS_dw` |
| 整库 | `exp_{数据源}[_{rt\|merge}]` | `exp_DORIS_dw` / `exp_DORIS_dw_rt` |

## 2. DataWorks 任务命名规范

### 2.1 库表空间

| 对象 | 命名 | 示例 |
|---|---|---|
| ODS schema | `ods_{源库小写}` | `ods_sap`、`ods_wms`、`ods_saphanadb` |
| ODS 表 | 保持源表名原样 | `t_trade_order_header` |
| 表全名 | `{schema}.{table}`，不写 project（ODPS 迁移时补 `bdprd.` 三段式） | `ods_order_db.t_trade_order_header` |

### 2.3 调度参数与写数

```sql
INSERT OVERWRITE TABLE dwd.dwd_trd_order_item_di PARTITION (inc_day)
SELECT '${bizdate}' AS inc_day, ...
```

- 业务日期只用 `\${bizdate}`。
- 分区写法与生命周期见《表属性规范》。
- DataWorks 数据集成落 ODS：保留 `_data_integration_deleted_` 软删列。

### 2.4 / 2.5 ODS 接入与出数任务：见 1.3 / 1.4 表。

## 3. 接口字段命名规范

### 3.1 命名风格

| 场景 | 风格 | 示例 |
|---|---|---|
| 表字段（SQL/ODS/DWD） | `snake_case` | `sale_amt`、`store_id` |
| 接口出参 / 入参 | `lowerCamelCase` | `saleAmt`、`storeId` |

接口字段与表字段解耦：底层列名下划线，对外返回名转小驼峰，靠命名风格转换完成，不做逐字段手工改名。

### 3.2 转换规则

| 源 → 目标 | 转换类型 | 规则 | 说明 |
|---|---|---|---|
| `sale_amt` → `saleAmt` | 字段名映射 / 命名风格转换 | `snake_case` → `lowerCamelCase` | 下划线转小驼峰 |

- 转换在 DataQL hint 声明：`hint FRAGMENT_SQL_COLUMN_CASE = "hump";`，统一 `hump`。
- 以 `_` 切分，首段不动，后续段首字母大写；禁止连续下划线、尾下划线。
- SQL 别名已是 `lowerCamelCase`（无下划线）时原样透传。

### 3.3 统一要求

1. 出参、入参一律 `lowerCamelCase`，不因历史接口风格做例外。
2. 新增与改造接口均按本规范执行，存量接口改造时一并归一。
