#requires -Version 7.4
<#
Test-RepositorySanitization.ps1

Fail-closed pre-push scan for common client/tenant identifiers and secrets.
Add organization-specific prohibited terms to $BlockedLiteralTerms before publishing.
#>

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BlockedLiteralTerms = @(
    # Add real customer/company/project names locally before a public release review.
    "CHANGE_ME_CUSTOMER_NAME",
    "CHANGE_ME_PRIVATE_DOMAIN"
)

$AllowedDomains = @(
    "example.com",
    "tenant.sharepoint.com",
    "tenant.onmicrosoft.com"
)

$Extensions = @(
    ".ps1",".psm1",".psd1",".json",".md",".txt",".yml",".yaml",
    ".csv",".xml",".config",".ini",".toml"
)

$Files = Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse |
    Where-Object {
        $_.FullName -notmatch "[\\/]\.git[\\/]" -and
        $Extensions -contains $_.Extension.ToLowerInvariant()
    }

$Findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding($File,$Type,$Value) {
    $Findings.Add([pscustomobject]@{
        File = $File
        Type = $Type
        Value = $Value
    })
}

foreach($file in $Files) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

    foreach($term in $BlockedLiteralTerms) {
        if($term -notlike "CHANGE_ME_*" -and $text -match [regex]::Escape($term)) {
            Add-Finding $file.FullName "Blocked literal" $term
        }
    }

    # Private keys / credential material
    foreach($pattern in @(
        "-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "(?i)client_secret\s*[:=]",
        "(?i)password\s*[:=]\s*['""][^'""]+",
        "(?i)refresh_token\s*[:=]",
        "(?i)access_token\s*[:=]"
    )) {
        if($text -match $pattern) {
            Add-Finding $file.FullName "Possible secret" $Matches[0]
        }
    }

    # Email addresses outside example.com
    foreach($m in [regex]::Matches($text,'(?i)\b[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})\b')) {
        $domain = $m.Groups[1].Value.ToLowerInvariant()
        if($domain -notin $AllowedDomains) {
            Add-Finding $file.FullName "Non-example email" $m.Value
        }
    }

    # SharePoint domains outside the sanitized placeholder
    foreach($m in [regex]::Matches($text,'(?i)https://([a-z0-9-]+)\.sharepoint\.com')) {
        if($m.Groups[1].Value.ToLowerInvariant() -ne "tenant") {
            Add-Finding $file.FullName "Non-placeholder SharePoint tenant" $m.Value
        }
    }

    # Windows user-profile paths often disclose operator names.
    # Sanitized documentation placeholders are explicitly allowed.
    foreach($m in [regex]::Matches($text,'(?i)C:\\Users\\([^\\\r\n"'']+)')) {

        $ProfileName = $m.Groups[1].Value

        if ($ProfileName -notin @(
            "<you>",
            "<username>"
        )) {
            Add-Finding `
                $file.FullName `
                "Windows user path" `
                $m.Value
        }
    }

    # Common credential/certificate files should never be in the repo.
    if($file.Extension -match '^\.(pfx|p12|pem|key|cer)$') {
        Add-Finding $file.FullName "Credential/certificate file" $file.Name
    }
}

if($Findings.Count -gt 0) {
    Write-Host ""
    Write-Host "SANITIZATION CHECK FAILED" -ForegroundColor Red
    $Findings | Sort-Object File,Type | Format-Table -AutoSize
    exit 1
}

Write-Host "SANITIZATION CHECK PASSED: no prohibited identifiers/secrets detected." -ForegroundColor Green
exit 0

