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
- `Veilpath/Containers/AppNameResolver.swift`: bounded in-memory application-name resolution.
- `Veilpath/Core/AppStorageService.swift`: read-only size scanning and stable tree inventories.
- `Veilpath/Core/AppBackupLibrary.swift`: retained backups, guarded cache transactions, and recovery.
- `Veilpath/AppManagementView.swift`: App Storage and Backup Center flows.
- `Veilpath/Core/`: sandbox access, file models, preview, and export.
- `Veilpath/Diagnostics/`: physical-device self-test and persisted JSON report.
- `Veilpath/Model/`: observable application state and orchestration.
- `Veilpath/ContentView.swift`: adaptive navigation, browser, settings, and diagnostics UI.
- `Veilpath/Localizable.xcstrings`: English source strings and Simplified Chinese translations.
- `docs/`: the static GitHub Pages site.
- `README.md`: canonical English documentation.
- `README.zh-CN.md`: Simplified Chinese documentation.
- `tests/SandboxAccessTests.swift`: standalone backend and workspace regression checks.
- `scripts/package.py`: local Release IPA archive, signing, export, and validation.

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

These checks use test-only bridge stubs to validate safe sideloaded App Group
mapping, automatic fallback, legacy
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

The schema 23 Automatic run on that iPhone passed 23 checks, with 3
unsupported capabilities and no failures. Simulator local-fixture checks passed
16 checks. New coverage includes name resolution, read-only external storage
scanning, verified backup import, cache cleanup/restore, corruption refusal, and
interrupted recovery despite cancellation. All mutation tests use disposable
fixtures in Veilpath's own temporary directory, never another app's live data.
Schema 24 removes directory Markdown coverage and adds guarded backup deletion,
including interrupted removal, cancellation, journal/staging protection, and link
refusal. It passed the same 16 simulator and 23 supported device checks, with 3
unsupported iOS 26 capabilities and no failures.
The Release development IPA exported by `scripts/package.py` was also unpacked,
installed, and passed the same 23 supported checks on that device. Do not label
that as proof of AltStore, SideStore, Sideloadly, or Apple Ad Hoc installation.

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
- Keep the three primary sections Applications, Backups, and Settings. Use one
  application list and one app detail route; avoid duplicate full-app backup or
  restore entry points in file menus. Keep technical previews and file writes in
  Advanced Tools. Ordinary file browsing remains read-only.
- First launch performs access verification, not a full self-test. Storage scans
  are user initiated or limited to the opened app. Keep full diagnostics on demand.
- Do not reintroduce grid/list customization, screenshot-triggered prompts,
  filename web search, directory Markdown export, or font/cookie-specific viewers.

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
- Application-name database reads must remain bounded, read-only, and in memory.
  Never save or export the raw LaunchServices database. Match names against both
  independently discovered container paths and bundle identifiers; retain the
  exact identifier when a name cannot be established.
- Storage scans report logical file bytes, partial results, and skipped links.
  An incomplete scan must never enable cleaning. Cleanup may target only the
  typed `Library/Caches` and opt-in `tmp` roots; protect the active Veilpath root.
- Cache cleanup must create and re-extract a compressed, CRC/SHA-verified backup,
  recheck source stability, and use the journaled directory transaction. Never
  interrupt rollback on cancellation or overwrite unexpected concurrent data.
  Preserve backups and staging when safe recovery cannot be established.
- Keep Backup Center archives without automatic expiry. Import must validate
  before publication; export must verify and copy through the private share
  cache. Restores must verify the live target identity and archive, then create
  a fresh retained safety backup. Keep file-removal size, archive size, and
  measured available-space change distinct. Do not enable system file sharing.
- Owner-approved manual backup deletion is a separate permanent purge of one
  selected retained record in Veilpath's own library, after explicit UI confirmation.
  It must validate identity, location, and exact expected file types/contents,
  serialize with other app data operations, and reject active recovery journals,
  preserved staging, links, or unexpected files. Do not create a backup of a
  deleted backup. Restore complete interrupted deletions for confirmation; retain
  partial/unsafe remnants. Never use this exception for live app files.
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
- Keep the default App Group synchronized with entitlements. AltStore's
  `ALTAppGroups` may select only one accessible mapping with our exact group
  prefix and a valid 10-character team suffix. Prefer the accessible original
  group; never stage operations in an unrelated installer's group or resolve
  ambiguous mappings by guessing.
- Package only device Release builds. Keep signing profiles out of re-signing
  IPAs; preserve the requested App Group entitlement in their ad hoc signature.
  Signed development/Ad Hoc exports must retain valid profiles and be scoped to
  permitted devices. Never commit or automatically upload generated packages,
  signing assets, build logs, or per-device profile data. Respect LICENSING.md
  before public binary distribution. Do not advertise TrollStore compatibility
  while its supported OS range does not overlap the deployment target.
- Do not silently broaden supported OS claims. Update compatibility statements
  only from verified device results.
- Preserve structured self-test output and schema compatibility. Increment the
  schema version only when the persisted report format or required checks change.
  The current version is centralized in `SelfTestRunner.schemaVersion` (24).
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
