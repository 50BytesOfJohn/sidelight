# Contributing to Sidelight

Thanks for helping out! Bug reports, ideas, new widgets, fixes and docs are all welcome. Please read and
follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Sidelight hasn't had its first release yet, so things move fast. The `config.json` format, names and APIs
change freely, with no migrations or backward compatibility. Don't spend effort preserving old behavior.

## Before you start

- **Small fixes** (typos, obvious bugs, small polish): just open a pull request.
- **Anything bigger** (a new widget, a new setting, a change to how the panel or window avoidance behaves):
  open an issue first so we can agree on the approach before you put in the time.
  [docs/VISION.md](docs/VISION.md) explains what Sidelight is trying to be.

Two principles shape most review feedback:

- **Idle cost stays near zero.** Sidelight runs all the time. Anything that polls, animates continuously or
  redraws often needs a reason and a measurement (Activity Monitor or Instruments, before and after).
- **It has to look great.** Aesthetics are a core feature. UI changes need screenshots or a short recording.

## Development setup

You need an Apple Silicon Mac with **macOS 26** and **Xcode 26.4 or newer**. There are no other dependencies.

```sh
make dev      # debug build, runs in the foreground with logs in this terminal (Ctrl-C quits)
make run      # release build of build/Sidelight.app, then launch it
make test     # unit tests
make format   # format all Swift sources in place
make check    # lint + build + test: what CI runs, and must pass before a PR is merged
```

Use `make` rather than calling `swift build` yourself. The Makefile points `DEVELOPER_DIR` at Xcode, which
SwiftUI's macros need.

**Keeping macOS permissions between builds.** Sidelight needs Accessibility access (to move other windows)
and optionally Calendar access. macOS ties those grants to the app's code signature. If you have no signing
identity, every build is ad-hoc signed and macOS asks again each time. To fix that, sign in to Xcode with any
Apple ID (*Xcode → Settings → Accounts*; a free account works) and create an *Apple Development*
certificate. `scripts/build-app.sh` picks it up automatically, or you can choose one with `SIGN_IDENTITY`.

## Making a change (fork and pull request)

You can't push to this repository directly. Instead, you work on your own copy (a *fork*) and open a pull
request asking for your branch to be merged.

1. **Fork** the repository with the *Fork* button on GitHub, then clone your fork:

   ```sh
   git clone https://github.com/<you>/sidelight.git
   cd sidelight
   git remote add upstream https://github.com/50BytesOfJohn/sidelight.git
   ```

   With the [GitHub CLI](https://cli.github.com), `gh repo fork 50BytesOfJohn/sidelight --clone` does all of
   this in one step.

2. **Create a branch** off an up-to-date `main`:

   ```sh
   git fetch upstream
   git switch -c fix-clock-flicker upstream/main
   ```

3. **Make your change.** Keep it focused: one fix or feature per pull request. Add or update tests in
   `Tests/SidelightCoreTests` for logic in `SidelightCore`, and try the change in the real app with `make dev`.

4. **Run `make check`** and fix anything it reports. CI runs the same command and treats warnings as failures.

5. **Commit** with a short, imperative summary line, like the existing history does: *"Add battery widget"*,
   *"Fix panel flicker when switching Spaces"*. Explain the *why* in the body if it isn't obvious.

6. **Push and open the pull request:**

   ```sh
   git push -u origin fix-clock-flicker
   gh pr create --repo 50BytesOfJohn/sidelight   # or use the "Compare & pull request" button on GitHub
   ```

   Fill in the template, link the issue it closes (`Closes #123`), and leave *Allow edits from maintainers*
   checked so small fixups can be pushed to your branch directly.

7. **Keep it current.** If `main` moves on while your PR is open, rebase rather than merge:

   ```sh
   git fetch upstream
   git rebase upstream/main
   git push --force-with-lease
   ```

PRs are squash-merged, so don't worry about tidying intermediate commits.

## Code guidelines

- [AGENTS.md](AGENTS.md) holds the rules every change follows.
- The [`sidelight-conventions`](.agents/skills/sidelight-conventions/SKILL.md) skill covers where code goes
  and how services and widgets are wired. [adding-a-widget.md](.agents/skills/sidelight-conventions/adding-a-widget.md)
  is the checklist for a new widget.
- The README's [Architecture](README.md#architecture) section maps out the source tree and data flow.
- Formatting is enforced by `swift format` (`.swift-format`). Run `make format` and don't fight the formatter.

## Using AI coding agents

AI-assisted contributions are welcome, and Sidelight is set up for them: `AGENTS.md` and the skills in
`.agents/skills/` are read automatically by Claude Code, Codex and similar tools. You are still the author.
Understand every line you submit, run it, and make sure the PR description reflects what actually changed.

## Reporting bugs and security issues

- Bugs and feature ideas: [open an issue](https://github.com/50BytesOfJohn/sidelight/issues/new/choose).
- Questions and open-ended ideas: [Discussions](https://github.com/50BytesOfJohn/sidelight/discussions).
- Security vulnerabilities: **don't open a public issue.** See [SECURITY.md](SECURITY.md).

## License

Sidelight is [MIT licensed](LICENSE). By submitting a contribution, you agree that it is licensed under the
same terms.
