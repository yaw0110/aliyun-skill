# aliyun-skill 项目约定

本仓库通过 agent skill 驱动 aliyun-cli 完成阿里云（重点 DataWorks）操作。

## 自动触发：遇到 DataWorks 操作必用对应 skill

凡是涉及 DataWorks / MaxCompute 的云端操作，**先 `read` 加载对应 skill 再动手**，按其命令/参数执行：

| 场景 | Skill |
|------|-------|
| 数据开发节点（查询/创建/修改/调度 ODPS_SQL 节点） | `.pi/skills/datastudio/SKILL.md` |
| 数据集成（数据源、离线/实时同步） | `.pi/skills/data-integration/SKILL.md` |
| 运维中心（实例、补数据、重跑、监控） | `.pi/skills/operation-center/SKILL.md` |
| 发布部署（上线/下线） | `.pi/skills/deploy/SKILL.md` |
| 数据地图（元数据、血缘、表检索） | `.pi/skills/datamap/SKILL.md` |
| 安装/配置 aliyun-cli | `.pi/skills/install/SKILL.md` |
| 新旧 ETL SQL 迁移（Hive→ODPS，含命名/任务头/分区规范） | `.pi/skills/etl-migration/SKILL.md` |

要点：
- 默认项目空间 `bdprd`（ProjectId=672230），region `cn-hangzhou`，凭证已配好（全局 `aliyun` 直接可用）。
- 执行 `aliyun dataworks-public <ApiName>` 前，先看对应 skill 的示例与铁律（如：禁止 `DeleteNode`、改节点前先 `GetNode`）。
- **skill 占位未实装的模块**（data-integration / operation-center / deploy / datamap 目前是骨架，无命令），先用 `aliyun dataworks-public help` 枚举 API 再补进 skill 再执行。
