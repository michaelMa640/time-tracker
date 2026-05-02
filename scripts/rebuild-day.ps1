param(
    [Parameter(Mandatory = $true)]
    [string]$Date,

    [switch]$WriteBack,

    [switch]$AllowBlockingIssues,

    [string]$Feeling,

    [Nullable[double]]$StatusValue = $null,

    [string]$Source = 'manual-rebuild',

    [switch]$AsJson,

    [switch]$PrettyJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/common.ps1')

function Convert-ToObjectArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    return @($Value)
}

function Convert-ToRowArray {
    param($Value)

    $items = @(Convert-ToObjectArray -Value $Value)
    if ($items.Count -eq 0) { return @() }
    if ($items[0] -is [System.Array]) { return @($items) }
    return ,@($items)
}

function New-StatsRowObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RecordId,

        [Parameter(Mandatory = $true)]
        $Row,

        [Parameter(Mandatory = $true)]
        [hashtable]$IndexMap,

        [Parameter(Mandatory = $true)]
        [string]$TargetDate
    )

    $schema = Get-TimeTrackerSchema
    $stats = $schema.Tables.Stats.FieldIds
    $rowValues = [object[]]@($Row)

    $dateText = Convert-CellValueToText -Value $rowValues[$IndexMap[$stats.Date]]
    $dateKey = Convert-CellValueToText -Value $rowValues[$IndexMap[$stats.DateKey]]
    $derivedDateKey = Convert-DateTextToDateKey -DateText $dateText
    $feeling = Convert-CellValueToText -Value $rowValues[$IndexMap[$stats.Feeling]]
    $statusValueText = Convert-CellValueToText -Value $rowValues[$IndexMap[$stats.StatusValue]]
    $statsVersion = Convert-CellValueToText -Value $rowValues[$IndexMap[$stats.StatsVersion]]
    $rebuiltAt = Convert-CellValueToText -Value $rowValues[$IndexMap[$stats.RebuiltAt]]
    $statsSource = Convert-CellValueToText -Value $rowValues[$IndexMap[$stats.StatsSource]]
    $anomalyFlag = Convert-CellValueToText -Value $rowValues[$IndexMap[$stats.AnomalyFlag]]

    $matchedBy = $null
    if ($dateKey -eq $TargetDate) {
        $matchedBy = 'date_key'
    } elseif ($derivedDateKey -eq $TargetDate) {
        $matchedBy = 'date_text_fallback'
    }

    $statusValueNumber = $null
    if (-not [string]::IsNullOrWhiteSpace($statusValueText)) {
        try {
            $statusValueNumber = [double]$statusValueText
        } catch {
            $statusValueNumber = $null
        }
    }

    $record = [pscustomobject]@{}
    $record | Add-Member -NotePropertyName 'recordId' -NotePropertyValue $RecordId
    $record | Add-Member -NotePropertyName 'dateText' -NotePropertyValue $dateText
    $record | Add-Member -NotePropertyName 'dateKey' -NotePropertyValue $dateKey
    $record | Add-Member -NotePropertyName 'derivedDateKey' -NotePropertyValue $derivedDateKey
    $record | Add-Member -NotePropertyName 'matchedBy' -NotePropertyValue $matchedBy
    $record | Add-Member -NotePropertyName 'feeling' -NotePropertyValue $feeling
    $record | Add-Member -NotePropertyName 'statusValue' -NotePropertyValue $statusValueNumber
    $record | Add-Member -NotePropertyName 'statsVersion' -NotePropertyValue $statsVersion
    $record | Add-Member -NotePropertyName 'rebuiltAt' -NotePropertyValue $rebuiltAt
    $record | Add-Member -NotePropertyName 'statsSource' -NotePropertyValue $statsSource
    $record | Add-Member -NotePropertyName 'anomalyFlag' -NotePropertyValue $anomalyFlag
    return $record
}

function Get-MatchedStatsRows {
    param([string]$TargetDate)

    $schema = Get-TimeTrackerSchema
    $statsTableId = $schema.Tables.Stats.Id
    $stats = $schema.Tables.Stats.FieldIds
    $selectedFieldIds = @(
        $stats.Date,
        $stats.DateKey,
        $stats.Feeling,
        $stats.StatusValue,
        $stats.StatsVersion,
        $stats.RebuiltAt,
        $stats.StatsSource,
        $stats.AnomalyFlag
    )

    $matches = [System.Collections.ArrayList]::new()
    $offset = 0
    $hasMore = $true

    while ($hasMore) {
        $response = Invoke-TimeTrackerRecordList -TableId $statsTableId -FieldIds $selectedFieldIds -Offset $offset -Limit 200
        $payload = $response.data
        $rows = @(Convert-ToRowArray -Value $payload.data)
        $recordIds = @(Convert-ToObjectArray -Value $payload.record_id_list)
        $indexMap = New-FieldIndexMap -FieldIds @(Convert-ToObjectArray -Value $payload.field_id_list)

        for ($i = 0; $i -lt $rows.Count; $i++) {
            $rowObject = New-StatsRowObject -RecordId ([string]$recordIds[$i]) -Row $rows[$i] -IndexMap $indexMap -TargetDate $TargetDate
            if ($rowObject.matchedBy) {
                [void]$matches.Add($rowObject)
            }
        }

        $hasMore = [bool]$payload.has_more
        $offset += $rows.Count
        if ($rows.Count -eq 0) { break }
    }

    return $matches
}

function Add-OptionalField {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Fields,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        $Value
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $Fields[$Key] = $Value
}

function Get-BlockingIssueCount {
    param([object[]]$Issues)

    $count = 0
    foreach ($issue in @($Issues)) {
        if ($null -eq $issue) {
            continue
        }

        $propertyNames = @($issue.PSObject.Properties.Name)
        if (-not ($propertyNames -contains 'type')) {
            continue
        }

        if ($issue.type -in @('duplicate', 'overlap', 'timestamp_mismatch', 'invalid_time_range', 'stats_duplicate_rows')) {
            $count += 1
        }
    }

    return $count
}

function Get-SummedHoursForCategory {
    param(
        [object[]]$Records,
        [string]$Category
    )

    $measure = $Records | Where-Object category -eq $Category | Measure-Object hours -Sum
    $sum = 0
    if ($null -ne $measure -and $null -ne $measure.Sum) {
        $sum = [double]$measure.Sum
    }

    return [math]::Round($sum, 2)
}

$auditPath = Join-Path $PSScriptRoot 'audit-day.ps1'
$auditData = Invoke-LocalJsonScript -ScriptPath $auditPath -Arguments @('-Date', $Date, '-IncludeRecords')
$records = @(Convert-ToObjectArray -Value $auditData.records)
$auditIssues = [System.Collections.ArrayList]::new()
foreach ($issue in @(Convert-ToObjectArray -Value $auditData.issues)) {
    [void]$auditIssues.Add($issue)
}

$categories = Get-TimeTrackerCategoryNames
$work = Get-SummedHoursForCategory -Records $records -Category $categories.Work
$study = Get-SummedHoursForCategory -Records $records -Category $categories.Study
$fun = Get-SummedHoursForCategory -Records $records -Category $categories.Fun
$total = [math]::Round(($work + $study + $fun), 2)

$workPct = if ($total -gt 0) { [math]::Round(($work / $total) * 100, 2) } else { 0 }
$studyPct = if ($total -gt 0) { [math]::Round(($study / $total) * 100, 2) } else { 0 }
$funPct = if ($total -gt 0) { [math]::Round(($fun / $total) * 100, 2) } else { 0 }

$statsMatches = @(Get-MatchedStatsRows -TargetDate $Date)
if ($statsMatches.Count -gt 1) {
    [void]$auditIssues.Add(([pscustomobject]@{
        type = 'stats_duplicate_rows'
        date = $Date
        count = $statsMatches.Count
        recordIds = @($statsMatches | ForEach-Object { $_.recordId })
    }))
}

$primaryStatsMatch = if ($statsMatches.Count -gt 0) { $statsMatches[0] } else { $null }
$resolvedFeeling = if (-not [string]::IsNullOrWhiteSpace($Feeling)) { $Feeling } elseif ($null -ne $primaryStatsMatch) { $primaryStatsMatch.feeling } else { $null }
$resolvedStatusValue = if ($PSBoundParameters.ContainsKey('StatusValue')) { $StatusValue } elseif ($null -ne $primaryStatsMatch) { $primaryStatsMatch.statusValue } else { $null }

$schema = Get-TimeTrackerSchema
$statsFieldIds = $schema.Tables.Stats.FieldIds
$timestamp = Get-DateKeyTimestamp -DateKey $Date
$dateTextForWrite = Get-DateKeyDateTimeText -DateKey $Date
$statsVersion = Get-RebuildVersion -Source $Source
$rebuiltAt = Get-BeijingNowText
$issueArray = [System.Collections.ArrayList]::new()
foreach ($issue in $auditIssues) {
    [void]$issueArray.Add($issue)
}
$blockingIssueCount = Get-BlockingIssueCount -Issues $issueArray
$hasBlockingIssues = ($blockingIssueCount -gt 0)
$anomalyFlag = if ($null -ne $auditData.summary) { $auditData.summary.anomalyFlag } else { 'none' }
if ($statsMatches.Count -gt 1) {
    $anomalyFlag = 'duplicate'
}

$fields = @{}
$fields[$statsFieldIds.Date] = $dateTextForWrite
$fields[$statsFieldIds.DateKey] = $Date
$fields[$statsFieldIds.WorkHours] = $work
$fields[$statsFieldIds.WorkRatio] = $workPct
$fields[$statsFieldIds.StudyHours] = $study
$fields[$statsFieldIds.StudyRatio] = $studyPct
$fields[$statsFieldIds.FunHours] = $fun
$fields[$statsFieldIds.FunRatio] = $funPct
$fields[$statsFieldIds.StatsVersion] = $statsVersion
$fields[$statsFieldIds.RebuiltAt] = $rebuiltAt
$fields[$statsFieldIds.StatsSource] = $Source
$fields[$statsFieldIds.AnomalyFlag] = $anomalyFlag
Add-OptionalField -Fields $fields -Key $statsFieldIds.Feeling -Value $Feeling
Add-OptionalField -Fields $fields -Key $statsFieldIds.StatusValue -Value $StatusValue

$writeMode = if ($null -ne $primaryStatsMatch) { 'update' } else { 'create' }
$targetRecordId = $null
if ($null -ne $primaryStatsMatch) {
    $targetRecordId = $primaryStatsMatch.recordId
}

$writeBackInfo = [pscustomobject]@{
    requested = [bool]$WriteBack
    mode = $writeMode
    blocked = $false
    reason = $null
    targetRecordId = $targetRecordId
    matchCount = $statsMatches.Count
    fields = $fields
}

if ($WriteBack) {
    if ($hasBlockingIssues -and -not $AllowBlockingIssues) {
        $writeBackInfo.blocked = $true
        $writeBackInfo.reason = 'blocking_issues_detected'
    } else {
        $upsertResponse = Invoke-TimeTrackerRecordUpsert -TableId $schema.Tables.Stats.Id -Fields $fields -RecordId $writeBackInfo.targetRecordId
        $writeBackInfo | Add-Member -NotePropertyName 'response' -NotePropertyValue $upsertResponse
    }
}

$statsMatchedBy = $null
if ($null -ne $primaryStatsMatch) {
    $statsMatchedBy = $primaryStatsMatch.matchedBy
}

$result = [pscustomobject]@{
    date = $Date
    timestamp = $timestamp
    writeDateText = $dateTextForWrite
    totals = [pscustomobject]@{
        work = $work
        study = $study
        fun = $fun
        total = $total
        workPct = $workPct
        studyPct = $studyPct
        funPct = $funPct
    }
    metadata = [pscustomobject]@{
        source = $Source
        statsVersion = $statsVersion
        rebuiltAt = $rebuiltAt
        feeling = $resolvedFeeling
        statusValue = $resolvedStatusValue
        anomalyFlag = $anomalyFlag
    }
    audit = [pscustomobject]@{
        summary = $auditData.summary
        issues = $issueArray
    }
    statsLookup = [pscustomobject]@{
        matchCount = $statsMatches.Count
        primaryRecordId = $writeBackInfo.targetRecordId
        matchedBy = $statsMatchedBy
        existingRows = @($statsMatches)
    }
    recordCount = @($records).Count
    records = @($records)
    writeBack = $writeBackInfo
}

if ($PrettyJson) {
    $result | ConvertTo-Json -Depth 8
} elseif ($AsJson) {
    $result | ConvertTo-Json -Depth 8 -Compress
} else {
    Write-Host "Date: $Date"
    Write-Host "Record count: $($result.recordCount)"
    Write-Host "Work: $work h ($workPct%)"
    Write-Host "Study: $study h ($studyPct%)"
    Write-Host "Fun: $fun h ($funPct%)"
    Write-Host "Total: $total h"
    Write-Host "Anomaly flag: $anomalyFlag"
    Write-Host "Blocking issues: $hasBlockingIssues"
    Write-Host "Stats row action: $writeMode"
    if ($writeBack.targetRecordId) {
        Write-Host "Stats record id: $($writeBack.targetRecordId)"
    }

    if ($issueArray.Count -gt 0) {
        Write-Host "Issues:"
        foreach ($issue in $issueArray) {
            Write-Host "- $($issue.type)"
        }
    }

    if ($WriteBack) {
        if ($writeBackInfo.blocked) {
            Write-Host "WriteBack: blocked ($($writeBackInfo.reason))"
        } else {
            Write-Host "WriteBack: completed"
        }
    }
}
