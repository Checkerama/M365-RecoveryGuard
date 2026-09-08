#requires -Version 7.4
#requires -Modules Pester

<#
RecoveryGuard.Repository.Tests.ps1

Pester 5/6-compatible offline validation for the sanitized RecoveryGuard repository.

These tests DO NOT connect to SharePoint and DO NOT perform recovery writes.
They validate repository structure, syntax, config defaults, synthetic queue
integrity, fail-closed source controls, .gitignore protections, and sanitizer
behavior.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Describe "RecoveryGuard repository structure" {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $ExpectedCoreFiles = @(
            (Join-Path $RepoRoot "src\M365-Recovery-SelfHealing.ps1")
            (Join-Path $RepoRoot "src\Start-RecoveryGuard.ps1")
            (Join-Path $RepoRoot "src\Watch-RecoveryGuard.ps1")
            (Join-Path $RepoRoot "config\recovery.template.json")
            (Join-Path $RepoRoot "examples\queue.synthetic.csv")
            (Join-Path $RepoRoot ".gitignore")
            (Join-Path $RepoRoot "tools\Test-RepositorySanitization.ps1")
        )
    }

    It "contains the expected core files" {
        foreach ($ExpectedFile in $ExpectedCoreFiles) {
            Test-Path -LiteralPath $ExpectedFile | Should -BeTrue
        }
    }

    It "does not contain a committed local production config" {
        Test-Path -LiteralPath (Join-Path $RepoRoot "config\recovery.local.json") |
            Should -BeFalse
    }
}

Describe "PowerShell source validation" {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    }

    It "parses without PowerShell syntax errors: M365-Recovery-SelfHealing.ps1" {
        $Path = Join-Path $RepoRoot "src\M365-Recovery-SelfHealing.ps1"
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$Tokens, [ref]$Errors
        )
        $Errors.Count | Should -Be 0
    }

    It "parses without PowerShell syntax errors: Start-RecoveryGuard.ps1" {
        $Path = Join-Path $RepoRoot "src\Start-RecoveryGuard.ps1"
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$Tokens, [ref]$Errors
        )
        $Errors.Count | Should -Be 0
    }

    It "parses without PowerShell syntax errors: Watch-RecoveryGuard.ps1" {
        $Path = Join-Path $RepoRoot "src\Watch-RecoveryGuard.ps1"
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$Tokens, [ref]$Errors
        )
        $Errors.Count | Should -Be 0
    }

    It "parses without PowerShell syntax errors: Test-RepositorySanitization.ps1" {
        $Path = Join-Path $RepoRoot "tools\Test-RepositorySanitization.ps1"
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$Tokens, [ref]$Errors
        )
        $Errors.Count | Should -Be 0
    }
}

Describe "Configuration safety defaults" {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $ConfigPath = Join-Path $RepoRoot "config\recovery.template.json"
        $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    }

    It "parses as valid JSON" {
        $Config | Should -Not -BeNullOrEmpty
    }

    It "defaults the write gate to CLOSED" {
        [bool]$Config.Safety.WriteEnabled | Should -BeFalse
    }

    It "uses only the placeholder SharePoint tenant" {
        [string]$Config.SharePoint.SiteUrl |
            Should -Be "https://tenant.sharepoint.com/sites/TargetSite"
    }

    It "uses an example target identity rather than a real account" {
        [string]$Config.Target.UserOrServiceAccount |
            Should -Be "affected-user@example.com"
    }

    It "does not contain a real Entra client ID" {
        [string]$Config.Authentication.ClientId |
            Should -Be "<ENTRA_APP_CLIENT_ID>"
    }
}

Describe "Synthetic recovery queue" {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $QueuePath = Join-Path $RepoRoot "examples\queue.synthetic.csv"
        $Queue = @(Import-Csv -LiteralPath $QueuePath)
    }

    It "contains at least one synthetic object" {
        $Queue.Count | Should -BeGreaterThan 0
    }

    It "contains only valid GUIDs" {
        foreach ($Row in $Queue) {
            $Parsed = [guid]::Empty
            [guid]::TryParse([string]$Row.RecycleBinId,[ref]$Parsed) |
                Should -BeTrue
        }
    }

    It "contains no duplicate recycle-bin GUIDs" {
        @($Queue | Group-Object RecycleBinId | Where-Object Count -gt 1).Count |
            Should -Be 0
    }

    It "contains no duplicate original sequence numbers" {
        @($Queue | Group-Object OriginalSequence | Where-Object Count -gt 1).Count |
            Should -Be 0
    }

    It "uses only the sanitized TargetSite path" {
        foreach ($Row in $Queue) {
            [string]$Row.DirName | Should -Match '^/sites/TargetSite/'
        }
    }
}

Describe "Fail-closed source controls" {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $EnginePath = Join-Path $RepoRoot "src\M365-Recovery-SelfHealing.ps1"
        $LauncherPath = Join-Path $RepoRoot "src\Start-RecoveryGuard.ps1"
        $Engine = Get-Content -LiteralPath $EnginePath -Raw
        $Launcher = Get-Content -LiteralPath $LauncherPath -Raw
    }

    It "uses immutable recycle-bin GUID identity" {
        $Engine | Should -Match 'Get-RowGuid'
        $Engine | Should -Match 'Restore-PnPRecycleBinItem\s+-Identity'
    }

    It "has a destination-state check before automatic recovery logic" {
        $Engine | Should -Match 'Get-DestinationState'
        $Engine | Should -Match 'CONFLICT'
    }

    It "contains an explicit write-arm validation control" {
        $Engine | Should -Match 'Assert-WriteArmed'
        $Engine | Should -Match 'WriteEnabled'
    }

    It "contains queue SHA256 validation" {
        $Engine | Should -Match 'QueueSha256'
        $Engine | Should -Match 'Get-QueueHash'
    }

    It "contains engine SHA256 validation" {
        $Engine | Should -Match 'ExpectedEngineSha256'
        $Engine | Should -Match 'Get-EngineHash'
    }

    It "contains watchdog hang detection" {
        $Engine | Should -Match 'HANG_DETECTED'
        $Engine | Should -Match 'Get-HangTimeout'
    }

    It "contains exact reconciliation logic for ambiguous outcomes" {
        $Engine | Should -Match 'Reconcile-Inflight'
        $Engine | Should -Match 'MANUAL_REVIEW_REQUIRED'
    }

    It "launcher refuses an already-active Supervisor" {
        $Launcher | Should -Match 'active Supervisor already exists'
    }

    It "launcher refuses unexplained inflight state" {
        $Launcher | Should -Match 'inflight\.json exists'
    }

    It "launcher refuses a fresh start after checkpoint advancement" {
        $Launcher | Should -Match 'checkpoint already advanced'
    }

    It "launcher resets the write gate CLOSED on startup verification failure" {
        $Launcher | Should -Match 'Set-WriteClosed'
        $Launcher | Should -Match 'write gate reset CLOSED'
    }
}

Describe ".gitignore protection" {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $GitIgnorePath = Join-Path $RepoRoot ".gitignore"
        $Ignore = Get-Content -LiteralPath $GitIgnorePath -Raw
    }

    It "ignores local production config" {
        $Ignore | Should -Match 'recovery\.local\.json'
    }

    It "ignores recovery state directories" {
        $Ignore | Should -Match 'state/'
    }

    It "ignores certificate/private-key material" {
        $Ignore | Should -Match '\*\.pfx'
        $Ignore | Should -Match '\*\.pem'
        $Ignore | Should -Match '\*\.key'
    }

    It "ignores production evidence/report formats" {
        $Ignore | Should -Match '\*\.pdf'
        $Ignore | Should -Match '\*\.docx'
        $Ignore | Should -Match '\*\.xlsx'
        $Ignore | Should -Match '\*\.zip'
    }
}

Describe "Sanitization scanner integration" {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $ScannerPath = Join-Path $RepoRoot "tools\Test-RepositorySanitization.ps1"
    }

    It "passes against the current sanitized repository" {
        & pwsh `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ScannerPath `
            -RepositoryRoot $RepoRoot |
            Out-Null

        $LASTEXITCODE | Should -Be 0
    }

    It "allows documented placeholder values" {
        $CaseRoot = Join-Path $TestDrive "safe-case"
        New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null

        $SafeUserPath = 'C:\Users\' + '<you>' + '\Documents\GitHub\m365-recoveryguard'

        @(
            "https://tenant.sharepoint.com/sites/TargetSite"
            "affected-user@example.com"
            $SafeUserPath
        ) | Set-Content -LiteralPath (Join-Path $CaseRoot "safe-example.txt") -Encoding UTF8

        & pwsh `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ScannerPath `
            -RepositoryRoot $CaseRoot |
            Out-Null

        $LASTEXITCODE | Should -Be 0
    }

    It "rejects a non-placeholder SharePoint tenant" {
        $CaseRoot = Join-Path $TestDrive "unsafe-tenant-case"
        New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null

        # Construct at runtime so the repository sanitizer does not flag
        # the negative test fixture inside this committed test file.
        $UnsafeUrl =
            "https://" + "privatecompany" + ".sharepoint.com/sites/Operations"

        $UnsafeUrl |
            Set-Content -LiteralPath (Join-Path $CaseRoot "unsafe-example.txt") -Encoding UTF8

        & pwsh `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ScannerPath `
            -RepositoryRoot $CaseRoot |
            Out-Null

        $LASTEXITCODE | Should -Be 1
    }

    It "rejects a real-looking Windows user profile path" {
        $CaseRoot = Join-Path $TestDrive "unsafe-user-case"
        New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null

        # Same approach: build the prohibited pattern dynamically.
        $UnsafeUserPath =
            'C:\Users\' + 'RealEmployee' + '\Documents\Recovery'

        $UnsafeUserPath |
            Set-Content -LiteralPath (Join-Path $CaseRoot "unsafe-userpath.txt") -Encoding UTF8

        & pwsh `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ScannerPath `
            -RepositoryRoot $CaseRoot |
            Out-Null

        $LASTEXITCODE | Should -Be 1
    }
}
