# M365 RecoveryGuard

A safety-first reference framework for investigating and recovering large Microsoft 365 / SharePoint deletion incidents.

## What this project demonstrates

RecoveryGuard coordinates a controlled recovery workflow around SharePoint recycle-bin objects. The architecture emphasizes:

- immutable object identity instead of filename-only matching
- pre-write destination collision checks
- no-overwrite behavior for occupied destinations
- durable terminal logging and checkpoints
- Supervisor/Worker process isolation
- health probes for DNS, TCP, SharePoint authentication, state storage, and optional database connectivity
- adaptive hang detection
- exact reconciliation before retrying an ambiguous restore
- cryptographic queue/engine binding before writes
- a separate read-only live monitor
- evidence packaging and SHA-256 manifests

This repository is a **sanitized reference implementation**. It does not contain the customer data, tenant identifiers, production queue, audit exports, user information, incident evidence, or credentials from the real-world incident that informed the architecture.

## Repository layout

```text
m365-recoveryguard/
├── README.md
├── .gitignore
├── SECURITY.md
├── NOTICE.md
├── src/
│   ├── M365-Recovery-SelfHealing.ps1
│   ├── Start-RecoveryGuard.ps1
│   └── Watch-RecoveryGuard.ps1
├── config/
│   └── recovery.template.json
├── examples/
│   └── queue.synthetic.csv
├── tools/
│   ├── Export-RecoveryEvidence.ps1
│   └── Test-RepositorySanitization.ps1
├── tests/
│   └── README.md
└── docs/
    ├── architecture.md
    ├── case-study.md
    ├── safety-model.md
    ├── sanitization.md
    └── github-first-upload.md
```

## Before using it

1. Install PowerShell 7.4+.
2. Install the PnP.PowerShell module appropriate to your environment.
3. Copy `config/recovery.template.json` to `config/recovery.local.json`.
4. Supply your own tenant/site, authentication configuration, absolute queue path, and state directory.
5. Keep `recovery.local.json`, production queues, logs, evidence, and credentials out of Git.
6. Run the sanitization scanner before every public push.

```powershell
pwsh -File .\tools\Test-RepositorySanitization.ps1
```

## Important safety boundary

Do not point this project at production merely because the scripts run. Validate the workflow in a non-production tenant, confirm your access model, verify the queue independently, and obtain explicit authorization before enabling recovery writes.

## Project status

Reference / portfolio-quality architecture. Not a Microsoft-supported recovery product.

## License

No open-source license is included yet. See `NOTICE.md`.
