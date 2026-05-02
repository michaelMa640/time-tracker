$today = Get-Date -Format "yyyy-MM-dd"
$timestamp = [DateTimeOffset]::ParseExact("$today 00:00:00 +08:00", "yyyy-MM-dd HH:mm:ss zzz", $null).ToUnixTimeMilliseconds()
$dateStr = [DateTimeOffset]::FromUnixTimeMilliseconds($timestamp).UtcDateTime.AddHours(8).ToString("yyyy-MM-dd")
$currentHour = 14
$endTime = [DateTime]::Today.AddHours($currentHour)
$startTime = $endTime.AddHours(-2)
$msg = "请告诉我过去2小时（" + $startTime.ToString("HH:mm") + " - " + $endTime.ToString("HH:mm") + "）你做了什么？"

$result = @{
    action = "ask"
    isSummary = $false
    phase = "time"
    message = $msg
    timestamp = $timestamp
    dateString = $dateStr
}

$result | ConvertTo-Json -Compress
