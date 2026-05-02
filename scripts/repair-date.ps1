param(
    [string]$FromDateKey,

    [string[]]$RecordIds,

    [Parameter(Mandatory = $true)]
    [string]$ToDateKey,

    [switch]$WriteBack,

    [switch]$SkipRebuild,

    [string]$SourceType = 'manual-repair',

    [string]$RevisionNote,

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

function New-RepairCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RecordId,

        [Parameter(Mandatory = $true)]
        $Row,

        [Parameter(Mandatory = $true)]
        [hashtable]$IndexMap
    )

    $schema = Get-TimeTrackerSchema
    $detail = $schema.Tables.Detail.FieldIds
    $rowValues = [object[]]@($Row)

    $dateText = Convert-CellValueToText -Value $rowValues[$IndexMap[$detail.Date]]
    $dateKey = Convert-CellValueToText -Value $rowValues[$IndexMap[$detail.DateKey]]
    $start = Convert-CellValueToText -Value $rowValues[$IndexMap[$detail.StartTime]]
    $end = Convert-CellValueToText -Value $rowValues[$IndexMap[$detail.EndTime]]
    $task = Convert-CellValueToText -Value $rowValues[$IndexMap[$detail.TaskName]]
    $batchId = Convert-CellValueToText -Value $rowValues[$IndexMap[$detail.BatchId]]
    $sourceType = Convert-CellValueToText -Value $rowValues[$IndexMap[$detail.SourceType]]
    $validationStatus = Convert-CellValueToText -Value $rowValues[$IndexMap[$detail.ValidationStatus]]
    $categoryValues = @(Convert-CellValueToStringArray -Value $rowValues[$IndexMap[$detail.Category]])
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

    $candidate = [pscustomobject]@{}
    $candidate | Add-Member -NotePropertyName 'recordId' -NotePropertyValue $RecordId
    $candidate | Add-Member -NotePropertyName 'dateText' -NotePropertyValue $dateText
    $candidate | Add-Member -NotePropertyName 'dateKey' -NotePropertyValue $dateKey
    $candidate | Add-Member -NotePropertyName 'derivedDateKey' -NotePropertyValue $derivedDateKey
    $candidate | Add-Member -NotePropertyName 'timestamp' -NotePropertyValue $timestamp
    $candidate | Add-Member -NotePropertyName 'start' -NotePropertyValue $start
    $candidate | Add-Member -NotePropertyName 'end' -NotePropertyValue $end
    $candidate | Add-Member -NotePropertyName 'task' -NotePropertyValue $task
    $candidate | Add-Member -NotePropertyName 'category' -NotePropertyValue $category
    $candidate | Add-Member -NotePropertyName 'batchId' -NotePropertyValue $batchId
    $candidate | Add-Member -NotePropertyName 'sourceType' -NotePropertyValue $sourceType
    $candidate | Add-Member -NotePropertyName 'validationStatus' -NotePropertyValue $validationStatus
    return $candidate
}

function Get-AllDetailCandidates {
    $schema = Get-TimeTrackerSchema
    $detailTableId = $schema.Tables.Detail.Id
    $detail = $schema.Tables.Detail.FieldIds
    $selectedFieldIds = @(
        $detail.Date,
        $detail.DateKey,
        $detail.EndTime,
        $detail.StartTime,
        $detail.BatchId,
        $detail.Category,
        $detail.SourceType,
        $detail.TaskName,
        $detail.ValidationStatus
    )

    $offset = 0
    $hasMore = $true
    $records = [System.Collections.ArrayList]::new()

    while ($hasMore) {
        $response = Invoke-TimeTrackerRecordList -TableId $detailTableId -FieldIds $selectedFieldIds -Offset $offset -Limit 200
        $payload = $response.data
        $rows = @(Convert-ToRowArray -Value $payload.data)
        $recordIdsLocal = @(Convert-ToObjectArray -Value $payload.record_id_list)
        $indexMap = New-FieldIndexMap -FieldIds @(Convert-ToObjectArray -Value $payload.field_id_list)

        for ($i = 0; $i -lt $rows.Count; $i++) {
            $candidate = New-RepairCandidate -RecordId ([string]$recordIdsLocal[$i]) -Row $rows[$i] -IndexMap $indexMap
            [void]$records.Add($candidate)
        }

        $hasMore = [bool]$payload.has_more
        $offset += $rows.Count
        if ($rows.Count -eq 0) { break }
    }

    return $records
}

function Get-CandidatesByDate {
    param([string]$DateKey)

    $getDayPath = Join-Path $PSScriptRoot 'get-day-records.ps1'
    $dayData = Invoke-LocalJsonScript -ScriptPath $getDayPath -Arguments @('-Date', $DateKey)
    return [System.Collections.ArrayList]@(Convert-ToObjectArray -Value $dayData.records)
}

function Split-IntoChunks {
    param(
        [string[]]$Items,
        [int]$Size = 200
    )

    $chunks = [System.Collections.ArrayList]::new()
    for ($i = 0; $i -lt $Items.Count; $i += $Size) {
        $upper = [Math]::Min($i + $Size - 1, $Items.Count - 1)
        $chunk = $Items[$i..$upper]
        [void]$chunks.Add(@($chunk))
    }

    return $chunks
}

function Get-RepairPreviewItem {
    param(
        [Parameter(Mandatory = $true)]
        $Candidate,

        [Parameter(Mandatory = $true)]
        [string]$TargetDateKey,

        [Parameter(Mandatory = $true)]
        [string]$TargetDateText
    )

    $sourceDateKey = if (-not [string]::IsNullOrWhiteSpace($Candidate.dateKey)) { $Candidate.dateKey } else { $Candidate.derivedDateKey }

    $item = [pscustomobject]@{}
    $item | Add-Member -NotePropertyName 'recordId' -NotePropertyValue $Candidate.recordId
    $item | Add-Member -NotePropertyName 'fromDateKey' -NotePropertyValue $sourceDateKey
    $item | Add-Member -NotePropertyName 'fromDateText' -NotePropertyValue $Candidate.dateText
    $item | Add-Member -NotePropertyName 'toDateKey' -NotePropertyValue $TargetDateKey
    $item | Add-Member -NotePropertyName 'toDateText' -NotePropertyValue $TargetDateText
    $item | Add-Member -NotePropertyName 'task' -NotePropertyValue $Candidate.task
    $item | Add-Member -NotePropertyName 'start' -NotePropertyValue $Candidate.start
    $item | Add-Member -NotePropertyName 'end' -NotePropertyValue $Candidate.end
    $item | Add-Member -NotePropertyName 'category' -NotePropertyValue $Candidate.category
    $item | Add-Member -NotePropertyName 'sourceTypeBefore' -NotePropertyValue $Candidate.sourceType
    $item | Add-Member -NotePropertyName 'sourceTypeAfter' -NotePropertyValue $SourceType
    $item | Add-Member -NotePropertyName 'isNoOpDate' -NotePropertyValue ($sourceDateKey -eq $TargetDateKey)
    return $item
}

if ([string]::IsNullOrWhiteSpace($FromDateKey) -and ($null -eq $RecordIds -or $RecordIds.Count -eq 0)) {
    throw 'Either -FromDateKey or -RecordIds must be provided.'
}

if (-not [string]::IsNullOrWhiteSpace($FromDateKey) -and ($null -ne $RecordIds -and $RecordIds.Count -gt 0)) {
    throw 'Use either -FromDateKey or -RecordIds, not both.'
}

$null = Get-DateKeyTimestamp -DateKey $ToDateKey
$targetDateText = Get-DateKeyDateTimeText -DateKey $ToDateKey
$schema = Get-TimeTrackerSchema
$detailTableId = $schema.Tables.Detail.Id
$detail = $schema.Tables.Detail.FieldIds

$mode = if (-not [string]::IsNullOrWhiteSpace($FromDateKey)) { 'from_date_key' } else { 'record_ids' }
$candidates = $null
$missingRecordIds = @()

if ($mode -eq 'from_date_key') {
    $candidates = Get-CandidatesByDate -DateKey $FromDateKey
} else {
    $allCandidates = @(Get-AllDetailCandidates)
    $recordIdSet = @{}
    foreach ($recordId in $RecordIds) {
        if (-not [string]::IsNullOrWhiteSpace($recordId)) {
            $recordIdSet[$recordId] = $true
        }
    }

    $matches = [System.Collections.ArrayList]::new()
    foreach ($candidate in $allCandidates) {
        if ($recordIdSet.ContainsKey($candidate.recordId)) {
            [void]$matches.Add($candidate)
        }
    }

    $foundIds = @($matches | ForEach-Object { $_.recordId })
    foreach ($recordId in $recordIdSet.Keys) {
        if ($foundIds -notcontains $recordId) {
            $missingRecordIds += $recordId
        }
    }

    $candidates = $matches
}

$candidateArray = @(Convert-ToObjectArray -Value $candidates)
if ($candidateArray.Count -eq 0) {
    throw 'No repair candidates found.'
}

$preview = [System.Collections.ArrayList]::new()
$affectedDateSet = @{}
$recordIdList = New-Object System.Collections.Generic.List[string]
foreach ($candidate in $candidateArray) {
    [void]$recordIdList.Add($candidate.recordId)

    $sourceDateKey = if (-not [string]::IsNullOrWhiteSpace($candidate.dateKey)) { $candidate.dateKey } else { $candidate.derivedDateKey }
    if (-not [string]::IsNullOrWhiteSpace($sourceDateKey)) {
        $affectedDateSet[$sourceDateKey] = $true
    }

    [void]$preview.Add((Get-RepairPreviewItem -Candidate $candidate -TargetDateKey $ToDateKey -TargetDateText $targetDateText))
}
$affectedDateSet[$ToDateKey] = $true
$affectedDates = @($affectedDateSet.Keys | Sort-Object)

$patch = @{}
$patch[$detail.Date] = $targetDateText
$patch[$detail.DateKey] = $ToDateKey
$patch[$detail.SourceType] = $SourceType
$patch[$detail.ValidationStatus] = 'ok'

$supportsRevisionNote = -not ($schema.Tables.Detail.MissingFields -contains 'RevisionNote')
if ($supportsRevisionNote -and -not [string]::IsNullOrWhiteSpace($RevisionNote)) {
    # Reserved for future field-map update once RevisionNote exists in Feishu and has a stable field id.
}

$writeInfo = [pscustomobject]@{
    requested = [bool]$WriteBack
    applied = $false
    tableId = $detailTableId
    recordCount = $recordIdList.Count
    chunkCount = [Math]::Ceiling($recordIdList.Count / 200.0)
    patch = $patch
    affectedDates = $affectedDates
    rebuildTriggered = $false
    rebuildSkipped = [bool]$SkipRebuild
}

if ($WriteBack) {
    $chunks = Split-IntoChunks -Items $recordIdList.ToArray()
    $responses = [System.Collections.ArrayList]::new()

    foreach ($chunk in $chunks) {
        $response = Invoke-TimeTrackerRecordBatchUpdate -TableId $detailTableId -RecordIds $chunk -Patch $patch
        [void]$responses.Add($response)
    }

    $writeInfo.applied = $true
    $writeInfo | Add-Member -NotePropertyName 'responses' -NotePropertyValue @($responses)

    if (-not $SkipRebuild) {
        $rebuildPath = Join-Path $PSScriptRoot 'rebuild-day.ps1'
        $rebuildResults = [System.Collections.ArrayList]::new()

        foreach ($repairDate in $affectedDates) {
            try {
                $rebuildResult = Invoke-LocalJsonScript -ScriptPath $rebuildPath -Arguments @('-Date', $repairDate, '-WriteBack', '-AsJson', '-Source', 'manual-rebuild')
                [void]$rebuildResults.Add([pscustomobject]@{
                    date = $repairDate
                    ok = $true
                    result = $rebuildResult
                })
            } catch {
                [void]$rebuildResults.Add([pscustomobject]@{
                    date = $repairDate
                    ok = $false
                    error = "$_"
                })
            }
        }

        $writeInfo.rebuildTriggered = $true
        $writeInfo | Add-Member -NotePropertyName 'rebuildResults' -NotePropertyValue @($rebuildResults)
    }
}

$result = [pscustomobject]@{
    mode = $mode
    fromDateKey = $FromDateKey
    toDateKey = $ToDateKey
    toDateText = $targetDateText
    sourceType = $SourceType
    revisionNote = $RevisionNote
    revisionNoteFieldAvailable = $supportsRevisionNote
    recordCount = $candidateArray.Count
    missingRecordIds = $missingRecordIds
    affectedDates = $affectedDates
    preview = @($preview)
    writeBack = $writeInfo
}

if ($PrettyJson) {
    $result | ConvertTo-Json -Depth 8
} elseif ($AsJson) {
    $result | ConvertTo-Json -Depth 8 -Compress
} else {
    Write-Host "Mode: $mode"
    Write-Host "Target date: $ToDateKey"
    Write-Host "Record count: $($candidateArray.Count)"
    Write-Host "Affected dates: $($affectedDates -join ', ')"
    if ($missingRecordIds.Count -gt 0) {
        Write-Host "Missing record ids: $($missingRecordIds -join ', ')"
    }

    foreach ($item in $preview) {
        Write-Host "- [$($item.recordId)] $($item.fromDateKey) -> $($item.toDateKey) :: $($item.start)-$($item.end) $($item.task)"
    }

    if ($WriteBack) {
        if ($writeInfo.applied) {
            Write-Host "WriteBack: completed"
        } else {
            Write-Host "WriteBack: not applied"
        }
    } else {
        Write-Host "Preview only. Add -WriteBack to apply changes."
    }
}
