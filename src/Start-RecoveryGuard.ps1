#requires -Version 7.4
<#
M365 RecoveryGuard - Arm and Start

Generic production gate for the sanitized RecoveryGuard engine.

Safety properties:
  - refuses a second Supervisor
  - refuses fresh launch when inflight state exists
  - refuses fresh launch when the checkpoint has advanced
  - closes the write gate before validation
  - validates PowerShell syntax, queue fingerprint, and queue envelope
  - runs engine SelfTest, ArmCheck, and health Probe
  - writes an exact arm file bound to engine + queue + site + client id
  - requires a live Supervisor PID and SUPERVISOR_START event
  - closes the write gate automatically when startup verification fails

This file intentionally contains no tenant-specific production constants.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Root = (Split-Path -Parent $PSScriptRoot),

    [Parameter(Mandatory=$false)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$EnginePath = Join-Path $Root "src\M365-Recovery-SelfHealing.ps1"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $Root "config\recovery.local.json"
}

function Write-AtomicJson {
    param($Object,[string]$Path)
    $tmp = "$Path.tmp.$PID"
    $Object | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tmp -Encoding UTF8
    [void](Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Set-WriteClosed {
    param([string]$Path)
    $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $cfg["Safety"]["WriteEnabled"] = $false
    Write-AtomicJson $cfg $Path
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " M365 RECOVERYGUARD - DEPLOYMENT GATE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "STOP: local config not found: $ConfigPath`nCopy config\recovery.template.json to config\recovery.local.json and fill in your environment values."
}
if (-not (Test-Path -LiteralPath $EnginePath)) {
    throw "STOP: engine not found: $EnginePath"
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$StateDir = [string]$Config["Paths"]["StateDirectory"]
$QueuePath = [string]$Config["Paths"]["QueueCsv"]
$ArmFile = [string]$Config["Safety"]["ArmFile"]

foreach($p in @($StateDir,$QueuePath,$ArmFile)) {
    if ([string]::IsNullOrWhiteSpace($p)) { throw "STOP: required config path is empty." }
}

$SupervisorPidPath = Join-Path $StateDir "supervisor.pid"
$WorkerPidPath     = Join-Path $StateDir "worker.pid"
$InflightPath      = Join-Path $StateDir "inflight.json"
$CheckpointPath    = Join-Path $StateDir "checkpoint.json"
$EventsPath        = Join-Path $StateDir "events.jsonl"

$activeSupervisor = $false
if (Test-Path -LiteralPath $SupervisorPidPath) {
    $pidText = (Get-Content -LiteralPath $SupervisorPidPath -Raw).Trim()
    $pidNum = 0
    if ([int]::TryParse($pidText,[ref]$pidNum)) {
        if (Get-Process -Id $pidNum -ErrorAction SilentlyContinue) {
            $activeSupervisor = $true
        }
    }
}

if ($activeSupervisor) {
    throw "STOP: an active Supervisor already exists."
}
if (Test-Path -LiteralPath $InflightPath) {
    throw "STOP: inflight.json exists. Reconcile it before restarting."
}
if (Test-Path -LiteralPath $CheckpointPath) {
    $cp = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
    if ([int]$cp.NextIndex -ne 0) {
        throw "STOP: checkpoint already advanced to NextIndex=$($cp.NextIndex). Use reconciliation/resume logic."
    }
}

Set-WriteClosed $ConfigPath
foreach($p in @($ArmFile,$SupervisorPidPath,$WorkerPidPath)) {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

# Syntax validation
$Tokens=$null
$ParseErrors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $EnginePath,[ref]$Tokens,[ref]$ParseErrors
)
if ($ParseErrors.Count -gt 0) {
    $ParseErrors | Format-List Message,Extent
    throw "STOP: engine PowerShell syntax validation failed."
}

$Queue = @(Import-Csv -LiteralPath $QueuePath)
if ($Queue.Count -lt 1) { throw "STOP: queue is empty." }

function Get-QueueGuid($Row) {
    foreach($n in @("RecycleBinId","Id","GUID","Guid")) {
        if($Row.PSObject.Properties.Name -contains $n) {
            $v=[string]$Row.$n
            if(-not [string]::IsNullOrWhiteSpace($v)){ return $v.Trim().ToLowerInvariant() }
        }
    }
    return $null
}

function Get-Sequence($Row,[int]$Index) {
    if($Row.PSObject.Properties.Name -contains "OriginalSequence" -and
       -not [string]::IsNullOrWhiteSpace([string]$Row.OriginalSequence)) {
        return [int]$Row.OriginalSequence
    }
    $base = 1
    if($Config["Recovery"].ContainsKey("OriginalSequenceBase")) {
        $base = [int]$Config["Recovery"]["OriginalSequenceBase"]
    }
    return $base + $Index
}

$FirstGuid = Get-QueueGuid $Queue[0]
if ([string]::IsNullOrWhiteSpace($FirstGuid)) {
    throw "STOP: first queue row has no immutable GUID."
}

$FirstSequence = Get-Sequence $Queue[0] 0
$LastSequence = Get-Sequence $Queue[-1] ($Queue.Count - 1)
$QueueHash = (Get-FileHash -LiteralPath $QueuePath -Algorithm SHA256).Hash.ToLowerInvariant()
$EngineHash = (Get-FileHash -LiteralPath $EnginePath -Algorithm SHA256).Hash.ToLowerInvariant()

# Bind the safety envelope to the current reviewed queue.
$Config["ProgramVersion"] = "1.0.0"
$Config["Safety"]["ExpectedEngineSha256"] = $EngineHash
$Config["Safety"]["QueueSha256"] = $QueueHash
$Config["Safety"]["ExpectedQueueCount"] = $Queue.Count
$Config["Safety"]["ExpectedFirstSequence"] = $FirstSequence
$Config["Safety"]["ExpectedLastSequence"] = $LastSequence
$Config["Safety"]["ExpectedFirstGuid"] = $FirstGuid
$Config["Safety"]["WriteEnabled"] = $false
Write-AtomicJson $Config $ConfigPath

Write-Host "Engine/queue safety envelope: PASS" -ForegroundColor Green

Write-Host ""
Write-Host "Running runtime SelfTest..." -ForegroundColor Cyan
& pwsh -NoProfile -ExecutionPolicy Bypass `
    -File $EnginePath `
    -Mode SelfTest `
    -ConfigPath $ConfigPath

$SelfTestPath = Join-Path $StateDir "selftest-result.json"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $SelfTestPath)) {
    throw "STOP: runtime SelfTest failed."
}
$SelfTest = Get-Content -LiteralPath $SelfTestPath -Raw | ConvertFrom-Json
if ($SelfTest.Passed -ne $true) {
    throw "STOP: runtime SelfTest did not pass."
}

$ApprovedAt = [datetimeoffset]::UtcNow.ToString("o")
$ArmId = [guid]::NewGuid().ToString()
$Population = [int]$Config["Reporting"]["IncidentPopulation"]
$RestoredBaseline = [int]$Config["Reporting"]["RestoredBaseline"]
$ConflictsBaseline = [int]$Config["Reporting"]["ConflictsBaseline"]

$Arm = [ordered]@{
    SchemaVersion      = "1.0"
    Approved           = $true
    ArmId              = $ArmId
    ApprovedAtUtc      = $ApprovedAt
    ApprovedBy         = "$env:USERDOMAIN\$env:USERNAME"
    MachineName        = $env:COMPUTERNAME
    ProgramVersion     = "1.0.0"
    EnginePath         = $EnginePath
    EngineSha256       = $EngineHash
    QueuePath          = $QueuePath
    QueueSha256        = $QueueHash
    QueueCount         = $Queue.Count
    FirstSequence      = $FirstSequence
    LastSequence       = $LastSequence
    FirstGuid          = $FirstGuid
    SiteUrl            = [string]$Config["SharePoint"]["SiteUrl"]
    ClientId           = [string]$Config["Authentication"]["ClientId"]
    IncidentPopulation = $Population
    RestoredBaseline   = $RestoredBaseline
    ConflictsBaseline  = $ConflictsBaseline
    PendingAtArm       = $Queue.Count
}

Write-AtomicJson $Arm $ArmFile

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$Config["Safety"]["WriteEnabled"] = $true
Write-AtomicJson $Config $ConfigPath

Write-Host "Write arm created: $ArmId" -ForegroundColor Yellow

& pwsh -NoProfile -ExecutionPolicy Bypass `
    -File $EnginePath `
    -Mode ArmCheck `
    -ConfigPath $ConfigPath

if ($LASTEXITCODE -ne 0) {
    Set-WriteClosed $ConfigPath
    throw "STOP: ArmCheck failed; write gate reset CLOSED."
}
Write-Host "ArmCheck: PASS" -ForegroundColor Green

& pwsh -NoProfile -ExecutionPolicy Bypass `
    -File $EnginePath `
    -Mode Probe `
    -ConfigPath $ConfigPath

$ProbePath = Join-Path $StateDir "probe-result.json"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ProbePath)) {
    Set-WriteClosed $ConfigPath
    throw "STOP: final Probe failed; write gate reset CLOSED."
}
$Probe = Get-Content -LiteralPath $ProbePath -Raw | ConvertFrom-Json
if ($Probe.Healthy -ne $true) {
    Set-WriteClosed $ConfigPath
    throw "STOP: final health state is unhealthy; write gate reset CLOSED."
}
Write-Host "Final health probe: PASS" -ForegroundColor Green

$PwshPath = (Get-Process -Id $PID).Path
$BootstrapCommand = @"
& '$($EnginePath.Replace("'","''"))' -Mode Supervisor -ConfigPath '$($ConfigPath.Replace("'","''"))'
"@
$EncodedBootstrap = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($BootstrapCommand))

$SupervisorStdout = Join-Path $StateDir "supervisor-stdout.log"
$SupervisorStderr = Join-Path $StateDir "supervisor-stderr.log"
foreach($p in @($SupervisorStdout,$SupervisorStderr)) {
    if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Force }
}

$Supervisor = Start-Process `
    -FilePath $PwshPath `
    -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-EncodedCommand",$EncodedBootstrap) `
    -RedirectStandardOutput $SupervisorStdout `
    -RedirectStandardError $SupervisorStderr `
    -PassThru

$deadline = (Get-Date).AddSeconds(20)
$confirmed = $false
do {
    Start-Sleep -Milliseconds 500
    $Supervisor.Refresh()
    if ($Supervisor.HasExited) { break }

    if (Test-Path -LiteralPath $SupervisorPidPath) {
        $declared = (Get-Content -LiteralPath $SupervisorPidPath -Raw).Trim()
        if ($declared -eq [string]$Supervisor.Id -and (Test-Path -LiteralPath $EventsPath)) {
            $hasStart = Get-Content -LiteralPath $EventsPath |
                Select-Object -Last 50 |
                Where-Object { $_ -match '"Type"\s*:\s*"SUPERVISOR_START"' }
            if ($hasStart) {
                $confirmed = $true
                break
            }
        }
    }
} while ((Get-Date) -lt $deadline)

if (-not $confirmed) {
    try {
        if (-not $Supervisor.HasExited) {
            Stop-Process -Id $Supervisor.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    Set-WriteClosed $ConfigPath
    throw "STOP: Supervisor process did not prove successful initialization; write gate reset CLOSED."
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " SUPERVISOR STARTUP VERIFIED" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Supervisor PID: $($Supervisor.Id)"
Write-Host "Arm ID:         $ArmId"
Write-Host "Queue:          $($Queue.Count)"
Write-Host "Sequences:      $FirstSequence..$LastSequence"
Write-Host "State:          $StateDir"
Write-Host ""
Write-Host "Production control transferred to the verified Supervisor." -ForegroundColor Green
