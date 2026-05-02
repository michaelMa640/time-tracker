# time-tracker Phase 0 字段基线

更新日期：2026-04-22  
来源：使用 `lark-cli base +field-list` 实测读取飞书 Base 字段结构  
Base Token：`<redacted>`

## 结论摘要

Phase 0 已完成字段盘点，结论如下：

1. 明细表已具备：
   - `日期`
   - `日期键`
   - `开始时间`
   - `结束时间`
   - `任务名称`
   - `分类`
   - `批次ID`
   - `来源类型`
   - `校验状态`

2. 明细表尚未发现：
   - `修订说明`

3. 统计表已具备：
   - `日期`
   - `日期键`
   - `工作时长(小时)`
   - `工作占比`
   - `学习时长(小时)`
   - `学习占比`
   - `娱乐时长(小时)`
   - `娱乐占比`
   - `体感`
   - `状态值`
   - `统计版本号`
   - `最近重算时间`
   - `统计来源`
   - `异常标记`

4. 这意味着：
   - v2 方案需要的统计表元字段已经全部到位
   - 明细表只差 `修订说明` 这一项可选增强字段
   - 下一阶段可以直接开始抽公共 helper，并实现 `get-day-records.ps1`

---

## 明细表基线

表名：`时间追踪明细表`  
表 ID：`<redacted>`

| 字段名 | 字段 ID | 类型 | 当前状态 | 备注 |
|------|------|------|------|------|
| 分类 | `<redacted>` | `select` | 已存在 | 选项包含 `工作 / 学习 / 娱乐` |
| 校验状态 | `<redacted>` | `text` | 已存在 | 可用于 `ok / timestamp_mismatch / overlap / duplicate / gap` |
| 任务名称 | `<redacted>` | `text` | 已存在 | 记录主文本 |
| 日期 | `<redacted>` | `datetime` | 已存在 | 显示格式 `yyyy/MM/dd` |
| 批次ID | `<redacted>` | `text` | 已存在 | 可用于 heartbeat / repair 批次定位 |
| 开始时间 | `<redacted>` | `text` | 已存在 | 当前仍为文本字段 |
| 来源类型 | `<redacted>` | `text` | 已存在 | 可写 `heartbeat / manual-repair / rebuild` |
| 结束时间 | `<redacted>` | `text` | 已存在 | 当前仍为文本字段 |
| 日期键 | `<redacted>` | `text` | 已存在 | v2 推荐锚点，格式应固定为 `YYYY-MM-DD` |

### 明细表缺口

当前未发现 `修订说明` 字段。  
这不会阻塞 `get-day-records.ps1`、`audit-day.ps1` 和 `rebuild-day.ps1` 的开发，但会影响后续 `repair-date.ps1` 写入修复备注时的完备性。

建议：

1. Phase 1-4 可以先继续推进
2. 在进入 `repair-date.ps1` 之前，再决定是否补建 `修订说明`

---

## 统计表基线

表名：`每日时间统计表`  
表 ID：`<redacted>`

| 字段名 | 字段 ID | 类型 | 当前状态 | 备注 |
|------|------|------|------|------|
| 统计来源 | `<redacted>` | `text` | 已存在 | 可写 `auto-22 / auto-24 / manual-rebuild` |
| 异常标记 | `<redacted>` | `text` | 已存在 | 可写 `none / overlap / duplicate / mismatch / gap` |
| 日期 | `<redacted>` | `datetime` | 已存在 | 显示格式 `yyyy/MM/dd` |
| 学习时长(小时) | `<redacted>` | `number` | 已存在 | 精度 1 位 |
| 工作占比 | `<redacted>` | `number` | 已存在 | `percentage=false`，说明应存百分比数值而非 0-1 小数 |
| 工作时长(小时) | `<redacted>` | `number` | 已存在 | 精度 1 位 |
| 统计版本号 | `<redacted>` | `text` | 已存在 | 可写重算版本号 |
| 最近重算时间 | `<redacted>` | `text` | 已存在 | 当前是文本字段，不是 datetime |
| 学习占比 | `<redacted>` | `number` | 已存在 | `percentage=false` |
| 娱乐时长(小时) | `<redacted>` | `number` | 已存在 | 精度 1 位 |
| 娱乐占比 | `<redacted>` | `number` | 已存在 | `percentage=false` |
| 状态值 | `<redacted>` | `number` | 已存在 | 精度 1 位 |
| 日期键 | `<redacted>` | `text` | 已存在 | 可作为统计表定位锚点 |
| 体感 | `<redacted>` | `text` | 已存在 | 存一句话体感描述 |

### 统计表结论

统计表已经具备 v2 方案建议的全部核心字段。  
后续 `rebuild-day.ps1` 可以直接实现：

1. 按 `日期键` 查找统计行
2. 不存在则创建
3. 存在则覆盖更新
4. 同步写入 `统计版本号 / 最近重算时间 / 统计来源 / 异常标记`

---

## 字段映射结论

本阶段已将脚本层字段映射固化到：

`./scripts/lib/field-map.ps1`

该文件当前承担以下职责：

1. 从私有配置读取 Base Token 与两张表 ID
2. 提供字段名映射结构
3. 承载字段 ID 基线
4. 记录当前缺失字段
5. 提供枚举值建议

后续所有脚本都应优先引用这个映射，而不是散落硬编码字段名。

---

## 对下一阶段的直接影响

### 可以直接开始

1. `scripts/lib/common.ps1`
2. `scripts/get-day-records.ps1`

### 开发时应遵守

1. 读取逻辑优先按 `日期键`
2. 统计表占比字段必须存百分比数值，例如 `62.5`
3. `日期` 字段仍然保留，并继续作为飞书看板兼容字段
4. `最近重算时间` 当前是文本字段，因此写入时应明确统一格式

### 暂不阻塞但需记账

1. 明细表尚缺 `修订说明`
2. 后续如果要做完整 repair 报告，建议补建

---

## 执行记录

本次 Phase 0 通过以下命令核验：

```powershell
& lark-cli base +field-list --base-token <your-base-token> --table-id <your-detail-table-id> --offset 0 --limit 100
& lark-cli base +field-list --base-token <your-base-token> --table-id <your-stats-table-id> --offset 0 --limit 100
```

后续如果字段结构发生变化，应重新执行一次 Phase 0 校验并更新本文件。
