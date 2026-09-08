# First GitHub Upload - Windows / GitHub Desktop

The safest first publication is a **private** repository.

## 1. Create a GitHub account

Go to GitHub and create/sign in to your personal account. Enable multi-factor authentication.

## 2. Install GitHub Desktop

Install GitHub Desktop and sign in to the same GitHub account.

## 3. Create the empty local repository

In GitHub Desktop:

1. `File` -> `New repository`
2. Name: `m365-recoveryguard`
3. Description: `Safety-first M365 / SharePoint deletion recovery orchestration framework`
4. Local path: choose a normal development folder such as `C:\Users\<you>\Documents\GitHub`
5. Leave Git ignore as `None` because this package includes a custom `.gitignore`
6. Do **not** add a license yet
7. Click `Create repository`

GitHub Desktop creates:

`C:\Users\<you>\Documents\GitHub\m365-recoveryguard`

## 4. Copy this package into that folder

Copy the contents of the sanitized package into the repository folder. Do not copy the outer folder on top of itself.

You should see `README.md`, `.gitignore`, `src`, `config`, `docs`, `examples`, `tools`, and `tests` directly inside the repository folder.

## 5. Run the sanitization test

Open PowerShell 7 in the repository folder:

```powershell
pwsh -File .\tools\Test-RepositorySanitization.ps1
```

Do not commit unless it says the sanitization check passed.

## 6. Review exactly what Git sees

In GitHub Desktop, look at the `Changes` tab.

Expected files include source code, documentation, the config template, and the synthetic example queue.

Unexpected files that must **not** appear:
- production config
- real queues/manifests
- audit exports
- incident logs/state
- PDFs/DOCX/XLSX/ZIP evidence
- certificates or secrets

## 7. Make the first commit

Summary:

`Initial sanitized RecoveryGuard framework`

Description:

`Generic safety-first SharePoint deletion recovery orchestration framework with Supervisor/Worker recovery, health probes, reconciliation, monitoring, and sanitization controls.`

Click `Commit to main`.

## 8. Publish to GitHub

Click `Publish repository`.

Use:
- Name: `m365-recoveryguard`
- Description: `Safety-first M365 / SharePoint deletion recovery orchestration framework`
- **Keep this code private: CHECKED**
- Organization: `None` unless you intentionally want an organization to own it

Click `Publish Repository`.

## 9. Verify on github.com

Open the repository in your browser.

Confirm:
- repository says `Private`
- README renders correctly
- no client/customer names appear
- no real tenant URL appears
- no production logs, manifests, evidence or reports appear

## 10. Only consider public visibility after a second review

Before changing the repository to public:
- confirm employer/client/IP publication rights
- search the entire repository for customer/company names and private domains
- run the sanitization scanner again
- inspect Git commit history
- decide whether you actually want to add an open-source license
