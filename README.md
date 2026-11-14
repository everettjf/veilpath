<p align="center">
  <img src="Veilpath/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Veilpath app icon">
</p>

<h1 align="center">Veilpath</h1>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  A native container explorer and guarded file workspace for iPhone and iPad,<br>
  with <a href="https://github.com/forcequitOS/bad_query"><code>bad_query</code></a> and <a href="https://github.com/forcequitOS/worse_query"><code>worse_query</code></a> access backends.
</p>

<p align="center">
  <a href="https://xnu.app/veilpath/">Website</a> ·
  <a href="https://discord.gg/eGzEaP6TzR">Discord</a> ·
  <a href="#compatibility">Compatibility</a> ·
  <a href="#building">Build</a> ·
  <a href="#acknowledgements">Acknowledgements</a>
</p>

> [!IMPORTANT]
> **Supported versions: iOS / iPadOS 26 through 27 beta 3.** The complete
> `bad_query` access path has been validated on a physical iPad Air running
> **iPadOS 27 beta 3 (`24A5380l`)**. Both backends and default automatic selection
> have also passed the supported checks on **iPhone 11, iOS 26.0.1 (`23A355`)**.
> A physical device is required; Simulator builds validate compilation, UI,
> and local fixtures only. The legacy `bad_query` proof of concept lists
> support through iOS 26.6.1 and iOS 27 beta 4, but those additional versions
> have not all been validated in Veilpath.

<table>
  <tr>
    <td width="68%"><img src="docs/assets/ipad-ui.webp" alt="Veilpath showing grouped application containers and a file list on iPad"></td>
    <td width="32%"><img src="docs/assets/iphone-ui.webp" alt="Veilpath showing the compact file browser on iPhone"></td>
  </tr>
</table>

## What is Veilpath?

Veilpath turns the `bad_query` and `worse_query` proofs of concept into a focused file-exploration
interface for the iOS and iPadOS versions where the technique applies. It
discovers otherwise inaccessible containers, resolves their identifiers, and
lets you inspect, export, and deliberately replace individual files with a
verified backup and restore path.

The name **Veilpath** combines **veil** and **path**: a route into data that is
normally hidden behind an app's sandbox boundary. It reflects the project's
focus on deliberate exploration while keeping every write guarded and
recoverable.

## Highlights

- Native SwiftUI interface that adapts to iPad and iPhone.
- Opens on an App library that can switch between a visual grid and a compact
  list, with the selected layout remembered across launches.
- Indexes Application, App Group, PluginKit, Internal Daemon, System Data, and
  System Group containers.
- Resolves container UUIDs to readable bundle identifiers using container
  metadata, and shows application names when a verified name is available.
- Opens App Storage and Backup Center directly from the App library. Scan file
  sizes, back up selected caches before cleaning, and keep full App and cache
  recovery backups together for verified import, export, and restoration.
- Falls back to `fsgetpath` inode discovery when a container root cannot be
  opened directly.
- Acquires a sandbox extension for each operation and releases it immediately
  afterward.
- Automatically chooses between `worse_query` and `bad_query`, with grant-time
  fallback and no manual backend selector.
- Browses with directory history, back/forward/up navigation, local filtering,
  recursive container search, and name/date/size sorting.
- Previews searchable plist and JSON trees, XML, text, images, hexadecimal data,
  and Mach-O architecture, dependency, signature, and entitlement details.
- Opens an app-specific iPad workspace with the current file list beside file
  properties, then a resizable 60–90% preview that can expand full screen.
- Uses a focused push flow on iPhone: App library, file list, then full-screen
  preview, with file information presented separately.
- Shows file metadata and SHA-256 hashes before export.
- Prepares files on demand for sharing, streaming large copies in 1 MiB chunks
  with progress, cancellation, verification, and automatic cache expiry.
- Archives the current folder or a selected folder as ZIP while preserving empty
  directories, honoring the hidden-file setting, and skipping symbolic links.
- Provides familiar multi-select file operations: copy, cut, paste, duplicate,
  batch ZIP compression, ZIP/IPA extraction, and guarded deletion. Deletes first
  create a uniquely named recoverable safety archive. Batch operations report
  per-item failures and preserve failed selections or cut sources for retry.
- Extracts stored and Deflate ZIP entries with bounded streaming I/O. Extraction
  verifies paths, sizes, and CRC-32, checks free space, rejects encrypted links,
  oversized output, and suspicious expansion ratios, and cleans partial output
  when cancelled.
- Exports a complete Application data backup containing `Documents`, `Library`,
  `tmp`, and `manifest.json`. Every file is recorded with its SHA-256 digest.
- Restores complete App backups only after validating the bundle identifier,
  exact root structure, declared payload, file sizes, and every SHA-256. A newly
  created backup is extracted and verified before success is reported. Restore
  blocks Veilpath's own live container, checks staging space, and first preserves the
  current container as a safety backup, stages the replacement, and rolls back
  if the directory swap fails.
- Exports the current directory as Markdown, with optional recursive traversal.
- Keeps browsing read-only by default while allowing guarded JSON and plist
  edits, versioned backup and replacement, SHA-256 verification, and restore
  with a fresh safety backup.
- Includes an on-device diagnostics suite with a structured JSON report.

## App storage and backups

Open **App Storage** from the App library to scan application containers, sorted
by measured size. The breakdown separates Documents, Library data, Caches,
temporary files, and other files. These are logical file sizes, not allocated
disk usage. Scans are cancellable; unreadable or bounded scans are marked
partial and cannot enable cleaning.

Application names combine available system API results, localized names for
common Apple apps, and bounded, read-only LaunchServices metadata matching.
Database names must match both the independently discovered container path and
bundle identifier. Parsing stays in memory; the raw database is neither saved
nor exported. Unknown names retain their exact bundle identifier. Name coverage
depends on the device and OS build.

In an app's storage details, **Back Up and Clean Caches** selects only
`Library/Caches`; `tmp` is opt-in. Close the target app first. Veilpath creates a
compressed recovery archive, re-extracts it, verifies CRC-32 and SHA-256, and
checks that the source has not changed before replacing the selected roots.
Documents and app settings remain outside this operation. Links and unsupported
files stop cleanup. The current recovery archive limit is 4 GB and 65,535 ZIP
entries. Veilpath's own active data container is protected.

Cleanup uses staged directory renames and a persisted journal. Interrupted
transactions are recovered before further app data operations; unexpected
concurrent data stops recovery and preserves the backup and staged files.
Cancellation does not interrupt rollback. Results distinguish source bytes
removed, recovery archive size, and the measured change in available space.
Keeping a recovery copy consumes storage, so the removed byte count is not a
promise of net free space.

**Backup Center** keeps full App backups and cache recovery archives in
Veilpath's own Documents directory without automatic expiry. It can create
backups, import supported ZIP backups after complete validation, export an
individual verified archive through Veilpath's share cache, and restore to a
currently matching app container. Restore creates a fresh safety backup in the
same center, labeled **Before Restore**. Full App backups contain Documents,
Library, and tmp with a SHA-256 manifest; symbolic links are excluded and their
count is shown when known. These are container file backups, not complete device
or Keychain backups. Retained archives also need space on the device.

Wallpapers and themes are reserved for a later phase. MobileGestalt modification
tools are not part of this workflow and require separate model and OS validation.

## Compatibility

Veilpath's stated support range is intentionally limited to versions covered by
its implementation and testing. **Do not assume that a newer beta or release is
compatible solely because the app builds.** Run the on-device self-test after
installing Veilpath; private Container Manager behavior may change between OS
builds.

| Platform | Target | Validation |
| --- | --- | --- |
| iPadOS | 27 beta 3 (`24A5380l`) | Fully tested on physical iPad Air (`iPad15,3`) |
| iOS / iPadOS | 26.x | Deployment target and App Group compatibility path |
| iPhone 11 | 26.0.1 (`23A355`) | Schema 23 Automatic: 23 passed, 3 unsupported, 0 failed; earlier schema 22 verified both forced backends |
| iPhone | 27 beta 3 (`24A5390f`) | Fully tested on physical iPhone 17 Pro (`iPhone18,1`) |
| Simulator | 26–27 | UI and local fixtures only; both access backends require a physical device |

The legacy bad_query upstream currently describes support through iOS 26.6.1 and iOS
27 beta 4. Veilpath deliberately documents the narrower range that has been
implemented and validated here: **iOS/iPadOS 26 through 27 beta 3**. Versions
outside this range are unsupported until confirmed by physical-device testing.

### Access backends

Veilpath automatically chooses its access backend. It initially prefers
worse_query, remembers a working backend for each container category during the
session, and falls back to bad_query when acquiring access fails. There is no
manual backend selector, and preferences saved by earlier builds are ignored.
The last backend that actually granted access is recorded in Diagnostics.
Debug builds retain backend overrides for regression testing only.

Both backends keep per-operation grants and share the existing backup,
validation, verification, and rollback safeguards. A failed file operation is
never replayed through another backend. worse_query requires a usable signed
App Group for every request; Veilpath preserves its cache directory by renaming
it before staging the temporary link, serializes requests, and recovers an
interrupted workspace before use. Original cache contents are never deleted.

The worse_query upstream declares iOS 26.0–26.7.2 and 27.2 support. That is an
upstream claim, not an expanded Veilpath compatibility guarantee. On iOS 26,
System Data and System Group capabilities remain unavailable. On a physical
iPhone 11 running iOS 26.0.1 (`23A355`), developer tests of both forced backends
and default automatic selection passed the supported
schema 22 checks, including external App Group metadata preview/export and
temporary-fixture backup/restore tests. Automatic selected worse_query. The new
backend has not yet been verified in Veilpath on iOS 27 devices.

### Physical-device diagnostics

Veilpath includes an on-device regression suite that verifies sandbox access,
container discovery, structured preview, file analysis, Mach-O parsing,
streamed sharing, ZIP policy, stored and Deflate extraction, multi-item file
operations, cancellation cleanup, Markdown export, guarded editing, complete
App backup and rollback-safe restore, and local search. Schema 23 adds bounded
application-name parsing, read-only on-device storage scanning, and recoverable
cache cleanup with import, restore, interrupted recovery, and corruption tests.
The final iPhone 11 automatic-mode run passed 23 checks, with 3 unsupported iOS 26
capabilities and no failures. The simulator passed 16 local-fixture checks.
Mutation tests use Veilpath's own disposable fixtures; other apps are only scanned
read-only. The new app-management flows have physical-device validation on iOS
26.0.1 only. Reports retain the selected and last granted backends, and older
reports remain decodable. Results are written to
`Documents/veilpath-self-test.json` inside Veilpath's own data container. Container
counts are intentionally not presented as project-wide metrics because they
depend entirely on the apps and system state of each device.

## Building

### Requirements

- Xcode 27 beta
- iOS or iPadOS 26.0 or newer
- An Apple development team for device signing
- A physical device for testing sandbox access

### Steps

1. Clone the repository:

   ```sh
   git clone https://github.com/everettjf/veilpath.git
   cd veilpath
   ```

2. Open `Veilpath.xcodeproj`.
3. Select the `Veilpath` scheme and an iPhone or iPad destination.
4. Choose your development team under **Signing & Capabilities**.
5. Build and run.

Veilpath uses the App Group identifier `group.com.xnu.veilpath` for every
worse_query request and the legacy iOS 26 App Group access path. If you build under a different bundle identifier or
team, replace it with an App Group owned by your account in both
`Veilpath/Veilpath.entitlements` and `Veilpath/Core/SandboxAccessClient.swift`.

The backend and workspace regression checks can also run on macOS without
a device (using test-only bridge stubs):

```sh
xcrun swiftc -D DEBUG Veilpath/Core/WorseQueryWorkspace.swift \
  Veilpath/Core/SandboxAccessClient.swift tests/SandboxAccessTests.swift \
  -o /tmp/veilpath-access-tests
/tmp/veilpath-access-tests
```

## Project structure

```text
Veilpath.xcodeproj/          Xcode project
Veilpath/
  BadQuery/                 Legacy C sandbox-extension primitive
  WorseQuery/               App Group query bridge and upstream license
  Containers/               Container indexing and metadata resolution
  Core/                     File access, preview, storage, guarded backup and recovery
  Diagnostics/              On-device regression suite
  Model/                    Observable application state
  ContentView.swift         Adaptive iPad/iPhone interface
  AppManagementView.swift   App Storage and Backup Center
docs/                       GitHub Pages website
tests/                      Standalone backend and workspace regression checks
```

Contributor instructions, validation commands, and access safeguards are in
[`AGENTS.md`](AGENTS.md). Keep the English and Simplified Chinese documentation
and the GitHub Pages site aligned when changing public behavior or compatibility.

## Safety and scope

Veilpath is experimental security-research software. It relies on private APIs
and behavior that can differ between OS builds. Use it only on devices and data
you own or are explicitly authorized to test.

Browsing, previews, search, and export remain read-only. Write operations require
an explicit user action. Structured edits use a temporary draft, validation,
Version Vault history, and SHA-256 verification. File deletion first creates a
recoverable ZIP; operation safety archives are retained for up to 30 days with
at most 10 archives in each category. This expiry policy does not apply to
Backup Center's retained App and cache recovery backups. Complete App restore validates the manifest and every payload
hash, saves the current `Documents`, `Library`, and `tmp`, stages the replacement,
then performs a rollback-capable directory swap. This is still sensitive research
software; an in-app backup reduces risk but is not a substitute for a device
backup. Diagnostics report failures explicitly instead of assuming a path is
accessible.

## Acknowledgements

Veilpath exists because of the original
[`forcequitOS/bad_query`](https://github.com/forcequitOS/bad_query) sandbox
escape proof of concept. Thank you to **forcequitOS** and the project's
contributors for researching the issue and publishing a clear implementation
for the community.

The low-level container-query approach in Veilpath is derived from that work.
Please credit and support the upstream project when reusing or extending it.

The additional [`forcequitOS/worse_query`](https://github.com/forcequitOS/worse_query)
backend is derived from Taj C (forcequit)'s work and retains its GPL-3.0-or-later
notice and license in `Veilpath/WorseQuery/`.

## Licensing status

See [`LICENSING.md`](LICENSING.md) for the exact file boundary, release checklist,
and a ready-to-send upstream clarification request.

The upstream `bad_query` repository does not currently declare an open-source
license. Consequently, the derived files under `Veilpath/BadQuery/` are **not**
implicitly covered by a permissive license, and this repository intentionally
does not claim otherwise.

Before assigning a single open-source license to the complete repository,
obtain permission or a license clarification from the upstream author. The
remaining original Veilpath code can be licensed separately once that boundary
is documented explicitly.

## Disclaimer

This project is provided for research and development. There is no warranty of
compatibility, reliability, or fitness for a particular purpose. Apple can
change or remove the private behavior Veilpath depends on at any time.
