# Token Rank public release verification

This repository contains only black-box acceptance scripts for downloadable Token Rank releases. It does not contain the private application source, production credentials, signing keys, or user usage records.

The Windows job uses a standard GitHub-hosted `windows-2022` runner. It validates the pinned release hash and identity, synthetic Codex accounting and duplicate handling, Windows PowerShell 5.1 exit codes, task registration and readback, and the signed update from 0.5.13 to 0.5.14. The temporary scheduled task is removed after the run.

No user account is connected. The final sync invoked by the ordinary update wrapper is expected to report that no account is configured; acceptance requires the preceding signed promotion and post-update check to succeed and the old binary to remain available.

Native Windows release acceptance is complete only when the workflow actually runs and passes. A queued or billing-blocked job is not acceptance evidence.
