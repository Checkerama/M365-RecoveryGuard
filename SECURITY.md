# Security Policy

## Never commit

Do not commit or upload:

- customer or employer names
- tenant domains or SharePoint URLs
- production Entra application IDs if they identify a real environment
- usernames, email addresses, device names, or IP addresses
- recycle-bin GUIDs from a real incident
- production queues, manifests, audit exports, or reconciliation logs
- OAuth tokens, secrets, passwords, certificates, private keys, connection strings
- screenshots or reports containing real business data
- incident-specific state directories

Run:

```powershell
pwsh -File .\tools\Test-RepositorySanitization.ps1
```

before publishing.

## Reporting vulnerabilities

If this repository becomes public, add a private security contact here rather than asking reporters to open public issues containing sensitive incident details.
