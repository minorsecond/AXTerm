## Sentry setup (AXTerm)

### Configuration sources (in order)

- **Environment variable (recommended for Debug / local)**: set `SENTRY_DSN` in your scheme’s Environment Variables.
- **Info.plist (recommended for Release)**: set build setting `SENTRY_DSN` (per configuration) and it will be injected into the generated Info.plist key `SENTRY_DSN`.

The app reads DSN in this precedence order:

1. `SENTRY_DSN` environment variable
2. `SENTRY_DSN` Info.plist key

### In-app toggles (Settings → Sentry)

- **Enable Sentry reporting**: master switch (default OFF).
- **Send connection details (host/port tags)**: controls `kiss_host` / `kiss_port` tags (default OFF).
- **Send packet contents**: controls whether `infoText` and `rawHex` can be attached to events (default OFF).

### Release + environment tagging

- **environment**: from `SENTRY_ENVIRONMENT` (`development` in Debug config, `production` in Release config by default).
- **release**: `AXTerm@<CFBundleShortVersionString>+<CFBundleVersion>`
- **git_commit**: set from `SENTRY_GIT_COMMIT` / `GIT_COMMIT_HASH` / CI SHA env vars, with fallback to `git rev-parse`.

### Symbolication (dSYM upload)

To symbolicate macOS crashes, Sentry must have matching dSYMs for the build you shipped.

- **Ensure dSYMs are generated**: In Xcode, set Debug and Release `Debug Information Format` to **DWARF with dSYM File**.
- **Upload dSYMs to Sentry** (high-level):
  - In Sentry, locate your project’s **Debug Files / dSYM** upload instructions.
  - Use `sentry-cli` to upload the generated dSYMs from your `.xcarchive` (preferred), or from DerivedData if you’re testing locally.

AXTerm now includes `Scripts/upload-sentry-dsyms.sh` as a target build phase.
It uploads dSYMs when:

- `ENABLE_SENTRY_DSYM_UPLOAD = YES`
- `sentry-cli` is installed and in `PATH`
- auth is available via `SENTRY_AUTH_TOKEN` or `~/.sentryclirc`

Behavior by configuration:

- **Debug** (`axterm-dev`): strict upload (`REQUIRE_SENTRY_DSYM_UPLOAD = YES`), UUID verification off by default.
- **Release** (`axterm`): strict upload + strict UUID verification (`VERIFY_SENTRY_DSYM_UUIDS = YES`).

Release verification checks every UUID found in generated `.dSYM` bundles against Sentry's debug-files API and fails the build if any UUID is missing.

Recommended CI env/build settings:

- `SENTRY_AUTH_TOKEN`
- `SENTRY_ORG`
- `SENTRY_PROJECT`
- `SENTRY_GIT_COMMIT` (or `GIT_COMMIT_HASH`)
- optional tuning:
  - `SENTRY_DSYM_UPLOAD_WAIT_SECS` (default `120`)
  - `SENTRY_DSYM_VERIFY_RETRIES` (default `12`)
  - `SENTRY_DSYM_VERIFY_SLEEP_SECS` (default `5`)
