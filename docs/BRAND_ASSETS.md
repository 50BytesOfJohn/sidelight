# AI Usage provider logos

The AI Usage widget uses locally bundled artwork to identify the services it reads. The logos remain the
property of their respective owners; they are not Sidelight branding or an indication of endorsement.

Sources for `Sources/Sidelight/Widgets/AIUsage/ProviderLogos.xcassets`:

- **Codex:** `icon-codex-light.png` and `icon-codex-dark-color.png`, supplied in the official OpenAI desktop
  app (`ChatGPT.app/Contents/Resources`). These are the original app icons, including their transparent
  margins. See [OpenAI's brand guidelines](https://openai.com/brand/).
- **Claude:** the orange starburst path from the Claude wordmark on [claude.com](https://claude.com/),
  preserved unchanged in its own `125 × 125` SVG view box.
- **Cursor:** `CUBE_2D_LIGHT.svg` and `CUBE_2D_DARK.svg`, unchanged from the archive linked by
  [Cursor's brand guidelines](https://cursor.com/brand).

The asset catalog compiles the SVGs as vector artwork and selects light/dark variants automatically.
`Package.swift` processes it into the SwiftPM resource bundle, which `scripts/build-app.sh` embeds in the
signed app. Rendering the logos requires no downloads or installed provider apps.

The widget first looks for the resource bundle in the packaged app's resources directory, falling back to
`Bundle.module` for package builds. This also supports older SwiftPM accessors that do not search the app's
`Contents/Resources` directory.

Older SwiftPM build engines copy `.xcassets` without compiling them. The app packaging script compiles the
catalog with `actool` when `Assets.car` is missing and supplies macOS resource-bundle metadata when needed;
SwiftBuild's already compiled bundles are copied as-is.
