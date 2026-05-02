# Time Tracker Skill runtime entrypoint
# Usage examples:
#   .\run.ps1 -CurrentHour 10 -Phase ask
#   .\run.ps1 -CurrentHour 10 -Phase store -UserInput "1 hour coding, 1 hour meeting"
#   .\run.ps1 -CurrentHour 22 -Phase feeling
#   .\run.ps1 -CurrentHour 22 -Phase summary -UserInput "Feeling good today" -StatusValue 82
#   .\run.ps1 -CurrentHour 24 -Phase summary

param(
    [int]$CurrentHour = (Get-Date).Hour,
    [string]$UserInput = '',
    [ValidateSet('ask', 'store', 'feeling', 'summary')]
    [string]$Phase = 'ask',
    [Nullable[double]]$StatusValue = $null,
    [switch]$WriteBackDetails,
    [switch]$WriteBackStats,
    [switch]$AllowBlockingIssues
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Prefer UTF-8 output across terminals.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
[Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('zh-CN')

. (Join-Path $PSScriptRoot 'scripts/lib/common.ps1')

function U {
    param([string]$Text)

    return [regex]::Unescape($Text)
}

function Resolve-HeartbeatHour {
    param([int]$Hour)

    if ($Hour -eq 0) {
        return 24
    }

    return $Hour
}

function Get-RunContext {
    param([int]$RequestedHour)

    $effectiveHour = Resolve-HeartbeatHour -Hour $RequestedHour
    $now = Get-Date
    $targetDate = if ($effectiveHour -eq 24) {
        $now.Date.AddDays(-1)
    } else {
        $now.Date
    }

    $targetDateKey = $targetDate.ToString('yyyy-MM-dd')
    $slotEndHour = $effectiveHour
    $slotStartHour = $slotEndHour - 2

    return [pscustomobject]@{
        requestedHour = $RequestedHour
        effectiveHour = $effectiveHour
        targetDate = $targetDate
        targetDateKey = $targetDateKey
        timestamp = Get-DateKeyTimestamp -DateKey $targetDateKey
        dateText = Get-DateKeyDateTimeText -DateKey $targetDateKey
        slotStartHour = $slotStartHour
        slotEndHour = $slotEndHour
        slotStartText = ('{0:00}:00' -f $slotStartHour)
        slotEndText = ('{0:00}:00' -f $slotEndHour)
        batchId = '{0}-slot-{1:00}-{2:00}' -f $targetDateKey, $slotStartHour, $slotEndHour
        is22Task = ($effectiveHour -eq 22)
        is24Task = ($effectiveHour -eq 24)
        isSummaryTask = ($effectiveHour -in @(22, 24))
    }
}

function Get-CategoryLabels {
    return Get-TimeTrackerCategoryNames
}

function Get-ClassificationCategory {
    param([string]$TaskText)

    $categories = Get-CategoryLabels
    if ($TaskText -match '\u5de5\u4f5c|\u4e0a\u73ed|\u5f00\u4f1a|\u4f1a\u8bae|\u62a5\u544a|\u90ae\u4ef6|\u4e0a\u4f20|\u8fd0\u8425|\u5236\u4f5c|\u9879\u76ee|\u5f00\u53d1|\u6392\u7248|\u8c03\u8bd5|\u4fee\u590d|\u5199\u4ee3\u7801|\u4ea7\u54c1|\u9700\u6c42') {
        return $categories.Work
    }

    if ($TaskText -match '\u5b66\u4e60|\u770b\u4e66|\u542c\u8bfe|\u57f9\u8bad|\u6280\u80fd|\u8bfe\u7a0b|\u590d\u76d8|\u7814\u7a76|\u9605\u8bfb') {
        return $categories.Study
    }

    return $categories.Fun
}

function Parse-UserInput {
    param(
        [string]$InputText,
        [datetime]$SlotStart
    )

    $records = [System.Collections.ArrayList]::new()
    $pattern = '(?=(?:\d+(?:\.\d+)?\s*\u5c0f\u65f6|\d+\s*\u5206\u949f))\s*(?:(?<hours>\d+(?:\.\d+)?)\s*\u5c0f\u65f6)?\s*(?:(?<minutes>\d+)\s*\u5206\u949f)?\s*(?<task>[^\uff0c,\uff1b;]+)'
    $matches = [regex]::Matches($InputText, $pattern)
    foreach ($match in $matches) {
        $hoursText = $match.Groups['hours'].Value
        $minutesText = $match.Groups['minutes'].Value
        $taskName = $match.Groups['task'].Value.Trim()
        $durationMinutes = 0

        if (-not [string]::IsNullOrWhiteSpace($hoursText)) {
            $durationMinutes += [int]([double]$hoursText * 60)
        }

        if (-not [string]::IsNullOrWhiteSpace($minutesText)) {
            $durationMinutes += [int]$minutesText
        }

        if ($durationMinutes -le 0 -or [string]::IsNullOrWhiteSpace($taskName)) {
            continue
        }

        [void]$records.Add([pscustomobject]@{
            taskName = $taskName
            duration = $durationMinutes
            category = Get-ClassificationCategory -TaskText $taskName
        })
    }

    if ($records.Count -eq 0) {
        [void]$records.Add([pscustomobject]@{
            taskName = $InputText
            duration = 120
            category = (Get-CategoryLabels).Fun
        })
    }

    return $records
}

function Get-DetailConflictCheck {
    param(
        $Context,
        [object[]]$PlannedRecords
    )

    $getDayRecordsPath = Join-Path $PSScriptRoot 'scripts/get-day-records.ps1'
    $dayData = Invoke-LocalJsonScript -ScriptPath $getDayRecordsPath -Arguments @('-Date', $Context.targetDateKey)
    $existingRecords = @($dayData.records)
    $issues = [System.Collections.ArrayList]::new()

    foreach ($planned in @($PlannedRecords)) {
        if ([string]::IsNullOrWhiteSpace($planned.startTime) -or [string]::IsNullOrWhiteSpace($planned.endTime)) {
            continue
        }

        $plannedStart = Convert-TimeTextToTimeSpan -TimeText $planned.startTime
        $plannedEnd = Convert-TimeTextToTimeSpan -TimeText $planned.endTime

        foreach ($existing in @($existingRecords)) {
            if ([string]::IsNullOrWhiteSpace($existing.start) -or [string]::IsNullOrWhiteSpace($existing.end)) {
                continue
            }

            $existingStart = Convert-TimeTextToTimeSpan -TimeText $existing.start
            $existingEnd = Convert-TimeTextToTimeSpan -TimeText $existing.end
            $sameExactRecord = (
                $planned.startTime -eq $existing.start -and
                $planned.endTime -eq $existing.end -and
                $planned.taskName -eq $existing.task -and
                $planned.category -eq $existing.category
            )

            if ($sameExactRecord) {
                [void]$issues.Add([pscustomobject]@{
                    type = 'duplicate'
                    existingRecordId = $existing.recordId
                    existingRange = $existing.rangeKey
                    plannedRange = "$($planned.startTime)-$($planned.endTime)"
                    task = $planned.taskName
                    category = $planned.category
                })
                continue
            }

            if (($plannedStart -lt $existingEnd) -and ($plannedEnd -gt $existingStart)) {
                [void]$issues.Add([pscustomobject]@{
                    type = 'overlap'
                    existingRecordId = $existing.recordId
                    existingRange = $existing.rangeKey
                    existingTask = $existing.task
                    plannedRange = "$($planned.startTime)-$($planned.endTime)"
                    plannedTask = $planned.taskName
                })
            }
        }
    }

    return [pscustomobject]@{
        checked = $true
        targetDateKey = $Context.targetDateKey
        existingRecordCount = @($existingRecords).Count
        conflictCount = @($issues).Count
        hasBlockingConflicts = (@($issues).Count -gt 0)
        issues = @($issues)
    }
}

function Get-StructuredRecords {
    param(
        [string]$InputText,
        $Context
    )

    $slotStart = $Context.targetDate.AddHours($Context.slotStartHour)
    $parsedRecords = Parse-UserInput -InputText $InputText -SlotStart $slotStart
    $totalMinutes = @($parsedRecords | Measure-Object duration -Sum).Sum

    if ($totalMinutes -lt 120) {
        [void]$parsedRecords.Add([pscustomobject]@{
            taskName = (U '\u5a31\u4e50/\u4f11\u606f')
            duration = (120 - $totalMinutes)
            category = (Get-CategoryLabels).Fun
        })
    }

    $currentTime = $slotStart
    $schema = Get-TimeTrackerSchema
    $detailFields = $schema.Tables.Detail.FieldIds
    $records = [System.Collections.ArrayList]::new()

    foreach ($record in $parsedRecords) {
        $recordStart = $currentTime
        $recordEnd = $currentTime.AddMinutes($record.duration)
        $fields = @{}
        $fields[$detailFields.Date] = $Context.dateText
        $fields[$detailFields.DateKey] = $Context.targetDateKey
        $fields[$detailFields.StartTime] = $recordStart.ToString('HH:mm')
        $fields[$detailFields.EndTime] = $recordEnd.ToString('HH:mm')
        $fields[$detailFields.TaskName] = $record.taskName
        $fields[$detailFields.Category] = $record.category
        $fields[$detailFields.BatchId] = $Context.batchId
        $fields[$detailFields.SourceType] = 'heartbeat'
        $fields[$detailFields.ValidationStatus] = 'ok'

        [void]$records.Add([pscustomobject]@{
            taskName = $record.taskName
            category = $record.category
            startTime = $recordStart.ToString('HH:mm')
            endTime = $recordEnd.ToString('HH:mm')
            durationMinutes = $record.duration
            dateKey = $Context.targetDateKey
            timestamp = $Context.timestamp
            dateText = $Context.dateText
            batchId = $Context.batchId
            sourceType = 'heartbeat'
            validationStatus = 'ok'
            fields = $fields
        })

        $currentTime = $recordEnd
    }

    return $records
}

function Get-DetailWritePlan {
    param([object[]]$Records)

    $schema = Get-TimeTrackerSchema
    $detailFieldIds = @($schema.Tables.Detail.FieldIds.PSObject.Properties | ForEach-Object { [string]$_.Value })
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($record in @($Records)) {
        $row = New-Object object[] $detailFieldIds.Count
        for ($i = 0; $i -lt $detailFieldIds.Count; $i++) {
            $fieldId = $detailFieldIds[$i]
            $value = $null
            if ($null -ne $record -and $null -ne $record.fields -and $record.fields.ContainsKey($fieldId)) {
                $value = $record.fields[$fieldId]
            }

            $row[$i] = $value
        }

        [void]$rows.Add($row)
    }

    $plainRows = @($rows | ForEach-Object { ,([object[]]$_) })
    $rowJsonParts = New-Object System.Collections.Generic.List[string]
    foreach ($plainRow in $plainRows) {
        [void]$rowJsonParts.Add(([object[]]$plainRow | ConvertTo-Json -Depth 10 -Compress))
    }
    $rowsJson = "[" + ($rowJsonParts -join ",") + "]"

    return [pscustomobject]@{
        tableId = $schema.Tables.Detail.Id
        fieldIds = $detailFieldIds
        rows = $plainRows
        rowsJson = $rowsJson
        rowCount = $plainRows.Count
    }
}


function Invoke-RebuildForRun {
    param(
        $Context,
        [string]$FeelingText,
        [Nullable[double]]$ComputedStatusValue
    )

    $rebuildPath = Join-Path $PSScriptRoot 'scripts/rebuild-day.ps1'
    $source = if ($Context.is22Task) { 'auto-22' } elseif ($Context.is24Task) { 'auto-24' } else { 'manual-rebuild' }
    $arguments = @(
        '-Date', $Context.targetDateKey,
        '-AsJson',
        '-Source', $source
    )

    if (-not [string]::IsNullOrWhiteSpace($FeelingText)) {
        $arguments += @('-Feeling', $FeelingText)
    }

    if ($PSBoundParameters.ContainsKey('ComputedStatusValue') -and $null -ne $ComputedStatusValue) {
        $arguments += @('-StatusValue', [string]$ComputedStatusValue)
    }

    if ($WriteBackStats) {
        $arguments += '-WriteBack'
    }

    if ($AllowBlockingIssues) {
        $arguments += '-AllowBlockingIssues'
    }

    return Invoke-LocalJsonScript -ScriptPath $rebuildPath -Arguments $arguments
}

$context = Get-RunContext -RequestedHour $CurrentHour

Write-Host "=== Time Tracker Skill ==="
Write-Host "Current hour: $($context.effectiveHour)"
Write-Host "Phase: $Phase"
Write-Host "Target date: $($context.targetDateKey)"
Write-Host "Slot: $($context.slotStartText) - $($context.slotEndText)"
Write-Host ''

if ($Phase -eq 'ask') {
    $message = if ($context.is22Task) {
        "20:00-22:00 $(U '\u4f60\u505a\u4e86\u4ec0\u4e48\uff1f')"
    } elseif ($context.is24Task) {
        "22:00-24:00 $(U '\u4f60\u505a\u4e86\u4ec0\u4e48\uff1f')"
    } else {
        "$((U '\u8bf7\u544a\u8bc9\u6211\u8fc7\u53bb2\u5c0f\u65f6')) ($($context.slotStartText) - $($context.slotEndText)) $((U '\u4f60\u505a\u4e86\u4ec0\u4e48\uff1f'))"
    }

    $nextPhase = if ($context.is22Task) { 'store' } elseif ($context.is24Task) { 'store' } else { $null }

    @{
        action = 'ask'
        phase = 'time'
        currentHour = $context.effectiveHour
        targetDateKey = $context.targetDateKey
        timestamp = $context.timestamp
        dateText = $context.dateText
        slotStart = $context.slotStartText
        slotEnd = $context.slotEndText
        batchId = $context.batchId
        message = $message
        isSummaryTask = $context.isSummaryTask
        needsFollowUp = $context.isSummaryTask
        nextPhase = $nextPhase
    } | ConvertTo-Json -Depth 8 -Compress

    exit 0
}

if ($Phase -eq 'store') {
    if ($context.is24Task -and [string]::IsNullOrWhiteSpace($UserInput)) {
        @{
            action = 'noop'
            phase = 'time'
            currentHour = $context.effectiveHour
            targetDateKey = $context.targetDateKey
            reason = 'empty_input_for_24_slot'
            shouldWriteRecords = $false
            needsFollowUp = $false
        } | ConvertTo-Json -Depth 8 -Compress

        exit 0
    }

    $records = Get-StructuredRecords -InputText $UserInput -Context $context
    $detailConflictCheck = Get-DetailConflictCheck -Context $context -PlannedRecords $records
    $detailWritePlan = Get-DetailWritePlan -Records $records
    Write-Host 'Structured records:'
    foreach ($record in $records) {
        Write-Host "  [$($record.startTime) - $($record.endTime)] $($record.taskName) [$($record.category)]"
    }

    $nextPhase = if ($context.is22Task) {
        'feeling'
    } elseif ($context.is24Task) {
        'summary'
    } else {
        $null
    }

    if ($detailConflictCheck.hasBlockingConflicts) {
        $nextPhase = $null
    }

    $detailWriteBack = [ordered]@{
        requested = [bool]$WriteBackDetails
        completed = $false
        blocked = $false
        reason = $null
        tableId = $detailWritePlan.tableId
        fieldIds = @($detailWritePlan.fieldIds)
        rowCount = $detailWritePlan.rowCount
        rows = @($detailWritePlan.rows)
        rowsJson = $detailWritePlan.rowsJson
        recordIds = @()
        response = $null
    }

    if ($WriteBackDetails) {
        if ($detailConflictCheck.hasBlockingConflicts) {
            $detailWriteBack.blocked = $true
            $detailWriteBack.reason = 'prewrite_conflicts_detected'
        } else {
            $writeResponse = Invoke-TimeTrackerRecordBatchCreate -TableId $detailWritePlan.tableId -FieldIds $detailWritePlan.fieldIds -RowsJson $detailWritePlan.rowsJson
            $detailWriteBack.completed = $true
            $detailWriteBack.response = $writeResponse

            if ($null -ne $writeResponse.data -and $null -ne $writeResponse.data.record_id_list) {
                $detailWriteBack.recordIds = @($writeResponse.data.record_id_list)
            }
        }
    }

    @{
        action = 'store'
        phase = 'time'
        currentHour = $context.effectiveHour
        targetDateKey = $context.targetDateKey
        timestamp = $context.timestamp
        dateText = $context.dateText
        batchId = $context.batchId
        detailTableId = (Get-TimeTrackerSchema).Tables.Detail.Id
        shouldWriteRecords = ((-not $detailWriteBack.completed) -and (-not $detailConflictCheck.hasBlockingConflicts))
        records = @($records)
        detailConflictCheck = $detailConflictCheck
        detailWriteBack = [pscustomobject]$detailWriteBack
        needsFollowUp = ($context.isSummaryTask -and (-not $detailConflictCheck.hasBlockingConflicts))
        nextPhase = $nextPhase
        autoProceed = ($context.is24Task -and (-not $detailConflictCheck.hasBlockingConflicts))
    } | ConvertTo-Json -Depth 10 -Compress

    exit 0
}

if ($Phase -eq 'feeling') {
    if (-not $context.is22Task) {
        throw 'feeling phase is only valid for the 22:00 task.'
    }

    @{
        action = 'ask'
        phase = 'feeling'
        currentHour = $context.effectiveHour
        targetDateKey = $context.targetDateKey
        timestamp = $context.timestamp
        dateText = $context.dateText
        message = (U '\u4eca\u5929\u6574\u4f53\u72b6\u6001\u5982\u4f55\uff1f\u8bf7\u4e00\u53e5\u8bdd\u63cf\u8ff0\u4f60\u7684\u4f53\u611f')
        needsFollowUp = $true
        nextPhase = 'summary'
    } | ConvertTo-Json -Depth 8 -Compress

    exit 0
}

if ($Phase -eq 'summary') {
    if (-not $context.isSummaryTask) {
        throw 'summary phase is only valid for the 22:00 or 24:00 tasks.'
    }

    $feelingText = if ($context.is22Task) { $UserInput } else { $null }
    $rebuildResult = Invoke-RebuildForRun -Context $context -FeelingText $feelingText -ComputedStatusValue $StatusValue

    @{
        action = 'summary'
        phase = 'summary'
        currentHour = $context.effectiveHour
        targetDateKey = $context.targetDateKey
        timestamp = $context.timestamp
        dateText = $context.dateText
        feeling = $feelingText
        statusValue = $StatusValue
        rebuild = $rebuildResult
        writeBackStatsRequested = [bool]$WriteBackStats
    } | ConvertTo-Json -Depth 10 -Compress

    exit 0
}

throw "Unknown phase: $Phase"
