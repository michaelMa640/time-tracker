$today = Get-Date -Format "yyyy-MM-dd"
$timestamp = [DateTimeOffset]::ParseExact(
    "$today 00:00:00 +08:00",
    "yyyy-MM-dd HH:mm:ss zzz",
    $null
).ToUnixTimeMilliseconds()

Write-Host "Today: $today"
Write-Host "Timestamp: $timestamp"
