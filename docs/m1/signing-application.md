# Code signing application checklist (M1, submit by day 3)

Goal: get Claude Progress releases signed so Windows SmartScreen stops warning users. Two routes; apply to SignPath Foundation first (free for OSS), keep Azure as the fallback.

## First, what would actually be signed

The app is PowerShell scripts (`.ps1`), a Node script (`hook.js`, `settings-hooks.js`, `demo.js`) and `.cmd` launchers, shipped in a ZIP. There is no `.exe` or `.msi` today.

- `.ps1` files can carry an Authenticode signature.
- `.cmd` and `.js` files cannot be Authenticode-signed in the usual way.
- A ZIP itself is not signed; SmartScreen judges what is run from it.

So before applying, decide what you will ask them to sign: the `.ps1` files only, or a small signed installer (`.exe`/`.msi`) that wraps the current one. Whether each service signs scripts, and whether signed scripts calm SmartScreen for a `.cmd` launcher, is **check on their site** (and worth a quick test).

## SignPath Foundation (free for open source)

Eligibility as I understand it:

- [ ] OSI-approved license with no extra restrictions (MIT is fine).
- [ ] No proprietary components bundled in what gets signed. **Check on their site** for how bundled third-party binaries (such as a future Node bundle in M3) are treated.
- [ ] Project is public, actively maintained, and already released (have the v1.0.0 Release up first).
- [ ] Signed artifacts must be built from the public repo by a CI system they support (GitHub Actions), not on your own PC. **Check on their site** for the current list of supported CI systems and the required build setup.
- [ ] The project's own name, not a company name, appears as the publisher, with a note that the certificate is issued to SignPath Foundation. **Check on their site** for the exact wording.
- [ ] Some reputation or usage signal may be expected (stars, downloads, users). **Check on their site**; this is a new project, so say so plainly.
- [ ] The app must not do anything unwanted on users' machines; the installer preview and uninstaller help here.
- [ ] A privacy statement / no-telemetry statement may be required. **Check on their site.**

## Azure Trusted Signing (fallback)

- [ ] Paid monthly (low cost, not free). **Check on their site** for current pricing and whether the service has been renamed.
- [ ] Identity validation is required. Availability for individual developers (as opposed to organisations) has been limited to certain countries. **Check on their site** for current eligibility for your country.
- [ ] Needs an Azure subscription and account setup; signing is then done from CI or a local tool.

## Project information to have ready

| Item | Value |
| --- | --- |
| Project name | Claude Progress |
| Repository | https://github.com/nyuwawen/claude-progress |
| License | MIT (`LICENSE` in repo root) |
| Homepage | the repo README |
| Maintainer | solo maintainer (nyuwawen) |
| Platform | Windows 10 and 11, Windows PowerShell 5.1, Node.js |
| Latest release | v1.0.0 (Release page with ZIP and `.sha256`) |
| Artifacts to sign | decide first (see above): `.ps1` files and/or a wrapper installer |
| Build process | today: files packaged into a ZIP and a SHA256 file written. Needed: a GitHub Actions workflow that builds the ZIP from a tagged commit, so signing happens in CI. |
| Tests | `node --test "tests/unit/*.test.js"`, functional and security suites under `tests\` |
| What it changes on a PC | adds hooks to `~/.claude/settings.json` (backup first), a Task Scheduler entry, Start menu shortcuts, start with Windows; all shown in a preview and undone by the uninstaller |
| Network / telemetry | none |

## Ready-to-paste project description (about 90 words)

> Claude Progress is a free, open-source (MIT) Windows app that shows live progress for Claude Code and Claude desktop chats: the current step, a timeline of where the time went, and a learned estimate of time left. It uses Claude Code's documented hooks and a small WPF window in Windows PowerShell 5.1. Everything stays on the user's computer; there is no telemetry or network access. The installer previews every change and waits for consent, backs up the user's settings, and has a full uninstaller. We want signed releases so users can trust the download.

## After submitting

- [ ] Note the submission date and reference number in the M1 tracking issue.
- [ ] Keep the "unsigned for now" wording in the tester call and release notes until a signed release ships.
