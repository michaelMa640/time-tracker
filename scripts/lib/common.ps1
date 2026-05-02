Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'field-map.ps1')

function Get-TimeTrackerRoot {
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-TimeTrackerScriptsRoot {
    return (Join-Path (Get-TimeTrackerRoot) 'scripts')
}

function Join-ExistingPath {
    param(
        [string]$BasePath,
        [string]$ChildPath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath) -or [string]::IsNullOrWhiteSpace($ChildPath)) {
        return $null
    }

    $candidate = Join-Path $BasePath $ChildPath
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    return $null
}

function Get-LarkCliPath {
    $override = $env:TIME_TRACKER_LARK_CLI_PATH
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override) {
            return $override
        }

        $command = Get-Command $override -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    foreach ($name in @('lark-cli', 'lark-cli.cmd')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    $workspaceRoot = Get-TimeTrackerRoot
    foreach ($candidate in @(
        (Join-Path $workspaceRoot 'node_modules/.bin/lark-cli'),
        (Join-Path $workspaceRoot 'node_modules/.bin/lark-cli.cmd')
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    foreach ($candidate in @(
        (Join-ExistingPath -BasePath $env:HOMEBREW_PREFIX -ChildPath 'bin/lark-cli'),
        (Join-ExistingPath -BasePath '/opt/homebrew' -ChildPath 'bin/lark-cli'),
        (Join-ExistingPath -BasePath '/usr/local' -ChildPath 'bin/lark-cli'),
        (Join-ExistingPath -BasePath $env:npm_config_prefix -ChildPath 'bin/lark-cli'),
        (Join-ExistingPath -BasePath $env:VOLTA_HOME -ChildPath 'bin/lark-cli'),
        (Join-ExistingPath -BasePath $env:PNPM_HOME -ChildPath 'lark-cli')
    )) {
        if ($candidate) {
            return $candidate
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $fallback = Join-Path $env:APPDATA 'npm/lark-cli.cmd'
        if (Test-Path -LiteralPath $fallback) {
            return $fallback
        }
    }

    throw 'Unable to locate lark-cli or lark-cli.cmd. Install it or set TIME_TRACKER_LARK_CLI_PATH.'
}

function Get-PowerShellExePath {
    $override = $env:TIME_TRACKER_PWSH_PATH
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override) {
            return $override
        }

        $command = Get-Command $override -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    foreach ($name in @('pwsh', 'powershell', 'powershell.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    foreach ($candidate in @(
        (Join-ExistingPath -BasePath $env:HOMEBREW_PREFIX -ChildPath 'bin/pwsh'),
        (Join-ExistingPath -BasePath '/opt/homebrew' -ChildPath 'bin/pwsh'),
        (Join-ExistingPath -BasePath '/usr/local' -ChildPath 'bin/pwsh'),
        '/Applications/PowerShell.app/Contents/MacOS/pwsh'
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw 'Unable to locate pwsh or powershell. Install PowerShell or set TIME_TRACKER_PWSH_PATH.'
}

function Get-PythonExePath {
    $override = $env:TIME_TRACKER_PYTHON_PATH
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override) {
            return $override
        }

        $command = Get-Command $override -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    foreach ($name in @('python3', 'python', 'py')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    throw 'Unable to locate python3 or python. Install Python or set TIME_TRACKER_PYTHON_PATH.'
}

function Invoke-LarkCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $workspaceRoot = Get-TimeTrackerRoot
    $cli = Get-LarkCliPath
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $ErrAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = Push-Location $workspaceRoot -ErrorAction Stop
            $null = & $cli @Arguments 2>$stderrFile >$stdoutFile
        }
        finally {
            $null = Pop-Location -ErrorAction SilentlyContinue
            $ErrorActionPreference = $ErrAction
        }

        $exitCode = $LASTEXITCODE

        $stdoutContent = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
        $stderrContent = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        if ($null -eq $stdoutContent) { $stdoutContent = '' }
        if ($null -eq $stderrContent) { $stderrContent = '' }
        $stdoutContent = $stdoutContent.Trim()
        $stderrContent = $stderrContent.Trim()

        $raw = $stdoutContent

        if ($exitCode -ne 0) {
            throw "lark-cli exited $exitCode : $stderrContent"
        }

        if (-not $raw) {
            throw "lark-cli returned no output."
        }

        $parsed = $raw | ConvertFrom-Json
        if (-not $parsed.ok) {
            $message = if ($parsed.error.message) { $parsed.error.message } else { $raw }
            throw "lark-cli request failed: $message"
        }

        return $parsed
    }
    finally {
        if (Test-Path -LiteralPath $stdoutFile) { Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stderrFile) { Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-LocalJsonScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string[]]$Arguments = @()
    )

    $powershellExe = Get-PowerShellExePath
    $powerShellArguments = @('-NoProfile')
    if ([System.IO.Path]::GetFileName($powershellExe) -like 'powershell*') {
        $powerShellArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $powerShellArguments += @('-File', $ScriptPath)
    $powerShellArguments += $Arguments
    $output = & $powershellExe @powerShellArguments 2>&1
    $raw = ($output | Out-String).Trim()

    if ($LASTEXITCODE -ne 0) {
        if (-not $raw) {
            $raw = "Script failed: $ScriptPath"
        }

        throw $raw
    }

    if (-not $raw) {
        throw "Script returned no output: $ScriptPath"
    }

    return ($raw | ConvertFrom-Json)
}

function Get-DateKeyTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DateKey
    )

    $timestamp = [DateTimeOffset]::ParseExact(
        "${DateKey}T00:00:00+08:00",
        "yyyy-MM-dd\THH:mm:sszzz",
        [System.Globalization.CultureInfo]::InvariantCulture
    ).ToUnixTimeMilliseconds()

    if (-not (Test-DateKeyTimestamp -DateKey $DateKey -Timestamp $timestamp)) {
        throw "Timestamp round-trip validation failed for $DateKey."
    }

    return $timestamp
}

function Test-DateKeyTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DateKey,

        [Parameter(Mandatory = $true)]
        [long]$Timestamp
    )

    $roundTrip = [DateTimeOffset]::FromUnixTimeMilliseconds($Timestamp).
        ToOffset([TimeSpan]::FromHours(8)).
        ToString('yyyy-MM-dd HH:mm:ss')

    return ($roundTrip -eq "${DateKey} 00:00:00")
}

function Convert-UnixMillisecondsToDateKey {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Timestamp
    )

    return [DateTimeOffset]::FromUnixTimeMilliseconds($Timestamp).
        ToOffset([TimeSpan]::FromHours(8)).
        ToString('yyyy-MM-dd')
}

function Get-DateKeyDateTimeText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DateKey
    )

    $timestamp = Get-DateKeyTimestamp -DateKey $DateKey
    return [DateTimeOffset]::FromUnixTimeMilliseconds($timestamp).
        ToOffset([TimeSpan]::FromHours(8)).
        ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-BeijingNow {
    return [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
}

function Get-BeijingNowText {
    return (Get-BeijingNow).ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-RebuildVersion {
    param(
        [string]$Source = 'manual-rebuild'
    )

    $safeSource = if ([string]::IsNullOrWhiteSpace($Source)) { 'rebuild' } else { $Source }
    return "$safeSource-$((Get-BeijingNow).ToString('yyyyMMdd-HHmmss'))"
}

function Get-TimeTrackerCategoryNames {
    $work = -join @([char]0x5DE5, [char]0x4F5C)
    $study = -join @([char]0x5B66, [char]0x4E60)
    $fun = -join @([char]0x5A31, [char]0x4E50)

    return [pscustomobject]@{
        Work = $work
        Study = $study
        Fun = $fun
    }
}

function Convert-DateTextToUnixMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DateText
    )

    $formats = @(
        'yyyy-MM-dd HH:mm:ss',
        'yyyy/MM/dd HH:mm:ss',
        'yyyy-MM-dd',
        'yyyy/MM/dd'
    )

    foreach ($format in $formats) {
        $parsed = [DateTime]::MinValue
        $ok = [DateTime]::TryParseExact(
            $DateText,
            $format,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )

        if ($ok) {
            $normalized = if ($format -in @('yyyy-MM-dd', 'yyyy/MM/dd')) {
                $parsed.ToString('yyyy-MM-dd 00:00:00')
            } else {
                $parsed.ToString('yyyy-MM-dd HH:mm:ss')
            }

            return [DateTimeOffset]::ParseExact(
                "${normalized} +08:00",
                'yyyy-MM-dd HH:mm:ss zzz',
                [System.Globalization.CultureInfo]::InvariantCulture
            ).ToUnixTimeMilliseconds()
        }
    }

    throw "Unsupported date text format: $DateText"
}

function Convert-DateTextToDateKey {
    param([string]$DateText)

    if ([string]::IsNullOrWhiteSpace($DateText)) {
        return $null
    }

    try {
        return Convert-UnixMillisecondsToDateKey -Timestamp (Convert-DateTextToUnixMilliseconds -DateText $DateText)
    } catch {
        return $null
    }
}

function Convert-CellValueToText {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]$Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return $null
        }

        if ($items[0] -is [string]) {
            return [string]$items[0]
        }

        if ($items[0].PSObject.Properties.Name -contains 'text') {
            return [string]$items[0].text
        }
    }

    return [string]$Value
}

function Convert-CellValueToStringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @([string]$Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        $result = New-Object System.Collections.Generic.List[string]

        foreach ($item in $items) {
            $text = Convert-CellValueToText -Value $item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $result.Add($text)
            }
        }

        return @($result.ToArray())
    }

    return @([string]$Value)
}

function Convert-TimeTextToTimeSpan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TimeText
    )

    if ($TimeText -eq '24:00') {
        return [TimeSpan]::FromHours(24)
    }

    return [TimeSpan]::ParseExact(
        $TimeText,
        'hh\:mm',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-HoursBetween {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Start,

        [Parameter(Mandatory = $true)]
        [string]$End
    )

    $startTs = Convert-TimeTextToTimeSpan -TimeText $Start
    $endTs = Convert-TimeTextToTimeSpan -TimeText $End

    # 处理跨天情况：当结束时间为 00:00 且小于开始时间时，视为次日 24:00
    if ($endTs -lt $startTs -and $End -eq '00:00') {
        $endTs = [TimeSpan]::FromHours(24)
    }

    return [math]::Round(($endTs - $startTs).TotalHours, 4)
}

function New-FieldIndexMap {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$FieldIds
    )

    $indexMap = @{}
    for ($i = 0; $i -lt $FieldIds.Count; $i++) {
        $indexMap[$FieldIds[$i]] = $i
    }

    return $indexMap
}

function Invoke-TimeTrackerRecordList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableId,

        [string[]]$FieldIds = @(),

        [int]$Offset = 0,

        [int]$Limit = 200
    )

    if ($Limit -lt 1 -or $Limit -gt 200) {
        throw 'Limit must be between 1 and 200.'
    }

    $schema = Get-TimeTrackerSchema
    $arguments = @(
        'base',
        '+record-list',
        '--base-token', $schema.BaseToken,
        '--table-id', $TableId,
        '--offset', [string]$Offset,
        '--limit', [string]$Limit
    )

    foreach ($fieldId in $FieldIds) {
        $arguments += @('--field-id', $fieldId)
    }

    return Invoke-LarkCliJson -Arguments $arguments
}

function Invoke-TimeTrackerRecordUpsert {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableId,

        [Parameter(Mandatory = $true)]
        [hashtable]$Fields,

        [string]$RecordId
    )

    $schema = Get-TimeTrackerSchema
    $jsonBody = $Fields | ConvertTo-Json -Depth 8 -Compress
    $arguments = @(
        'base',
        '+record-upsert',
        '--base-token', $schema.BaseToken,
        '--table-id', $TableId
    )

    if (-not [string]::IsNullOrWhiteSpace($RecordId)) {
        $arguments += @('--record-id', $RecordId)
    }

    $arguments += @('--json', $jsonBody)
    return Invoke-LarkCliJson -Arguments $arguments
}

function Invoke-TimeTrackerRecordBatchCreate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableId,

        [Parameter(Mandatory = $true)]
        [string[]]$FieldIds,

        [Parameter(Mandatory = $true)]
        [string]$RowsJson
    )

    if ($FieldIds.Count -eq 0) {
        throw 'FieldIds cannot be empty.'
    }

    if ([string]::IsNullOrWhiteSpace($RowsJson)) {
        throw 'RowsJson cannot be empty.'
    }

    $schema = Get-TimeTrackerSchema
    $dateFieldId = $schema.Tables.Detail.FieldIds.Date

    # Parse the rows JSON and convert date strings to timestamps
    $normalizedRows = @((ConvertFrom-Json -InputObject $RowsJson))
    $normalizedRows = @($normalizedRows | ForEach-Object {
        if ($_ -is [string]) {
            ,@((ConvertFrom-Json -InputObject $_))
        }
        else {
            ,$_
        }
    })

    if ($normalizedRows.Count -eq 0) {
        throw 'Rows cannot be empty.'
    }

    if ($normalizedRows.Count -gt 200) {
        throw 'record-batch-create supports at most 200 rows per request.'
    }

    # Convert date fields to timestamps
    $pythonRows = [System.Collections.ArrayList]::new()
    foreach ($row in $normalizedRows) {
        $normalizedRow = @($row)
        if ($normalizedRow.Count -eq 1 -and $normalizedRow[0] -is [System.Array]) {
            $normalizedRow = @($normalizedRow[0])
        }

        $pyRow = [System.Collections.ArrayList]::new()
        for ($i = 0; $i -lt $FieldIds.Count; $i++) {
            $value = $normalizedRow[$i]
            if ($FieldIds[$i] -eq $dateFieldId -and $value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
                $value = Convert-DateTextToUnixMilliseconds -DateText $value
            }

            [void]$pyRow.Add($value)
        }

        [void]$pythonRows.Add(@($pyRow))
    }

    $workspaceRoot = Get-TimeTrackerRoot
    $cliPath = Get-LarkCliPath

    # Build payload for Python script
    $payload = @{
        base_token = $schema.BaseToken
        table_id = $TableId
        field_ids = @($FieldIds)
        rows = @($pythonRows)
        cli_path = $cliPath
        workdir = $workspaceRoot
    }

    $pyScriptPath = Join-Path (Get-TimeTrackerScriptsRoot) 'batch_create.py'
    $pythonExe = Get-PythonExePath
    $payloadJson = $payload | ConvertTo-Json -Depth 15 -Compress
    $tmpPayloadPath = [System.IO.Path]::GetTempFileName() + '.json'
    $tmpOutputPath = [System.IO.Path]::GetTempFileName() + '.out'
    $tmpErrorPath = [System.IO.Path]::GetTempFileName() + '.err'
    try {
        [System.IO.File]::WriteAllText($tmpPayloadPath, $payloadJson, [System.Text.UTF8Encoding]::new($false))

        $ErrAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = Push-Location $workspaceRoot -ErrorAction Stop
            $null = & $pythonExe $pyScriptPath $tmpPayloadPath 2>$tmpErrorPath >$tmpOutputPath
        }
        finally {
            $null = Pop-Location -ErrorAction SilentlyContinue
            $ErrorActionPreference = $ErrAction
        }

        $pyExitCode = $LASTEXITCODE
        $stdoutContent = if (Test-Path $tmpOutputPath) { Get-Content $tmpOutputPath -Raw } else { '' }
        $stderrContent = if (Test-Path $tmpErrorPath) { Get-Content $tmpErrorPath -Raw } else { '' }
        $diagnostic = @($stderrContent, $stdoutContent) -join [Environment]::NewLine
        $diagnostic = $diagnostic.Trim()

        if ($pyExitCode -ne 0) {
            if (-not $diagnostic) {
                $diagnostic = 'No output captured.'
            }

            throw "batch_create.py failed (exit $pyExitCode): $diagnostic"
        }
    }
    finally {
        if (Test-Path $tmpPayloadPath) { Remove-Item $tmpPayloadPath -Force -EA SilentlyContinue }
        if (Test-Path $tmpOutputPath) { Remove-Item $tmpOutputPath -Force -EA SilentlyContinue }
        if (Test-Path $tmpErrorPath) { Remove-Item $tmpErrorPath -Force -EA SilentlyContinue }
    }

    if ($pyExitCode -ne 0) {
        throw "batch_create.py failed (exit $pyExitCode): $diagnostic"
    }

    # Parse Python output: last N lines are record IDs (one per line)
    $lines = @($stdoutContent -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $dataLines = @($lines | Where-Object { $_ -notmatch '^\{' })
    $recordIds = @($dataLines | Where-Object { $_ -match '^rec[A-Za-z0-9]+$' })

    return [pscustomobject]@{
        ok = $true
        data = [pscustomobject]@{
            record_id_list = $recordIds
        }
    }
}

function Invoke-TimeTrackerRecordBatchUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableId,

        [Parameter(Mandatory = $true)]
        [string[]]$RecordIds,

        [Parameter(Mandatory = $true)]
        [hashtable]$Patch
    )

    if ($RecordIds.Count -eq 0) {
        throw 'RecordIds cannot be empty.'
    }

    if ($RecordIds.Count -gt 200) {
        throw 'record-batch-update supports at most 200 record ids per request.'
    }

    $schema = Get-TimeTrackerSchema
    $body = @{
        record_id_list = $RecordIds
        patch = $Patch
    }

    $jsonBody = $body | ConvertTo-Json -Depth 8 -Compress
    $arguments = @(
        'base',
        '+record-batch-update',
        '--base-token', $schema.BaseToken,
        '--table-id', $TableId,
        '--json', $jsonBody
    )

    return Invoke-LarkCliJson -Arguments $arguments
}
