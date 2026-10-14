# Multiple Claude accounts

How Sidelight shows Claude plan limits for more than one Claude account, and why it signs them in through Claude
Code rather than with a browser sign-in of its own. Researched October 2026 against Claude Code 2.1.299.

## Sidelight can't run its own Claude sign-in

The obvious design is the one Claude Code uses: OAuth with PKCE against `claude.com/cai/oauth/authorize`, with Claude
Code's client ID, keeping each account's refresh token in Sidelight's keychain. Several third-party usage trackers do
this, or scrape the claude.ai `sessionKey` cookie instead.

Anthropic's terms rule both out. From
[Legal and compliance › Authentication and credential use](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use):

- OAuth sign-in is meant for Claude Code and Anthropic's own apps.
- Third-party developers may not offer Claude.ai login in their own apps.
- They may not collect, store or intermediate Claude.ai credentials or session tokens. Sign-in has to go through
  Anthropic's own flow.

Anthropic started enforcing this in January 2026 and blocked third-party clients that used subscription OAuth.
Sidelight only reads usage and doesn't run inference, but it would still be storing and refreshing Claude.ai tokens
itself. So it doesn't, and it never will.

What the terms do allow, in the same section, is someone signing in to the unmodified Claude Code with their own
subscription.

## Claude Code supports multiple accounts

From [Authentication › Log in with multiple accounts](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts):
each account gets its own configuration folder, chosen with `CLAUDE_CONFIG_DIR`, for example
`alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'`. Each folder keeps its own settings, history and login.

What Claude Code derives from the folder (checked in the 2.1.299 binary and by experiment):

| | Default (`CLAUDE_CONFIG_DIR` unset) | `CLAUDE_CONFIG_DIR=<dir>` |
| --- | --- | --- |
| Keychain item (service) | `Claude Code-credentials` | `Claude Code-credentials-<hash>` |
| Fallback credentials file | `~/.claude/.credentials.json` | `<dir>/.credentials.json` |
| State (plan, email, `/usage` cache) | `~/.claude.json` | `<dir>/.claude.json` |

`<hash>` is the first 8 hex digits of the SHA-256 of `<dir>`. Claude Code hashes the variable exactly as it's set,
after NFC normalization, with no `~` expansion and no trailing-slash cleanup. An empty variable counts as unset.

## The design

A Claude account in Sidelight is an **app profile**: a Claude Code folder. Sidelight saves only the folder in
`config.json` (`kind: "appProfile"`, `folder: "/Users/…/.sidelight/claude/work"`). Claude Code keeps the sign-in and Sidelight
reads it, just as it already reads the default sign-in. Claude Code's own default sign-in stays the fixed
`claudeCode.app` account and remains the default.

**Adding an account** runs the unmodified `claude auth login --claudeai` with `CLAUDE_CONFIG_DIR` set to a new folder
named after the account, in `~/.sidelight/claude`, such as `~/.sidelight/claude/work`. The same account works in a
terminal with `CLAUDE_CONFIG_DIR=~/.sidelight/claude/work claude`, and Settings shows that command with a Copy button.

The folders sit in the home folder rather than Application Support, for three reasons:

- Each is a whole Claude Code folder. Once the account is used in a terminal it holds that account's history and
  settings, and uninstallers that clear `~/Library/Application Support/Sidelight` shouldn't take that with them.
- The terminal command stays short, with no spaces to escape.
- They all sit under one entry in the home folder, not one `~/.claude-*` folder each.

The location has to stay put: Claude Code names its keychain item after the path, so moving a folder means signing in
again.

**Choosing between opening and copying the link.** Claude Code opens its sign-in link by running `$BROWSER <url>`, or
`open` when `BROWSER` isn't set. Sidelight sets `BROWSER` to `Resources/claude-code-sign-in-link.sh`, which writes the
URL to a private temporary file instead of opening it. The sheet then offers **Open in Browser** and **Copy Link**.
That link redirects to Claude Code's local callback server, so signing in from any browser on this Mac finishes on its
own. Claude Code also prints a manual link, whose page shows a code to paste. The sheet keeps that link under
"Signing in on another device?" and pipes the pasted code to Claude Code's stdin. Once Claude Code prints
`Login successful`, `claude auth status --json` says who signed in.

**Adding a folder that's already signed in.** The sheet lists folders in `~/.sidelight/claude` and `~/.claude*` whose
state file names an account, and also lets you pick any folder. `claude auth status` confirms the sign-in before the folder is added.

**Signing in again** reruns the same flow in the account's folder. For the default account it runs with
`CLAUDE_CONFIG_DIR` unset.

**Removing** an account forgets the folder. "Remove and Sign Out" also runs `claude auth logout` there, which revokes
the sign-in and deletes Claude Code's keychain item. Sidelight never deletes a profile's folder, except one it created
for a sign-in that didn't finish.

**Reading usage** works per account, just as it used to for the one account. Each account has a `ClaudeCodeAccount`
that watches its state file and its own status line file, and can fetch Anthropic's usage endpoint as an opt-in. The
status line bridge writes `status-line-<hash>.json` when `CLAUDE_CONFIG_DIR` is set, so two profiles never overwrite
each other's limits.

## Limits

- **Token renewal.** Claude Code renews an access token only when that profile is used. An account that's only ever
  used through Sidelight shows "Sign-in expired" for Anthropic fetches after a few hours. Its cached `/usage` and
  status line data stay visible, and Sidelight doesn't hide them behind a sign-in prompt. No non-interactive
  `claude auth` command renews a token, and Sidelight renewing it itself is exactly what the terms forbid.
- **Shell spelling.** A folder spelled differently in a shell, such as with a trailing slash, hashes differently and is
  a different keychain item to Claude Code too.
- **Sessions widgets.** These still list sessions from `~/.claude` only.
