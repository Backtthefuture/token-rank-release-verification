# Token Rank native Windows release verification

Synthetic black-box checks for signed Token Rank 0.5.18 binaries. The runner checks identity and SHA-256, legacy and paginated accounting, shared-root subagent records, estimated context notifications, duplicate responses, real counter gaps, Chinese paths, scheduled tasks and PowerShell signed updates. Source metadata is pinned in release-config.json.

No private application source, credentials, conversation logs or real user usage are published here. Temporary fixtures and scheduled tasks are confined to a disposable Windows runner. The compiled regression executable is also pinned by SHA-256.
