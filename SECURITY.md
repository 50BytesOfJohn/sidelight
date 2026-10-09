# Security policy

## Supported versions

Sidelight hasn't had its first release yet. Security fixes go to `main` and to the next release only.

## Reporting a vulnerability

**Please don't report security issues in public issues, discussions or pull requests.**

Report privately through GitHub instead:
[**Report a vulnerability**](https://github.com/50BytesOfJohn/sidelight/security/advisories/new). Include
what you found, how to reproduce it, and the impact you think it has.

This is a volunteer project, so responses are best-effort. You should hear back within a week. Once a fix
ships, we'll publish an advisory and credit you, unless you'd rather stay anonymous.

## What's in scope

Sidelight runs with privileges worth protecting, so these areas matter most:

- **Accessibility access.** Sidelight uses it to move and resize other apps' windows.
- **The local agent-event server.** It listens on `127.0.0.1:47821` (loopback only) and accepts
  unauthenticated `POST /event` requests that are displayed in the Agents widget.
- **External tools.** Sidelight launches `codex` and `media-control` from your `PATH` and parses their
  output, and reads Codex session files in `~/.codex/sessions`.
- **Configuration.** It reads and live-reloads `~/Library/Application Support/Sidelight/config.json`.

Problems that need an attacker who already has full control of your user account (for example, one who can
replace binaries on your `PATH`) are generally out of scope.
