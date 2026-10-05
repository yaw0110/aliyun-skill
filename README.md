# aliyun-skill

通过 agent skill 驱动 **aliyun-cli**（阿里云命令行工具）完成云端操作，采用**多 skill 架构**按领域拆分。

## 项目背景

平时操作阿里云资源需记住 aliyun-cli 用法、API 命名、参数结构，心智负担大。本项目把 aliyun-cli 封装成 agent 可用的 **skill 集合**，让 agent 能**读懂文档、生成命令、执行并解释结果**。

核心思路：**用多个按领域拆分的 skill 把 aliyun-cli 能力变成 agent 可调用的技能**。CLI 装到**用户级全局路径**（`~/.local/bin`），全局 `aliyun` 命令直接可用，各 skill 直接调用全局 `aliyun`。

## 仓库布局

```
aliyun-skill/
├── README.md
└── .agents/skills/             # 领域 skill（按 DataWorks 控制台模块分布，git 追踪的源）
    ├── install/                  # 安装：装/升/验证 CLI、配凭证、环境变量
    │   ├── SKILL.md
    │   ├── references/install.md
    │   └── scripts/              # install skill 特有：install.sh/.ps1
    ├── datastudio/               # DataStudio：数据开发
    │   ├── SKILL.md
    │   └── references/dataworks-public.md
    ├── etl-migration/            # 新旧 ETL SQL 迁移（Hive→ODPS，命名/任务头/分区规范）
    │   ├── SKILL.md
    │   └── references/dev-standards.md
    ├── data-integration/         # 数据集成：数据源、同步任务（占位）
    ├── operation-center/         # 运维中心：实例、补数据、监控（占位）
    ├── deploy/                   # 发布：部署、上下线（占位）
    └── datamap/                  # 数据地图：元数据、血缘（占位）

本地开发：`.pi/skills/*` 为指向 `.agents/skills/*` 的本地 symlink（不入库），各人自建。
```

## 快速开始

```bash
# 1. 安装 aliyun-cli 到 ~/.local/bin
cd .agents/skills/install && ./scripts/install.sh
# Windows: powershell -ExecutionPolicy Bypass -File scripts\install.ps1

# 2. 验证（全局可用）
aliyun version

# 3. 配置凭证 + region
aliyun configure --mode AK
aliyun configure set --region cn-hangzhou
aliyun sts GetCallerIdentity
```

## 定位 CLI（所有 skill 共用）

全局安装后 `aliyun` 命令直接可用，各 skill 直接调用 `aliyun`，不硬编码路径。

## 当前状态

- [x] 多 skill 架构（install + 5 个 DataWorks 模块）
- [x] CLI 用户级全局安装（`~/.local/bin`，`aliyun` 全局可用）
- [x] install skill：安装 + 凭证 + 环境变量
- [x] datastudio：数据开发模块
- [ ] 枚举 `dataworks-public` API，按模块填充各 skill
