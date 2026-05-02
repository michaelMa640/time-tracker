Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TimeTrackerConfigRoot {
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-TimeTrackerConfigPath {
    return (Join-Path (Get-TimeTrackerConfigRoot) 'time-tracker.config.json')
}

function Get-TimeTrackerConfigExamplePath {
    return (Join-Path (Get-TimeTrackerConfigRoot) 'time-tracker.config.example.json')
}

function Read-TimeTrackerConfig {
    $configPath = Get-TimeTrackerConfigPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        $examplePath = Get-TimeTrackerConfigExamplePath
        throw "Missing time-tracker.config.json. Copy $examplePath to $configPath and fill in your private Lark IDs."
    }

    $raw = Get-Content -LiteralPath $configPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Config file is empty: $configPath"
    }

    return ($raw | ConvertFrom-Json)
}

function Get-TimeTrackerSchema {
    $config = Read-TimeTrackerConfig
    return [pscustomobject]@{
        BaseToken = $config.BaseToken
        Tables = $config.Tables
        Enums = [pscustomobject]@{
            DetailSourceTypes = @('heartbeat', 'manual-repair', 'rebuild')
            ValidationStatuses = @('ok', 'timestamp_mismatch', 'overlap', 'duplicate', 'gap')
            StatsSources = @('auto-22', 'auto-24', 'manual-rebuild')
            AnomalyFlags = @('none', 'overlap', 'duplicate', 'mismatch', 'gap')
        }
        Formats = [pscustomobject]@{
            DateKey = 'yyyy-MM-dd'
            DetailDateDisplay = 'yyyy/MM/dd'
            StatsDateDisplay = 'yyyy/MM/dd'
            RatioValue = 'percentage-number'
        }
        VerifiedAt = $config.VerifiedAt
    }
}
