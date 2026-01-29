## Sentry setup (AXTerm)

### Configuration sources (in order)

- **Environment variable (recommended for Debug / local)**: set `SENTRY_DSN` in your scheme’s Environment Variables.
- **Info.plist (recommended for Release)**: set build setting `SENTRY_DSN` (per configuration) and it will be injected into the generated Info.plist key `SentryDSN`.

The app reads DSN in this precedence order:

1. `SENTRY_DSN` environment variable
2. `SentryDSN` Info.plist key

### In-app toggles (Settings → Sentry)

- **Enable Sentry reporting**: master switch (default OFF).
- **Send connection details (host/port tags)**: controls `kiss_host` / `kiss_port` tags (default OFF).
- **Send packet contents**: controls whether `infoText` and `rawHex` can be attached to events (default OFF).

### Release + environment tagging

- **environment**: `debug` in Debug builds, `release` otherwise.
- **release**: `AXTerm@<CFBundleShortVersionString>+<CFBundleVersion>`

### Symbolication (dSYM upload)

To symbolicate macOS crashes, Sentry must have matching dSYMs for the build you shipped.

- **Ensure dSYMs are generated**: In Xcode, set Release `Debug Information Format` to **DWARF with dSYM File**.
- **Upload dSYMs to Sentry** (high-level):
  - In Sentry, locate your project’s **Debug Files / dSYM** upload instructions.
  - Use `sentry-cli` to upload the generated dSYMs from your `.xcarchive` (preferred), or from DerivedData if you’re testing locally.

No build-phase scripts are required by AXTerm; you can add one later if you want automatic uploads on archive.

