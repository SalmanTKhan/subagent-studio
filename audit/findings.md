# Security findings register

No findings confirmed yet. Architectural concerns are hypotheses until tested.

| ID | Severity | Component | Reproduction | Impact | Remediation | Regression test | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |

## Initial hypotheses
- H-01: Local Git hooks alone cannot enforce remote branch protection.
- H-02: Bash-enabled reviewer may mutate files despite missing Edit/Write tools.
- H-03: Permission automation could approve unintended commands if scope is too broad.
- H-04: Parsing malformed review trailers or paths could permit bypasses.
- H-05: Installer/uninstaller may mishandle existing configuration or symlinks.

For every confirmed finding record the exact revision, commands, expected/actual behavior, and minimal non-destructive reproduction.
