# Security and Safe Publication

The app uses MapKit and public government feeds without an embedded API key or TDX client secret. App Store Connect, GitHub and signing credentials belong in local credential storage or properly scoped CI secrets, never in source, assets, fixtures or documentation.

## Before Pushing

```sh
git status --short
git diff --cached --stat
python3 tools/audit_repository.py
gitleaks git --redact --no-banner
```

Gitleaks is a separately installed optional scanner, not an app dependency. Audit both the proposed tree and all history being pushed. The lightweight audit checks tracked file categories, SQLite text fields, signing settings, local home paths and PNG metadata. It complements secret scanning; it cannot prove all personal information or credentials are absent.

Do not commit private keys, certificate bundles, provisioning profiles, `.env` files, signing/export configuration, device logs, personal-location histories or upload archives. `.gitignore` is not a substitute for reviewing staged content. Use your own Apple signing team in Xcode or through a local command-line override; do not check in a personal team identifier.

Email may appear in commit attribution. Repository/bundle identifiers, public government URLs, agency names and published camera coordinates are intentional public information. Personal device IDs, routes and precise personal coordinates do not belong in public issues.

If a real credential is exposed, revoke/rotate it and investigate access. Removing it in a later commit does not clean earlier history. Do not post the secret in an incident report.

## Reporting

Use GitHub private vulnerability reporting when available, or contact the owner privately. Do not create public issues containing credentials, certificates, private-account details or personal locations. Include the affected version and a minimal sanitized reproduction. Incorrect-camera reports should cite the public dataset/record and official source, not a personal driving trace.
