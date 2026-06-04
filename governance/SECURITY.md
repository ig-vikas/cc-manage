# Security Policy

## Secret Handling

Never commit API keys, `.env` files, key maps, debug logs, active-profile files, or runtime profile files.

The v2 profile format stores only generated profile-wise key ids such as `CCKEY_<PROVIDER>_<PROFILE>_<RANDOM_ID>` in local runtime profile files. Actual key values belong in `.env` and must be redacted in logs, test output, and issue reports.

## Reporting Issues

If you find a security issue, do not open a public issue with secrets or exploit details. Report privately to the project maintainer and include:

- A short description of the issue.
- A minimal reproduction without real keys.
- Affected provider/profile mode.
- Relevant redacted logs.

## Expected Protections

- API keys are loaded from `.env`.
- Runtime profile files and key maps are ignored by Git.
- CLI output redacts secret values.
- Debug logs are opt-in.
- Provider errors are normalized without exposing headers or tokens.
- Migration backs up profiles before rewriting them.
