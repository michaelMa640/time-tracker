param(
    [Parameter(Mandatory = $true)]
    [string]$Date,

    [int]$PageSize = 200,

    [switch]$PrettyJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/common.ps1')

function Convert-ToObjectArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Convert-ToRowArray {
    param($Value)

    $items = @(Convert-ToObjectArray -Value $Value)
    if ($items.Count -eq 0) {
        return @()
    }

    $first = $items[0]
    if ($first -is [System.Array]) {
        return @($items)
    }

    return ,@($items)
}

function New-DetailRecordObject {
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
    $detailFields = $schema.Tables.Detail.FieldIds
    $rowValues = [object[]]@($Row)

    if ($rowValues.Count -eq 0) {
        throw "Empty row received for record $RecordId."
    }

    $dateText = Convert-CellValueToText -Value $rowValues[$IndexMap[$detailFields.Date]]
    $dateKey = Convert-CellValueToText -Value $rowValues[$IndexMap[$detailFields.DateKey]]
    $start = Convert-CellValueToText -Value $rowValues[$IndexMap[$detailFields.StartTime]]
    $end = Convert-CellValueToText -Value $rowValues[$IndexMap[$detailFields.EndTime]]
    $task = Convert-CellValueToText -Value $rowValues[$IndexMap[$detailFields.TaskName]]
    $batchId = Convert-CellValueToText -Value $rowValues[$IndexMap[$detailFields.BatchId]]
    $sourceType = Convert-CellValueToText -Value $rowValues[$IndexMap[$detailFields.SourceType]]
    $validationStatus = Convert-CellValueToText -Value $rowValues[$IndexMap[$detailFields.ValidationStatus]]
    $categoryValues = @(Convert-CellValueToStringArray -Value $rowValues[$IndexMap[$detailFields.Category]])
    $category = if ($categoryValues.Count -gt 0) { $categoryValues[0] } else { $null }

    $derivedDateKey = Convert-DateTextToDateKey -DateText $dateText
    $timestamp = $null
    if (-not [string]::IsNullOrWhiteSpace($dateText)) {
        try {
            $timestamp = Convert-DateTextToUnixMilliseconds -DateText $dateText
        } catch {
            $timestamp = $null
        }
    }

    $matchedBy = $null
    if ($dateKey -eq $TargetDate) {
        $matchedBy = 'date_key'
    } elseif ([string]::IsNullOrWhiteSpace($dateKey) -and $derivedDateKey -eq $TargetDate) {
        $matchedBy = 'date_text_fallback'
    } elseif ($derivedDateKey -eq $TargetDate) {
        $matchedBy = 'date_text_mismatch'
    }

    $issues = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($dateKey) -and -not [string]::IsNullOrWhiteSpace($derivedDateKey) -and $dateKey -ne $derivedDateKey) {
        $issues.Add([pscustomobject]@{
            type = 'timestamp_mismatch'
            recordId = $RecordId
            expectedDateKey = $derivedDateKey
            actualDateKey = $dateKey
        })
    }

    $hours = $null
    if (-not [string]::IsNullOrWhiteSpace($start) -and -not [string]::IsNullOrWhiteSpace($end)) {
        try {
            $hours = Get-HoursBetween -Start $start -End $end
        } catch {
            $issues.Add([pscustomobject]@{
                type = 'invalid_time_range'
                recordId = $RecordId
                start = $start
                end = $end
            })
        }
    }

    $rangeKey = $null
    if (-not [string]::IsNullOrWhiteSpace($start) -and -not [string]::IsNullOrWhiteSpace($end)) {
        $rangeKey = "$start-$end"
    }

    $record = [pscustomobject]@{}
    $issueArray = [System.Collections.ArrayList]::new()
    foreach ($issue in $issues) {
        [void]$issueArray.Add($issue)
    }

    $record | Add-Member -NotePropertyName 'recordId' -NotePropertyValue $RecordId
    $record | Add-Member -NotePropertyName 'targetDate' -NotePropertyValue $TargetDate
    $record | Add-Member -NotePropertyName 'matchedBy' -NotePropertyValue $matchedBy
    $record | Add-Member -NotePropertyName 'dateKey' -NotePropertyValue $dateKey
    $record | Add-Member -NotePropertyName 'derivedDateKey' -NotePropertyValue $derivedDateKey
    $record | Add-Member -NotePropertyName 'timestamp' -NotePropertyValue $timestamp
    $record | Add-Member -NotePropertyName 'dateText' -NotePropertyValue $dateText
    $record | Add-Member -NotePropertyName 'start' -NotePropertyValue $start
    $record | Add-Member -NotePropertyName 'end' -NotePropertyValue $end
    $record | Add-Member -NotePropertyName 'task' -NotePropertyValue $task
    $record | Add-Member -NotePropertyName 'category' -NotePropertyValue $category
    $record | Add-Member -NotePropertyName 'batchId' -NotePropertyValue $batchId
    $record | Add-Member -NotePropertyName 'sourceType' -NotePropertyValue $sourceType
    $record | Add-Member -NotePropertyName 'validationStatus' -NotePropertyValue $validationStatus
    $record | Add-Member -NotePropertyName 'hours' -NotePropertyValue $hours
    $record | Add-Member -NotePropertyName 'rangeKey' -NotePropertyValue $rangeKey
    $record | Add-Member -NotePropertyName 'issues' -NotePropertyValue $issueArray

    return $record
}

$schema = Get-TimeTrackerSchema
$detailTableId = $schema.Tables.Detail.Id
$detailFields = $schema.Tables.Detail.FieldIds

$selectedFieldIds = @(
    $detailFields.Date,
    $detailFields.DateKey,
    $detailFields.EndTime,
    $detailFields.StartTime,
    $detailFields.BatchId,
    $detailFields.Category,
    $detailFields.SourceType,
    $detailFields.TaskName,
    $detailFields.ValidationStatus
)

$offset = 0
$pagesFetched = 0
$hasMore = $true
$allRecords = New-Object System.Collections.Generic.List[object]
$allIssues = New-Object System.Collections.Generic.List[object]
$lastFieldScope = $null
$lastRecordScope = $null

while ($hasMore) {
    $response = Invoke-TimeTrackerRecordList -TableId $detailTableId -FieldIds $selectedFieldIds -Offset $offset -Limit $PageSize
    $pagesFetched += 1

    $payload = $response.data
    $lastFieldScope = $payload.query_context.field_scope
    $lastRecordScope = $payload.query_context.record_scope

    $rows = @(Convert-ToRowArray -Value $payload.data)
    $recordIds = @(Convert-ToObjectArray -Value $payload.record_id_list)
    $indexMap = New-FieldIndexMap -FieldIds @(Convert-ToObjectArray -Value $payload.field_id_list)

    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($i -ge $recordIds.Count) {
            throw "record_id_list shorter than data rows at offset $offset."
        }

        $row = @($rows[$i])
        $record = New-DetailRecordObject -RecordId ([string]$recordIds[$i]) -Row $row -IndexMap $indexMap -TargetDate $Date
        if ($record.matchedBy) {
            $allRecords.Add($record)
        }

        foreach ($issue in $record.issues) {
            if ($record.matchedBy) {
                $allIssues.Add($issue)
            }
        }
    }

    $hasMore = [bool]$payload.has_more
    $offset += $rows.Count

    if ($rows.Count -eq 0) {
        break
    }
}

$recordArray = if ($allRecords.Count -gt 0) { $allRecords.ToArray() } else { @() }
$sortedRecords = $recordArray | Sort-Object `
    @{ Expression = { if ($_.start) { $_.start } else { '99:99' } } }, `
    @{ Expression = { if ($_.end) { $_.end } else { '99:99' } } }, `
    @{ Expression = { if ($_.task) { $_.task } else { '' } } }

$resultIssues = [System.Collections.ArrayList]::new()
foreach ($issue in $allIssues) {
    [void]$resultIssues.Add($issue)
}

$result = [pscustomobject]@{
    date = $Date
    query = [pscustomobject]@{
        preferredAnchor = 'date_key'
        fallbackAnchor = 'date_text'
    }
    table = [pscustomobject]@{
        id = $detailTableId
        key = $schema.Tables.Detail.Key
    }
    pagination = [pscustomobject]@{
        pageSize = $PageSize
        pagesFetched = $pagesFetched
        rowsFetched = $offset
        hasMore = $hasMore
        fieldScope = $lastFieldScope
        recordScope = $lastRecordScope
    }
    recordCount = @($sortedRecords).Count
    records = @($sortedRecords)
    issues = $resultIssues
}

if ($PrettyJson) {
    $result | ConvertTo-Json -Depth 8
} else {
    $result | ConvertTo-Json -Depth 8 -Compress
}
