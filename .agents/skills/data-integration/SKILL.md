---
name: data-integration
description: DataWorks 数据集成：数据源管理、离线/实时同步任务的创建查询与运维。已实装任务列表/详情/运行明细/报警规则/事件，以及汇总数据集成产出 ODS 表的脚本。
---

# data-integration

DataWorks 数据集成（Data Integration / DI）。核心对象是**数据集成任务（DIJob）**。

## 产品信息

- 产品代码：`dataworks-public`，API 版本：`2024-05-18`
- 默认 region：`cn-hangzhou`
- **默认项目空间：`bdprd`（ProjectId=672230）**
- 凭证：全局 `aliyun`（已配置）

## 能力边界（已实装）

### 任务列表 / 详情 / 运行明细

| 目的 | 命令 |
|------|------|
| 查全部数据集成任务 | `ListDIJobs --ProjectId 672230 --PageSize 100` |
| 按名查任务 | `ListDIJobs --ProjectId 672230 --Name <任务名>` |
| 查任务详情（源/目标数据源、TableMappings、JobSettings） | `GetDIJob --DIJobId <id> --ProjectId 672230` |
| 查任务运行明细（**目标 schema/表**） | `ListDIJobRunDetails --DIJobId <id> --PageSize 200` |
| 启动 / 停止任务 | `StartDIJob` / `StopDIJob` |

**要点**：
- `ListDIJobs` 返回字段：`DIJobId` / `JobName` / `JobStatus` / `MigrationType` / `SourceDataSourceType` / `DestinationDataSourceType` / `Owner`。
- `GetDIJob` 里 `SourceDataSourceSettings[].DataSourceName`（如 `ZT_fulfillment_db`）是**数据源名**，不含连接地址。
- `ListDIJobRunDetails` 返回 `DestinationSchemaName` / `DestinationTableName` / `SourceTableName` 等 —— **查目标 schema/表用这个**。

### 报警规则（重要：CLI 只覆盖任务级自定义规则）

| 目的 | 命令 |
|------|------|
| 查数据集成任务报警规则 | `ListDIAlarmRules --JobId <id> --PageSize 100` |
| 创建 / 更新 / 删除报警规则 | `CreateDIAlarmRule` / `UpdateDIAlarmRule` / `DeleteDIAlarmRule` |
| 查告警事件（Alarm/Failover/DDL） | `ListDIJobEvents --DIJobId <id> --EventType Alarm --StartTime <ts> --EndTime <ts>` |

**⚠️ 关键限制**：
- `ListDIAlarmRules` 按**单个 JobId** 查询（不传 JobId 会报 `diJobId is null`），返回的是**任务级自定义规则**（DIAlarmRuleId）。
- **「公共报警规则（publicAlarm）」CLI 无法查询**：它只在 DataWorks 前端 BFF（`bff-cn-hangzhou.data.aliyun.com/di/listPublicAlarms`）暴露，需浏览器登录态。特征字段 `alarmType=publicAlarm`、`relatedJobList[]`、`notifySetting.webhookUrls` 等在 OpenAPI 中均不存在。

### 数据源（权限受限）

- `ListDataSources` / `GetDataSource` 需 `AliyunDataWorksFullAccess`，当前账号 **403030 无权限**，无法直接查数据源连接地址。

## 脚本：DI求ODS_表.sh

**用途**：遍历项目全部数据集成任务，汇总其产出的所有 `ods_*` 目标表清单（Markdown）。

**位置**：项目根目录 `DI求ODS_表.sh`

**原理**：`ListDIJobs`（自动翻页取全部任务）→ 逐个 `ListDIJobRunDetails` 取目标 schema/表 → 过滤 `ods_*` 前缀 → 去重按 schema 分组输出。

**用法**：
```bash
./DI求ODS_表.sh                 # 输出到 stdout
./DI求ODS_表.sh -o ods_all.md   # 写入 Markdown 文件
./DI求ODS_表.sh -p 672230 -o ods_all.md   # 指定项目
```

**注意**：
- 结果来自**数据集成任务的目标表**，反映「数据集成产出的 ODS 表」，不代表 MaxCompute 全部 ods_* 表。
- 表数会随任务表映射动态变化，以实时查询为准。

## 权限要求

- DI 相关 API（`ListDIJobs`/`GetDIJob`/`ListDIJobRunDetails`/`ListDIAlarmRules`/`ListDIJobEvents`）**有权限**。
- 数据源 API（`ListDataSources`/`GetDataSource`）**403030 无权限**，需 `AliyunDataWorksFullAccess`。

## 待补全

- [ ] 数据源连接地址查询（需加 `AliyunDataWorksFullAccess` 权限）
- [ ] 公共报警规则（publicAlarm）的查询（仅 BFF，OpenAPI 无）
