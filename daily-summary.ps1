# Time Tracker Daily Summary - 每日时间统计
# ⚠️ 此脚本已废弃（2026-03-25起）：统计功能已合并到 run.ps1 的 22:00 综合任务中
# 用法: .\daily-summary.ps1 -Date <日期>

param(
    [string]$Date = (Get-Date).ToString("yyyy-MM-dd")
)

. (Join-Path $PSScriptRoot 'scripts/lib/field-map.ps1')
$schema = Get-TimeTrackerSchema
$appToken = $schema.BaseToken
$tableId = $schema.Tables.Detail.Id
$summaryTableId = $schema.Tables.Stats.Id

Write-Host "=== Time Tracker Daily Summary ==="
Write-Host "日期: $Date"
Write-Host ""

# 获取日期的时间戳（用于查询）
$parsedDate = [DateTime]::Parse($Date)
$timestamp = [DateTimeOffset]::new($parsedDate.Date, [TimeSpan]::Zero).ToUnixTimeMilliseconds()

Write-Host "时间戳: $timestamp"
Write-Host ""

# 注意：实际查询需要通过 feishu_bitable_app_table_record 工具
# 这里输出查询参数，供主程序调用

# 输出JSON格式的查询请求
$result = @{
    action = "query_and_summary"
    date = $Date
    timestamp = $timestamp
    appToken = $appToken
    tableId = $tableId
    summaryTableId = $summaryTableId
    message = "需要查询日期 $Date 的所有记录并统计分类时长"
}

$result | ConvertTo-Json -Compress

Write-Host ""
Write-Host "查询参数已生成，等待主程序调用 API 查询记录..."
