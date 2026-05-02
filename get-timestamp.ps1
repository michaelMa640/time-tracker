$today = Get-Date -Format "yyyy-MM-dd"
$ts = [DateTimeOffset]::ParseExact("$today 00:00:00 +08:00", "yyyy-MM-dd HH:mm:ss zzz", $null).ToUnixTimeMilliseconds()
Write-Host "日期: $today"
Write-Host "时间戳: $ts"