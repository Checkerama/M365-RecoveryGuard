#requires -Version 7.4
# Sanitized generic monitor. Contains no production tenant values.
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "configecovery.local.json"),
    [int]$RefreshSeconds = 5,
    [int]$ReadRetries = 6,
    [int]$RetryDelayMilliseconds = 125
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-TextShared {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $lastError = $null

    for ($attempt = 1; $attempt -le $ReadRetries; $attempt++) {
        try {
            $fs = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            )

            try {
                $sr = [System.IO.StreamReader]::new($fs)
                try {
                    return $sr.ReadToEnd()
                }
                finally {
                    $sr.Dispose()
                }
            }
            finally {
                $fs.Dispose()
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }

    throw "Unable to read '$Path' after $ReadRetries attempts. Last error: $lastError"
}

function Read-JsonShared {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $text = Read-TextShared -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return ($text | ConvertFrom-Json)
}

function Read-CsvShared {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $text = Read-TextShared -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    return @($text | ConvertFrom-Csv)
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$State  = [string]$Config.Paths.StateDirectory
$Queue  = @(Import-Csv -LiteralPath ([string]$Config.Paths.QueueCsv))

$Checkpoint = Join-Path $State "checkpoint.json"
$Heartbeat  = Join-Path $State "worker-heartbeat.json"
$Results    = Join-Path $State "terminal-results.csv"
$Health     = Join-Path $State "health.csv"
$Events     = Join-Path $State "events.jsonl"
$SupervisorPid = Join-Path $State "supervisor.pid"
$WorkerPid     = Join-Path $State "worker.pid"

# Last-good snapshots keep the monitor alive through transient file replacement/locks.
$lastCp = $null
$lastHb = $null
$lastRows = @()
$lastHealth = $null
$lastEvent = $null
$lastReadWarning = $null

while ($true) {
    try {
        try {
            if (Test-Path -LiteralPath $Checkpoint) {
                $x = Read-JsonShared -Path $Checkpoint
                if ($null -ne $x) { $lastCp = $x }
            }
        } catch { $lastReadWarning = "checkpoint: $($_.Exception.Message)" }

        try {
            if (Test-Path -LiteralPath $Heartbeat) {
                $x = Read-JsonShared -Path $Heartbeat
                if ($null -ne $x) { $lastHb = $x }
            }
        } catch { $lastReadWarning = "heartbeat: $($_.Exception.Message)" }

        try {
            if (Test-Path -LiteralPath $Results) {
                $x = Read-CsvShared -Path $Results
                if ($null -ne $x) { $lastRows = @($x) }
            }
        } catch { $lastReadWarning = "results: $($_.Exception.Message)" }

        try {
            if (Test-Path -LiteralPath $Health) {
                $x = Read-CsvShared -Path $Health
                if (@($x).Count -gt 0) { $lastHealth = @($x)[-1] }
            }
        } catch { $lastReadWarning = "health: $($_.Exception.Message)" }

        try {
            if (Test-Path -LiteralPath $Events) {
                $text = Read-TextShared -Path $Events
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $line = @($text -split "`r?`n" | Where-Object { $_.Trim() })[-1]
                    if ($line) {
                        try { $lastEvent = $line | ConvertFrom-Json } catch {}
                    }
                }
            }
        } catch { $lastReadWarning = "events: $($_.Exception.Message)" }

        $cp = $lastCp
        $hb = $lastHb
        $rows = @($lastRows)

        $restored = @(
            $rows | Where-Object {
                $_.Result -in @("RESTORED","RECOVERED_COMMITTED_AFTER_HANG")
            }
        ).Count

        $conflicts = @(
            $rows | Where-Object { $_.Result -eq "CONFLICT" }
        ).Count

        $failed = @(
            $rows | Where-Object {
                $_.Result -in @(
                    "FAILED_REVIEW_REQUIRED",
                    "AMBIGUOUS_RESTORE_ABORT",
                    "ABORT_BEFORE_RESTORE",
                    "BAD_PATH",
                    "MANUAL_REVIEW_REQUIRED"
                )
            }
        ).Count

        $nextIndex = if ($cp) { [int]$cp.NextIndex } else { 0 }
        $pending = $Queue.Count - $nextIndex
        $pct = if ($Queue.Count) { 100.0 * $nextIndex / $Queue.Count } else { 0 }

        $spid = $null
        if (Test-Path -LiteralPath $SupervisorPid) {
            try { $spid = [int](Read-TextShared -Path $SupervisorPid).Trim() } catch {}
        }

        $wpid = $null
        if (Test-Path -LiteralPath $WorkerPid) {
            try { $wpid = [int](Read-TextShared -Path $WorkerPid).Trim() } catch {}
        }

        $supervisorAlive = if ($spid) { $null -ne (Get-Process -Id $spid -ErrorAction SilentlyContinue) } else { $false }
        $workerAlive = if ($wpid) { $null -ne (Get-Process -Id $wpid -ErrorAction SilentlyContinue) } else { $false }

        Clear-Host
        Write-Host "M365 RECOVERYGUARD - LIVE MONITOR" -ForegroundColor Cyan
        Write-Host ("Updated: {0}" -f (Get-Date))
        Write-Host ""
        Write-Host ("Checkpoint: {0}/{1} ({2:N2}%)" -f $nextIndex,$Queue.Count,$pct)
        Write-Host ("Pending:    {0}" -f $pending)
        Write-Host ("Restored:   {0}" -f $restored)
        Write-Host ("Conflicts:  {0}" -f $conflicts)
        Write-Host ("Failures:   {0}" -f $failed)

        if ($cp) {
            Write-Host ("Last seq:   {0}" -f $cp.LastOriginalSequence)
            Write-Host ("Last result:{0}" -f (" " + $cp.LastResult))
        }

        Write-Host ""
        Write-Host ("Supervisor: PID={0} Alive={1}" -f $(if($spid){$spid}else{"none"}),$supervisorAlive)
        Write-Host ("Worker:     PID={0} Alive={1}" -f $(if($wpid){$wpid}else{"none"}),$workerAlive)

        if ($hb) {
            $age = ((Get-Date) - ([datetimeoffset]::Parse([string]$hb.Timestamp)).LocalDateTime).TotalSeconds
            Write-Host ("Heartbeat:  {0} | Seq={1} | Age={2:N1}s" -f $hb.Phase,$hb.Sequence,$age)
        }
        else {
            Write-Host "Heartbeat:  none yet"
        }

        if ($lastHealth) {
            Write-Host ("Health:     DNS={0} TCP={1} State={2} SP={3} DB={4}" -f `
                $lastHealth.Dns,$lastHealth.Tcp,$lastHealth.StateStore,$lastHealth.SharePoint,$lastHealth.Database)
        }

        if ($lastEvent) {
            Write-Host ("Last event: {0} | {1}" -f $lastEvent.Type,$lastEvent.Message)
        }

        if ($lastReadWarning) {
            Write-Host ""
            Write-Host ("Transient read warning (monitor continued): {0}" -f $lastReadWarning) -ForegroundColor Yellow
            $lastReadWarning = $null
        }

        Write-Host ""
        Write-Host "Read-only monitor. Ctrl+C exits monitor only; it does not stop Supervisor." -ForegroundColor DarkGray
    }
    catch {
        # The monitor itself should never take production down.
        Write-Host ""
        Write-Host ("Monitor refresh error; retrying: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    Start-Sleep -Seconds $RefreshSeconds
}
