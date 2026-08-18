# Veilpath Contributor Guide

## Project overview

Veilpath is a native iOS and iPadOS container explorer and guarded file workspace
built around the `bad_query` sandbox-extension technique. The app is written in
SwiftUI and targets iOS/iPadOS 26 or newer. Treat it as security-research
software: keep browsing read-only by default, and route every explicit write
through the existing backup, validation, verification, and recovery safeguards.
Do not add unguarded or destructive file operations unless the project owner
explicitly changes that policy.

## Repository layout

- `Veilpath.xcodeproj/`: Xcode project and build settings.
- `Veilpath/BadQuery/`: low-level C bridge and code derived from `bad_query`.
- `Veilpath/Containers/`: container discovery and metadata resolution.
- `Veilpath/Core/`: sandbox access, file models, preview, and export.
- `Veilpath/Diagnostics/`: physical-device self-test and persisted JSON report.
- `Veilpath/Model/`: observable application state and orchestration.
- `Veilpath/ContentView.swift`: adaptive navigation, browser, settings, and diagnostics UI.
- `Veilpath/Localizable.xcstrings`: English source strings and Simplified Chinese translations.
- `docs/`: the static GitHub Pages site.
- `README.md`: canonical English documentation.
- `README.zh-CN.md`: Simplified Chinese documentation.

The Xcode project uses a file-system-synchronized source group. New files placed
under `Veilpath/` are normally discovered automatically; do not add redundant
PBX file references without confirming they are necessary.

## Build and validation

Use the `Veilpath` scheme. A signing-free simulator build is the baseline check:

```sh
xcodebuild \
  -project Veilpath.xcodeproj \
  -scheme Veilpath \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath /tmp/veilpath-build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Before committing, also run:

```sh
jq empty Veilpath/Localizable.xcstrings
git diff --check
```

Simulator builds validate compilation and UI only. The `bad_query` behavior,
container indexing, sandbox grants, preview, export, and diagnostic counts must
be validated on a compatible physical device. Do not describe simulator results
as proof that the exploit path works.

## Swift and SwiftUI conventions

- Prefer native SwiftUI and current APIs supported by the deployment target.
- Keep application state in the existing `@Observable` model; use `@Bindable`
  only in views that need writable bindings.
- Keep view-owned `@State` and `@FocusState` properties private.
- Use stable identities in `List` and `ForEach`.
- Use `Button`, `NavigationLink`, and `Link` for interactive elements and keep
  accessibility labels, hints, and selection traits accurate.
- Preserve the adaptive `NavigationSplitView` layout on both iPad and iPhone.
- Keep normal status information quiet. Surface access state in the sidebar
  only while verification is running or when attention is required; the full
  steady-state status belongs in Settings.
- Avoid decorative controls or icons with unclear actions.

## Localization

English is the app's source and default language. Simplified Chinese
(`zh-Hans`) is supported.

- Add every new user-facing string to `Veilpath/Localizable.xcstrings` with a
  complete `zh-Hans` translation.
- Pass string literals directly to SwiftUI text APIs so the compiler can extract
  them. Use `LocalizedStringResource` for known runtime choices and
  `String(localized:)` outside views.
- Do not localize file paths, UUIDs, bundle identifiers, raw diagnostic details,
  or other values whose exact representation is important.
- Keep `README.md` canonical and in English. Mirror material documentation
  changes in `README.zh-CN.md`, and preserve the language switch in both files.

## Security and compatibility constraints

- Browsing, preview, search, and export are intentionally read-only. Export must
  copy data into Veilpath's own cache before invoking the share sheet. Guarded
  edits, replacements, and restores must use the existing Version Vault path.
- Acquire sandbox extensions only for the operation that needs them and release
  each grant immediately afterward.
- Preserve the iOS 26 App Group compatibility path and keep
  `group.com.xnu.veilpath` synchronized between entitlements and source code.
- Do not silently broaden supported OS claims. Update compatibility statements
  only from verified device results.
- Preserve structured self-test output and schema compatibility. Increment the
  schema version only when the persisted report format or required checks change.
- The upstream `forcequitOS/bad_query` repository currently has no declared
  open-source license. Do not claim that derived files under `Veilpath/BadQuery/`
  are covered by a permissive license without upstream clarification.

## Change hygiene

- Keep edits focused and preserve unrelated worktree changes.
- Never commit DerivedData, build products, signing material, provisioning
  profiles, device logs, or local Xcode user state.
- Update the GitHub Pages site when public-facing positioning, compatibility, or
  screenshots materially change.
- Use concise, outcome-oriented commit messages and verify the worktree is clean
  after a successful push.
