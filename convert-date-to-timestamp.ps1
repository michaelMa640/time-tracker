# convert-date-to-timestamp.ps1
# 用法: .\convert-date-to-timestamp.ps1 -Date "2026-04-21"
# 输出: 1776700800000
param(
    [Parameter(Mandatory = $true)]
    [string]$Date
)

$timestamp = [DateTimeOffset]::ParseExact(
    "${Date}T00:00:00+08:00",
    "yyyy-MM-dd'T'HH:mm:ssK",
    [System.Globalization.CultureInfo]::InvariantCulture
).ToUnixTimeMilliseconds()

Write-Output $timestamp
