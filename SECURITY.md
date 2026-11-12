# Security Policy

## Supported Versions

Security fixes are made on the latest release only. Please update to the
latest release before reporting.

| Version        | Supported |
| -------------- | --------- |
| Latest release | Yes       |
| Older releases | No        |

## Reporting a Vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub: on the repository page open the
**Security** tab and choose **Report a vulnerability**. Include the Spate
version, your operating system and browser, and the steps to reproduce.

You can expect an acknowledgement within 7 days. If the report is accepted, a
fix is released and the report is credited in the release notes unless you
prefer otherwise. If it is declined, you will get an explanation.

## Scope

Spate runs a local service on `127.0.0.1` (ports 8760 to 8762) that the
browser extension talks to, and a native messaging host that browsers start.
Reports about either, about how downloaded file names and paths are handled,
and about the installers are all in scope.
