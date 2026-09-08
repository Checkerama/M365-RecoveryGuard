#requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TestPath = Join-Path $PSScriptRoot "RecoveryGuard.Repository.Tests.ps1"

if (-not (Get-Module -ListAvailable -Name Pester)) {
    throw @"
Pester is not installed.

Install it for your user account first:

    Install-PSResource Pester -Scope CurrentUser -TrustRepository

Then rerun this script.
"@
}

Import-Module Pester -MinimumVersion 5.0

$Config = New-PesterConfiguration
$Config.Run.Path = $TestPath
$Config.Run.PassThru = $true
$Config.Output.Verbosity = "Detailed"
$Config.TestResult.Enabled = $true
$Config.TestResult.OutputPath = Join-Path $RepoRoot "test-results.xml"
$Config.TestResult.OutputFormat = "NUnitXml"

$Result = Invoke-Pester -Configuration $Config

if ($Result.FailedCount -gt 0) {
    exit 1
}

exit 0
