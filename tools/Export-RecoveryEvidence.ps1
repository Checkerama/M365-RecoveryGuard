#requires -Version 7.4
<#
Export-RecoveryEvidence.ps1

Creates a read-only evidence snapshot from a completed RecoveryGuard state directory.
The source evidence is not modified.

This sanitized version contains no production client names, paths, tenant URLs,
incident counts, identities, or production GUIDs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config not found: $ConfigPath"
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$StateDir = [string]$Config.Paths.StateDirectory
$Queue = [string]$Config.Paths.QueueCsv
$Terminal = Join-Path $StateDir "terminal-results.csv"
$Checkpoint = Join-Path $StateDir "checkpoint.json"

foreach($p in @($StateDir,$Queue,$Terminal,$Checkpoint)) {
    if(-not (Test-Path -LiteralPath $p)) {
        throw "Required evidence missing: $p"
    }
}

$queueRows = @(Import-Csv -LiteralPath $Queue)
$resultRows = @(Import-Csv -LiteralPath $Terminal)
$cp = Get-Content -LiteralPath $Checkpoint -Raw | ConvertFrom-Json
$unique = @($resultRows | Group-Object RecycleBinId)

if([int]$cp.NextIndex -ne $queueRows.Count) {
    throw "Checkpoint does not equal queue length. Do not freeze as complete."
}
if($unique.Count -ne $queueRows.Count) {
    throw "Unique terminal GUID count does not equal queue length."
}

if([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Split-Path -Parent $StateDir) "closure"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Dest = Join-Path $OutputDirectory "RecoveryGuard-Closure-$stamp"
$Zip = "$Dest.zip"

New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $Dest "config.snapshot.json")
Copy-Item -LiteralPath $Queue -Destination (Join-Path $Dest "queue.snapshot.csv")
Copy-Item -LiteralPath $StateDir -Destination (Join-Path $Dest "state") -Recurse

$summary = [ordered]@{
    ClosureTimestamp = [datetimeoffset]::Now.ToString("o")
    Site = [string]$Config.SharePoint.SiteUrl
    QueueCount = $queueRows.Count
    UniqueTerminalGuids = $unique.Count
    Checkpoint = [int]$cp.NextIndex
    IncidentPopulation = [int]$Config.Reporting.IncidentPopulation
    RestoredBaseline = [int]$Config.Reporting.RestoredBaseline
    ConflictsBaseline = [int]$Config.Reporting.ConflictsBaseline
}
$summary | ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath (Join-Path $Dest "closure-summary.json") -Encoding UTF8

$manifest = Get-ChildItem -LiteralPath $Dest -File -Recurse |
    Sort-Object FullName |
    ForEach-Object {
        $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
        [pscustomobject]@{
            RelativePath = $_.FullName.Substring($Dest.Length).TrimStart("\")
            Length = $_.Length
            LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString("o")
            SHA256 = $hash.Hash.ToLowerInvariant()
        }
    }

$manifest |
    Export-Csv -LiteralPath (Join-Path $Dest "SHA256-MANIFEST.csv") -NoTypeInformation -Encoding UTF8

Get-ChildItem -LiteralPath $Dest -File -Recurse |
    ForEach-Object { $_.IsReadOnly = $true }

Compress-Archive -LiteralPath $Dest -DestinationPath $Zip -CompressionLevel Optimal -Force
$zipHash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host ""
Write-Host "Evidence snapshot complete." -ForegroundColor Green
Write-Host "Folder: $Dest"
Write-Host "ZIP:    $Zip"
Write-Host "SHA256: $zipHash"
