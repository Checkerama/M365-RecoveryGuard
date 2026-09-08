# Sanitization Checklist

Use this checklist before every push, especially before changing a repository from private to public.

## Remove or replace

- organization/customer names
- personal names
- real email addresses
- tenant `.sharepoint.com` hostnames
- internal domains
- workstation names
- public/private IP addresses associated with the incident
- Entra application IDs tied to the production tenant
- recycle-bin GUIDs from production
- filenames and folder paths from real business content
- incident counts if they are not approved for publication
- exact dates/times if they identify the incident
- audit exports
- recovery manifests and queues
- state directories and logs
- screenshots and stakeholder reports
- certificate files, tokens, secrets, connection strings

## Run the scanner

```powershell
pwsh -File .\tools\Test-RepositorySanitization.ps1
```

For a real release, edit `$BlockedLiteralTerms` in the scanner on your local machine to include the actual customer/company names and private domains you want to prohibit.

## Git history matters

Deleting a secret from the latest file does not remove it from older commits. Do the sanitization **before the first commit**. If sensitive data is ever committed, treat it as exposed and clean the Git history before publishing.
