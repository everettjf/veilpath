# Veilpath Contributor Guide

## Project overview

Veilpath is a native iOS and iPadOS container explorer and guarded file workspace
built around the `bad_query` and `worse_query` sandbox-extension techniques. The app is written in
SwiftUI and targets iOS/iPadOS 26 or newer. Treat it as security-research
software: keep browsing read-only by default, and route every explicit write
through the existing backup, validation, verification, and recovery safeguards.
Do not add unguarded or destructive file operations unless the project owner
explicitly changes that policy.

## Repository layout

- `Veilpath.xcodeproj/`: Xcode project and build settings.
- `Veilpath/BadQuery/`: low-level C bridge and code derived from `bad_query`.
- `Veilpath/WorseQuery/`: Objective-C query bridge derived from `worse_query` and its upstream license.
- `Veilpath/Core/SandboxAccessClient.swift`: automatic backend selection and operation-scoped grants.
- `Veilpath/Core/WorseQueryWorkspace.swift`: App Group cache preservation, locking, and recovery.
- `Veilpath/Containers/`: container discovery and metadata resolution.
- `Veilpath/Core/`: sandbox access, file models, preview, and export.
- `Veilpath/Diagnostics/`: physical-device self-test and persisted JSON report.
- `Veilpath/Model/`: observable application state and orchestration.
- `Veilpath/ContentView.swift`: adaptive navigation, browser, settings, and diagnostics UI.
- `Veilpath/Localizable.xcstrings`: English source strings and Simplified Chinese translations.
- `docs/`: the static GitHub Pages site.
- `README.md`: canonical English documentation.
- `README.zh-CN.md`: Simplified Chinese documentation.
- `tests/SandboxAccessTests.swift`: standalone backend and workspace regression checks.

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

Run the standalone backend and workspace checks when changing access code:

```sh
xcrun swiftc -D DEBUG Veilpath/Core/WorseQueryWorkspace.swift \
  Veilpath/Core/SandboxAccessClient.swift tests/SandboxAccessTests.swift \
  -o /tmp/veilpath-access-tests
/tmp/veilpath-access-tests
```

These checks use test-only bridge stubs to validate automatic fallback, legacy
preference handling, grant lifetime, concurrent staging, cache preservation,
and interrupted-workspace recovery. They do not exercise either exploit.

Simulator builds validate compilation, UI, and local fixtures only. Both backends,
container indexing, sandbox grants, preview, export, and diagnostic counts must
be validated on a compatible physical device. Do not describe simulator results
as proof that the exploit path works.

The iPhone 11 on iOS 26.0.1 (`23A355`) passed all 20 supported schema 22 checks
with each forced backend and with default automatic selection; 3 checks were
unsupported and none failed. This includes external App Group metadata preview
and export. Backup/restore write tests use Veilpath's own temporary fixtures.
Do not infer `worse_query` compatibility on iOS 27 from the older `bad_query`
device results.

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
- Keep production backend selection automatic. Prefer `worse_query`, remember
  working backends by container category for the session, and fall back only
  while acquiring a grant. Never replay a failed file operation through another
  backend. Do not add a user-facing selector or honor old manual preferences;
  backend overrides are for Debug regression testing only.
- Route all access through `SandboxAccessClient`; keep the selected and actual
  backend details in Diagnostics rather than adding routine sidebar status.
- `worse_query` requires a usable signed App Group on every supported OS.
  Preserve its original `Library/Caches` contents by renaming, serialize staging
  across threads and processes, and restore before returning a grant. Recover
  interrupted staging before use, and stop on unsafe recovery states. Never
  copy the upstream example's directory deletion into the app.
- A consumed root grant does not prove directory-listing permission. Preserve
  inode discovery fallback when opening or listing a container root fails.
- Preserve the iOS 26 App Group compatibility path and keep
  `group.com.xnu.veilpath` synchronized between entitlements and source code.
- Do not silently broaden supported OS claims. Update compatibility statements
  only from verified device results.
- Preserve structured self-test output and schema compatibility. Increment the
  schema version only when the persisted report format or required checks change.
  The current version is centralized in `SelfTestRunner.schemaVersion` (22).
  Backend report fields are optional when decoding older reports; unsupported
  OS capabilities must remain distinct from failed checks.
- The upstream `forcequitOS/bad_query` repository currently has no declared
  open-source license. Do not claim that derived files under `Veilpath/BadQuery/`
  are covered by a permissive license without upstream clarification.
- Preserve the `worse_query` copyright, modification notices, and
  GPL-3.0-or-later license in `Veilpath/WorseQuery/`. Its explicit license does
  not resolve the separate `bad_query` boundary documented in `LICENSING.md`.

## Change hygiene

- Keep edits focused and preserve unrelated worktree changes.
- Never commit DerivedData, build products, signing material, provisioning
  profiles, device logs, or local Xcode user state.
- Update the GitHub Pages site when public-facing positioning, compatibility, or
  screenshots materially change.
- Use concise, outcome-oriented commit messages and verify the worktree is clean
  after a successful push.
