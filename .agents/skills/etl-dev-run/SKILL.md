---
name: etl-dev-run
description: >-
  把本地 ETL SQL 提交到 DataWorks DEV 试跑，并回报日志结果。
  关键字：etl试跑。也在用户说「DEV 试跑」「提交试跑」「本地 SQL 带 bizdate 跑一下」时使用。
---

# etl-dev-run

本地 SQL → DEV 试跑 → 看返回。**不改节点、不发布到 PROD。**

## 关键字

用户说 **`etl试跑`**（或同义：DEV 试跑 / 提交试跑）即启动本流程。

## 默认值

| 项 | 值 |
|----|----|
| ProjectId | `672230`（bdprd） |
| EnvType | `Dev` |
| 数据源 | `BDMaxCompute` |
| 资源组 | `group_212862176241921` |
| Owner | 当前身份 `sts GetCallerIdentity` 的 `UserId` / `PrincipalId` |
| Timeout | `3600`（必须 ≥ 3600） |
| bizdate | 用户指定；默认格式 **`yyyymmdd`**（如 `20261001`） |

## 输入

启动前向用户确认（缺一不可则追问）：

1. **SQL 来源**：本地文件路径，或直接贴 SQL
2. **bizdate**：如 `20261001`（`${bizdate}` 按此替换）

若 SQL 不含 `${bizdate}`，仍可跑；Parameters 照常带上便于日志核对。

## 流程

### 1. 准备脚本

- 读本地文件或使用用户粘贴的 SQL。
- 若使用三段式表名且未设置，在最前补：`set odps.namespace.schema=true;`
- 生成 `ClientUniqueCode`：`etl_trial_<yyyymmddHHMMSS>_<随机6位>`

### 2. 提交试跑

```bash
aliyun dataworks-public ExecuteAdhocWorkflowInstance \
  --ProjectId 672230 \
  --EnvType Dev \
  --Owner <UserId> \
  --Name "etl_trial_<短名>" \
  --BizDate <bizdate 当天 00:00:00 Asia/Shanghai 的毫秒时间戳> \
  --Tasks '<JSON>'
```

`Tasks` 单元素数组：

```json
[{
  "Name": "<短名>",
  "Type": "ODPS_SQL",
  "Owner": "<UserId>",
  "ClientUniqueCode": "<唯一码>",
  "Timeout": 3600,
  "Script": {
    "Content": "<SQL全文>",
    "Parameters": "bizdate=<yyyymmdd>"
  },
  "RuntimeResource": {
    "ResourceGroupId": "group_212862176241921",
    "Cu": "0.25"
  },
  "DataSource": { "Name": "BDMaxCompute" }
}]
```

完成标准：响应含 `WorkflowInstanceId`。

### 3. 轮询状态

每 3–5 秒：

```bash
aliyun dataworks-public GetWorkflowInstance --Id <WorkflowInstanceId>
aliyun dataworks-public ListTaskInstances \
  --ProjectId 672230 --ProjectEnv Dev \
  --Bizdate <同上毫秒时间戳> \
  --PageNumber 1 --PageSize 50
```

在 `TaskInstances` 里用 `WorkflowInstanceId` 匹配任务，记下任务实例 `Id` 与 `Status`。

完成标准：任务 `Status` 为 `Success` / `Failure` / `Cancel`（或明确超时，默认最多约 5 分钟）。

### 4. 取回结果

```bash
aliyun dataworks-public GetTaskInstanceLog --Id <任务实例Id>
```

向用户回报：

- 状态（Success / Failure）
- `WorkflowInstanceId` / 任务实例 Id
- 日志中与结果相关的片段（SELECT 结果表、报错栈）；可截尾，但必须含结果行或错误行

## 铁律

1. **只跑 Dev**：`EnvType=Dev`，禁止默认 `Prod`。
2. **不改节点**：本 skill 不调用 `UpdateNode` / `CreateNode` / `CreatePipelineRun`。
3. **不进 PROD 发布**：不做 Pipeline 上线。
4. **bizdate 默认 `yyyymmdd`**：用户给 `2026-10-01` 时先转成 `20261001` 再写入 Parameters，并口头确认。
5. **Timeout ≥ 3600**，否则 API 直接 400。
6. 动手前可对用到的 API 跑一次 `aliyun dataworks-public <Api> help`；参数以 help 为准。

## 与其它 skill 边界

| 需求 | 用 |
|------|----|
| 只试跑看返回（本流程） | **etl-dev-run** |
| 创建/修改调度节点 | datastudio |
| Hive→ODPS 迁移改写 | etl-migration |
| 发布到调度 DEV/PROD | deploy（待补） |
