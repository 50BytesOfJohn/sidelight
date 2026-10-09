# Releasing Sidelight

Releases are Developer ID–signed, notarized DMGs on [GitHub Releases](https://github.com/50BytesOfJohn/sidelight/releases).
This is direct distribution, with no Mac App Store submission or review. Apple notarization checks the signed app
for malware and gives Gatekeeper a ticket. Accessibility and Calendar access still need the user's permission;
signing keeps the app's identity stable across updates so those grants can persist.
Installed copies update themselves with [Sparkle](https://sparkle-project.org).

## How updates reach users

- The app's feed (`SUFeedURL` in `Resources/Info.plist`) is
  `https://github.com/50BytesOfJohn/sidelight/releases/latest/download/appcast.xml`, the `appcast.xml` attached to the
  **latest published** release. Drafts and pre-releases don't count, so publishing a release is what ships it.
- Sparkle compares `CFBundleVersion`, which counts main's first-parent history (`scripts/build-app.sh`). Release CI
  requires tags on main, a higher build number and a higher numeric version than the previous published release.
- Each update in the appcast is signed with an EdDSA key. The app only installs updates signed by the private key that
  matches `SUPublicEDKey` in `Resources/Info.plist`. Sparkle also checks the update's Apple code signature.
- Background checks run about once a day. An update found right after launch shows Sparkle's window. Later ones put a
  badge on the menu bar icon and an "Update to Sidelight …" item in its menu (Sparkle's *gentle reminders*).
- Debug builds (`make dev`) never check for updates.

## Cutting a release

1. Pick the version and write the release notes in Markdown. They become the tag's message, the GitHub release text
   and the notes in the app's update window.
2. Tag and push:

   ```sh
   git tag -a v0.2.0 --cleanup=whitespace -F notes.md
   git push origin v0.2.0
   ```

   `--cleanup=whitespace` keeps Markdown headings, which git otherwise strips as `#` comments.

   A lightweight tag (no message) falls back to GitHub's generated list of merged pull requests.
3. The [Release workflow](../.github/workflows/release.yml) validates the tag and runs `make check` before the signing
   job can access the `release` environment. Then `scripts/release.sh` builds,
   signs and notarizes the app, packs it into a notarized DMG, generates the signed appcast and attaches everything
   to a **draft** release. It checks Gatekeeper, both stapled tickets, the feed metadata and the DMG's EdDSA signature.
   CI also retains the installer, feed and debug symbols as an Actions artifact for 30 days. This usually takes
   5–15 minutes, mostly waiting for Apple's notary service; first submissions can take longer.
4. Download the DMG from the draft and try it. Then publish the draft (the web UI, or `gh release edit v0.2.0 --draft=false --latest`).

Use numeric tags such as `v0.1.0`. Prerelease suffixes are deliberately unsupported by this stable update feed.
Release runs are serialized. If a run fails, use GitHub's **Re-run failed jobs**, or:

```sh
gh workflow run release.yml --ref v0.2.0 --repo 50BytesOfJohn/sidelight
```

Retries can replace assets on an existing draft, but refuse to modify a published release. If Apple's service
times out, check the submission in `notarytool history` before retrying rather than repeatedly uploading it.

To fix the notes after tagging, delete the draft and the tag (`git push --delete origin v0.2.0`) and tag again. The
appcast is generated from the tag, so editing only the draft's text doesn't change what the app shows.

`make release VERSION=0.2.0` runs the same pipeline locally and writes to `build/release/` without publishing
anything. It's useful for checking signing and notarization.

## One-time setup

The repository's secrets live in a GitHub environment named `release`, which only `v*` tags can deploy to. A
workflow change pushed to any branch can't read them.

### 1. Sparkle signing key

Generated once with `generate_keys --account sidelight`. The private key is in the maintainer's login keychain, and
its public half is `SUPublicEDKey` in `Resources/Info.plist`.

> [!IMPORTANT]
> Back it up in a password manager. If it's lost, installed copies can't update themselves anymore.
>
> ```sh
> .build/artifacts/sparkle/Sparkle/bin/generate_keys --account sidelight -x sparkle-private-key.txt
> ```

On another Mac, import it with `generate_keys --account sidelight -f sparkle-private-key.txt`.

### 2. Developer ID certificate

The *Developer ID Application* certificate and its private key, exported for CI: in **Keychain Access → login → My
Certificates**, right-click *Developer ID Application: …* → **Export…**, and save it as `developer-id.p12` with a
strong password.

### 3. Notarization API key

On [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api), go to **Users and Access →
Integrations → App Store Connect API → Team Keys**. Generate a key with the **Developer** role and download the
`AuthKey_<KEY_ID>.p8` file (you can only download it once). Note the **Key ID** and the **Issuer ID** shown above the
list.

For local `make release`, store it in the keychain under the profile name the script uses:

```sh
xcrun notarytool store-credentials sidelight --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

### 4. GitHub environment and secrets

```sh
REPO=50BytesOfJohn/sidelight
gh api -X PUT "repos/$REPO/environments/release" --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" -f name='v*' -f type=tag

base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12 --env release --repo "$REPO"
gh secret set DEVELOPER_ID_P12_PASSWORD --env release --repo "$REPO"   # prompts for the password
gh secret set NOTARY_API_KEY --env release --repo "$REPO" < AuthKey_<KEY_ID>.p8
gh secret set NOTARY_KEY_ID --env release --repo "$REPO" --body <KEY_ID>
gh secret set NOTARY_ISSUER --env release --repo "$REPO" --body <ISSUER_ID>
gh secret set SPARKLE_PRIVATE_KEY --env release --repo "$REPO" < sparkle-private-key.txt
```

Remove temporary exported credentials after uploading them, keeping backups in a password manager. If a certificate
or API key is shared with another app, keep that app's existing credentials intact. Never commit them to Git.

An HTTP 403 mentioning a missing or expired agreement means the account holder must accept the pending agreement
at [Apple Developer](https://developer.apple.com/account). This also applies to distribution outside the App Store.
After accepting it, allow a few minutes for the notary service to recognize it and retry. No new signing key is needed.

## Renewing

Check the certificate's actual expiry in Keychain Access; its lifetime depends on how it was issued. Timestamped
releases signed before expiry keep working. Create a new
certificate for the same team and replace the `DEVELOPER_ID_P12` and `DEVELOPER_ID_P12_PASSWORD` secrets. Sparkle
accepts it because the EdDSA key stays the same. Never change the certificate and the EdDSA key in the same release.
