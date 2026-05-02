$today = Get-Date -Format "yyyy-MM-dd"
$ts = [DateTimeOffset]::ParseExact("$today 00:00:00 +08:00", "yyyy-MM-dd HH:mm:ss zzz", $null).ToUnixTimeMilliseconds()
$ds = [DateTimeOffset]::FromUnixTimeMilliseconds($ts).UtcDateTime.AddHours(8).ToString("yyyy-MM-dd")
$eh = [DateTime]::Today.AddHours(14)
$sh = $eh.AddHours(-2)
$msg = "${sh} - ${eh} 你做了什么？"
$msg = $sh.ToString("HH:mm") + " - " + $eh.ToString("HH:mm") + " 你做了什么？"
Write-Host "timestamp: $ts"
Write-Host "dateString: $ds"
Write-Host "startTime: $($sh.ToString('HH:mm'))"
Write-Host "endTime: $($eh.ToString('HH:mm'))"
Write-Host "message: $msg"
