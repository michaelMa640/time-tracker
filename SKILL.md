# Time Tracker Skill

## 描述

每 2 小时询问一次用户过去 2 小时的活动，并把结果写入飞书时间追踪明细表；22:00 与 24:00 任务在记录完成后，会基于当日真实明细数据做全量审计与重算。

## 当前实现状态（2026-04-22）

当前重构已落地的脚本与能力：

- 已完成真实表结构基线校验
- 已完成按 `日期键` 拉取单日全部明细记录
- 已完成单日审计：`duplicate / overlap / timestamp_mismatch / gap / invalid_time_range`
- 已完成单日重算与统计表写回准备
- 已完成日期修复与修复后自动重算
- 已完成 `run.ps1` 与新重算链路集成

## 设计原则

1. `日期` 字段保留为北京时间当天 `00:00:00` 的时间戳锚点
2. `日期键` 作为稳定查询锚点，格式固定为 `YYYY-MM-DD`
3. 统计表永远是明细表的派生结果，不能靠会话记忆累计
4. 模型负责理解用户输入，脚本负责时间、审计、统计、修复
5. 22:00 与 24:00 都必须读取当天真实数据后重算

## 运行入口

主入口：

- `./run.ps1`
- `./run.sh`（推荐给 macOS / Linux 外层调度器使用）

运行依赖：

- PowerShell 7+（macOS / Linux 用 `pwsh`，Windows 可用 `pwsh` 或 `powershell.exe`）
- `lark-cli`（或设置环境变量 `TIME_TRACKER_LARK_CLI_PATH` 指向可执行文件）
- Python 3（或设置环境变量 `TIME_TRACKER_PYTHON_PATH`）
- 私有配置文件 `time-tracker.config.json`（可由 `time-tracker.config.example.json` 复制后填写）

运行阶段：

- `ask`：产出当前时段提问文案
- `store`：把用户输入解析成结构化明细记录
- `feeling`：22:00 专用，询问当天体感
- `summary`：22:00 / 24:00 专用，调用 `rebuild-day.ps1` 做全量重算

常用示例：

```powershell
pwsh -File ./run.ps1 -CurrentHour 10 -Phase ask
pwsh -File ./run.ps1 -CurrentHour 10 -Phase store -UserInput "1小时写代码，1小时开会"
pwsh -File ./run.ps1 -CurrentHour 10 -Phase store -UserInput "1小时写代码，1小时开会" -WriteBackDetails
pwsh -File ./run.ps1 -CurrentHour 22 -Phase feeling
pwsh -File ./run.ps1 -CurrentHour 22 -Phase summary -UserInput "今天整体状态不错" -StatusValue 82
pwsh -File ./run.ps1 -CurrentHour 24 -Phase summary -WriteBackStats
```

```bash
./run.sh -CurrentHour 10 -Phase ask
./run.sh -CurrentHour 10 -Phase store -UserInput "1小时写代码，1小时开会"
```

## 工作模式

### 1. `record`

正常心跳记录最近 2 小时活动。

### 2. `rebuild`

手动重算某一天统计，例如：

```powershell
pwsh -File ./scripts/rebuild-day.ps1 -Date 2026-04-21 -AsJson
```

### 3. `repair`

修复错误日期、错误年份、错挂记录、重复记录之后再自动重算，例如：

```powershell
pwsh -File ./scripts/repair-date.ps1 -RecordIds recA,recB -ToDateKey 2026-04-21
```

## 触发时间表

| 触发时间 | 询问时段 | 执行任务 |
|---------|---------|---------|
| 10:00 | 08:00-10:00 | 记录到明细表 |
| 12:00 | 10:00-12:00 | 记录到明细表 |
| 14:00 | 12:00-14:00 | 记录到明细表 |
| 16:00 | 14:00-16:00 | 记录到明细表 |
| 18:00 | 16:00-18:00 | 记录到明细表 |
| 20:00 | 18:00-20:00 | 记录到明细表 |
| 22:00 | 20:00-22:00 | 记录 + 体感 + 当天全量重算 |
| 24:00 | 22:00-24:00 | 补充记录 + 当天全量重算 |

## 实际流程

### 常规时段（10:00-20:00）

1. `ask` 生成当前时段问题
2. 用户回复后执行 `store`
3. `store` 返回 `records[*].fields`
4. 可由外层执行器写入明细表，或直接在 `store` 阶段传 `-WriteBackDetails`

### 22:00

1. `ask` 询问 `20:00-22:00 你做了什么？`
2. `store` 解析并返回明细写入 payload
3. 外层写入明细表，或直接使用 `-WriteBackDetails`
4. 执行 `feeling` 询问今日体感
5. 执行 `summary`
6. `summary` 内部调用 `rebuild-day.ps1`，重新读取当天全部记录并审计、重算
7. 如需要真正写回统计表，调用 `summary` 时传 `-WriteBackStats`

### 24:00

1. `ask` 询问 `22:00-24:00 你做了什么？`
2. 若 `store` 输入为空，返回 `action=noop`，静默结束
3. 若有回复，`store` 返回明细写入 payload，并给出 `nextPhase=summary` 与 `autoProceed=true`
4. 执行 `summary`
5. `summary` 内部调用 `rebuild-day.ps1`，对当天做全量重算

### 24:00 日期语义

24:00 任务的目标日期不是次日，而是“刚结束的那一天”。

例如：

- 2026-04-22 00:00 触发的 `24:00` 心跳
- 目标日期应为 `2026-04-21`
- 记录槽为 `22:00-24:00`

## 明细解析规则

### 时段映射

- 每次心跳固定对应前 2 小时时间槽
- 用户未显式给出开始结束时间时，按当前心跳槽从前往后顺序排布
- 例如 `1小时A，30分钟B，30分钟C` 会顺序映射到当前槽内连续时间段

### 分类规则

默认分类：

- 工作
- 学习
- 娱乐

脚本会按关键词做初步分类，例如：

- `开会 / 会议 / 开发 / 调试 / 修复 / 写代码` 归为工作
- `学习 / 看书 / 课程 / 复盘 / 阅读` 归为学习
- 未命中时默认归为娱乐

### 补齐规则

若用户输入总时长少于 120 分钟，脚本会自动补一条 `娱乐/休息` 记录，把本时段补满 2 小时。

## 写入与输出约定

### `store` 阶段输出

`run.ps1 -Phase store` 返回：

- `records`
- `records[*].fields`
- `detailTableId`
- `detailWriteBack`
- `targetDateKey`
- `batchId`
- `nextPhase`
- `autoProceed`

其中 `records[*].fields` 已按飞书字段 ID 组装，可直接供外层写入。

`detailWriteBack` 的行为：

- 默认仅返回预览计划，不实际写表
- 传入 `-WriteBackDetails` 后，会直接调用 `lark-cli base +record-batch-create`
- 一旦已实际写入，返回结果中的 `shouldWriteRecords=false`，用于避免外层重复写入

### `summary` 阶段输出

`run.ps1 -Phase summary` 返回：

- `rebuild.totals`
- `rebuild.audit`
- `rebuild.statsLookup`
- `rebuild.writeBack`

默认是预览模式；只有传入 `-WriteBackStats` 时，才会真正写回统计表。

### 阻断异常

若审计发现以下阻断问题：

- `duplicate`
- `overlap`
- `timestamp_mismatch`
- `invalid_time_range`

则 `rebuild-day.ps1` 默认阻止统计写回。只有明确允许时，才可传 `-AllowBlockingIssues`。

## 时间戳与日期键策略

### 时间戳

`日期` 字段必须严格表示北京时间当天 `00:00:00`。

标准生成方式由公共脚本统一提供，禁止人工手填。

### 日期键

`日期键` 固定为：

- `YYYY-MM-DD`

查询优先使用 `日期键`，必要时再回退到 `日期` 文本。

## 当前表结构

### 明细表

已使用字段：

- 日期
- 日期键
- 开始时间
- 结束时间
- 任务名称
- 分类
- 批次ID
- 来源类型
- 校验状态

说明：

- 当前真实表里已存在以上字段
- `修订说明` 仍未落表，因此修复脚本暂不写该字段

### 统计表

已使用字段：

- 日期
- 日期键
- 工作时长(小时)
- 工作占比
- 学习时长(小时)
- 学习占比
- 娱乐时长(小时)
- 娱乐占比
- 体感
- 状态值
- 统计版本号
- 最近重算时间
- 统计来源
- 异常标记

## 已落地脚本

- `scripts/lib/field-map.ps1`
  - 维护真实字段 ID 映射
- `scripts/lib/common.ps1`
  - 公共日期、JSON、CLI、批量更新辅助函数
- `scripts/get-day-records.ps1`
  - 拉取某日全部记录，处理分页与日期回退匹配
- `scripts/audit-day.ps1`
  - 检测重复、重叠、时间戳不一致、缺口、非法时间段
- `scripts/rebuild-day.ps1`
  - 基于真实明细重算统计，可选写回统计表
- `scripts/repair-date.ps1`
  - 修复错误日期，并可在修复后自动触发重算

## 工具使用约定

- 明细写入：**优先使用飞书插件工具**（`feishu_bitable_app_table_record`），`lark-cli` 仅在插件不可用时作为 fallback
- 统计重算：统一走 `rebuild-day.ps1`
- 历史修复：统一走 `repair-date.ps1`
- 禁止依赖会话记忆手工累加当天统计

## 表格配置

公开仓库不包含真实飞书 `BaseToken`、表 ID、字段 ID。

使用前请：

1. 复制 `time-tracker.config.example.json`
2. 重命名为 `time-tracker.config.json`
3. 填入你自己的飞书 Base Token、表 ID、字段 ID

`time-tracker.config.json` 已加入 `.gitignore`，不会被提交。
