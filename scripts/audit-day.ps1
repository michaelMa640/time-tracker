param(
    [Parameter(Mandatory = $true)]
    [string]$Date,

    [switch]$IncludeRecords,

    [switch]$PrettyJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/common.ps1')

function Get-TimeSortKey {
    param([string]$TimeText)

    if ([string]::IsNullOrWhiteSpace($TimeText)) {
        return [TimeSpan]::FromHours(99)
    }

    return Convert-TimeTextToTimeSpan -TimeText $TimeText
}

function Get-PrimaryAnomalyFlag {
    param([object[]]$Issues)

    if (-not $Issues -or $Issues.Count -eq 0) {
        return 'none'
    }

    $types = @($Issues | ForEach-Object { $_.type })
    if ($types -contains 'overlap') { return 'overlap' }
    if ($types -contains 'duplicate') { return 'duplicate' }
    if ($types -contains 'timestamp_mismatch') { return 'mismatch' }
    if ($types -contains 'gap') { return 'gap' }
    return 'none'
}

function New-IssueRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [hashtable]$Properties = @{}
    )

    $issue = [pscustomobject]@{}
    $issue | Add-Member -NotePropertyName 'type' -NotePropertyValue $Type

    foreach ($key in $Properties.Keys) {
        $issue | Add-Member -NotePropertyName $key -NotePropertyValue $Properties[$key]
    }

    return $issue
}

$getDayRecordsPath = Join-Path $PSScriptRoot 'get-day-records.ps1'
$dayData = Invoke-LocalJsonScript -ScriptPath $getDayRecordsPath -Arguments @('-Date', $Date)
$records = @($dayData.records)

$sortedRecords = $records | Sort-Object `
    @{ Expression = { Get-TimeSortKey -TimeText $_.start } }, `
    @{ Expression = { Get-TimeSortKey -TimeText $_.end } }, `
    @{ Expression = { if ($_.task) { $_.task } else { '' } } }

$issues = [System.Collections.ArrayList]::new()

foreach ($record in $sortedRecords) {
    foreach ($existingIssue in @($record.issues)) {
        [void]$issues.Add((New-IssueRecord -Type $existingIssue.type -Properties @{
            recordId = $existingIssue.recordId
            expectedDateKey = $existingIssue.expectedDateKey
            actualDateKey = $existingIssue.actualDateKey
        }))
    }
}

$duplicateGroups = $sortedRecords | Group-Object {
    $taskValue = if ($_.task) { $_.task } else { '' }
    $categoryValue = if ($_.category) { $_.category } else { '' }
    "$($_.rangeKey)||$taskValue||$categoryValue"
}

foreach ($group in $duplicateGroups) {
    if ($group.Count -gt 1) {
        [void]$issues.Add((New-IssueRecord -Type 'duplicate' -Properties @{
            key = $group.Name
            count = $group.Count
            range = $group.Group[0].rangeKey
            task = $group.Group[0].task
            category = $group.Group[0].category
            recordIds = @($group.Group | ForEach-Object { $_.recordId })
        }))
    }
}

for ($i = 1; $i -lt $sortedRecords.Count; $i++) {
    $previous = $sortedRecords[$i - 1]
    $current = $sortedRecords[$i]

    if ([string]::IsNullOrWhiteSpace($previous.start) -or
        [string]::IsNullOrWhiteSpace($previous.end) -or
        [string]::IsNullOrWhiteSpace($current.start) -or
        [string]::IsNullOrWhiteSpace($current.end)) {
        continue
    }

    $previousEnd = Convert-TimeTextToTimeSpan -TimeText $previous.end
    $currentStart = Convert-TimeTextToTimeSpan -TimeText $current.start
    $currentEnd = Convert-TimeTextToTimeSpan -TimeText $current.end

    # 处理跨天 00:00：当结束时间文本为 00:00 时，视为次日 24:00
    if ($previous.end -eq '00:00' -and $previousEnd -lt (Convert-TimeTextToTimeSpan -TimeText $previous.start)) {
        $previousEnd = [TimeSpan]::FromHours(24)
    }
    if ($current.end -eq '00:00' -and $currentEnd -lt $currentStart) {
        $currentEnd = [TimeSpan]::FromHours(24)
    }

    if ($currentStart -lt $previousEnd) {
        $sameExactRecord = (
            $previous.rangeKey -eq $current.rangeKey -and
            $previous.task -eq $current.task -and
            $previous.category -eq $current.category
        )

        if (-not $sameExactRecord) {
            [void]$issues.Add((New-IssueRecord -Type 'overlap' -Properties @{
                leftRecordId = $previous.recordId
                rightRecordId = $current.recordId
                leftRange = $previous.rangeKey
                rightRange = $current.rangeKey
                leftTask = $previous.task
                rightTask = $current.task
            }))
        }
    } elseif ($currentStart -gt $previousEnd) {
        [void]$issues.Add((New-IssueRecord -Type 'gap' -Properties @{
            leftRecordId = $previous.recordId
            rightRecordId = $current.recordId
            gapStart = $previous.end
            gapEnd = $current.start
            hours = [math]::Round(($currentStart - $previousEnd).TotalHours, 4)
        }))
    }

    if ($currentEnd -lt $currentStart) {
        [void]$issues.Add((New-IssueRecord -Type 'invalid_time_range' -Properties @{
            recordId = $current.recordId
            start = $current.start
            end = $current.end
        }))
    }
}

$issueArray = [System.Collections.ArrayList]::new()
foreach ($issue in $issues) {
    [void]$issueArray.Add($issue)
}
$summary = [pscustomobject]@{
    recordCount = @($sortedRecords).Count
    duplicateCount = @($issueArray | Where-Object type -eq 'duplicate').Count
    overlapCount = @($issueArray | Where-Object type -eq 'overlap').Count
    mismatchCount = @($issueArray | Where-Object type -eq 'timestamp_mismatch').Count
    gapCount = @($issueArray | Where-Object type -eq 'gap').Count
    invalidTimeRangeCount = @($issueArray | Where-Object type -eq 'invalid_time_range').Count
    blockingIssueCount = @($issueArray | Where-Object { $_.type -in @('duplicate', 'overlap', 'timestamp_mismatch', 'invalid_time_range') }).Count
    hasBlockingIssues = (@($issueArray | Where-Object { $_.type -in @('duplicate', 'overlap', 'timestamp_mismatch', 'invalid_time_range') }).Count -gt 0)
    anomalyFlag = Get-PrimaryAnomalyFlag -Issues $issueArray
}

$result = [pscustomobject]@{
    date = $Date
    source = [pscustomobject]@{
        script = 'audit-day.ps1'
        recordsScript = 'get-day-records.ps1'
    }
    summary = $summary
    issues = $issueArray
}

if ($IncludeRecords) {
    $result | Add-Member -NotePropertyName 'records' -NotePropertyValue @($sortedRecords)
}

if ($PrettyJson) {
    $result | ConvertTo-Json -Depth 8
} else {
    $result | ConvertTo-Json -Depth 8 -Compress
}
