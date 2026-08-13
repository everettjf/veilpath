<p align="center">
  <img src="Vellune/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Vellune app icon">
</p>

<h1 align="center">Vellune</h1>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  A native, read-only container explorer for iPhone and iPad,<br>
  built around the <a href="https://github.com/forcequitOS/bad_query"><code>bad_query</code></a> sandbox escape.
</p>

<p align="center">
  <a href="https://xnu.app/vellune/">Website</a> ·
  <a href="#compatibility">Compatibility</a> ·
  <a href="#building">Build</a> ·
  <a href="#acknowledgements">Acknowledgements</a>
</p>

> [!IMPORTANT]
> **Supported versions: iOS / iPadOS 26 through 27 beta 3.** The complete
> `bad_query` access path has been validated on a physical iPad Air running
> **iPadOS 27 beta 3 (`24A5380l`)**. A physical device is required; Simulator
> builds validate only compilation and UI. The upstream proof of concept lists
> support through iOS 26.6.1 and iOS 27 beta 4, but those additional versions
> have not all been validated in Vellune.

![Vellune running on iPad](docs/assets/ipad-ui.png)

## What is Vellune?

Vellune turns the `bad_query` proof of concept into a focused file-exploration
interface for the iOS and iPadOS versions where the technique applies. It
discovers otherwise inaccessible containers, resolves their identifiers, and
lets you inspect and export files without enabling arbitrary writes.

The name **Vellune** is an invented word inspired by **veil** and **lune**
(French for “moon”). Its intended image is *looking through a veil at what was
previously hidden*—a fitting metaphor for exploring data beyond an app's normal
sandbox boundary.

## Highlights

- Native SwiftUI interface that adapts to iPad and iPhone.
- Indexes Application, App Group, PluginKit, Internal Daemon, System Data, and
  System Group containers.
- Resolves container UUIDs to readable bundle identifiers using container
  metadata.
- Falls back to `fsgetpath` inode discovery when a container root cannot be
  opened directly.
- Acquires a sandbox extension for each operation and releases it immediately
  afterward.
- Previews text, JSON, property lists, and images.
- Stages files inside Vellune's cache before presenting the system share sheet.
- Includes an on-device diagnostics suite with a structured JSON report.
- Intentionally read-only: destructive container operations are not exposed.

## Compatibility

Vellune's stated support range is intentionally limited to versions covered by
its implementation and testing. **Do not assume that a newer beta or release is
compatible solely because the app builds.** Run the on-device self-test after
installing Vellune; private Container Manager behavior may change between OS
builds.

| Platform | Target | Validation |
| --- | --- | --- |
| iPadOS | 27 beta 3 (`24A5380l`) | Fully tested on physical iPad Air (`iPad15,3`) |
| iOS / iPadOS | 26.x | Deployment target and App Group compatibility path |
| iPhone | 26–27 beta 3 | Adaptive UI builds and simulator validation |
| Simulator | 26–27 | UI only; `bad_query` requires a physical device |

The upstream project currently describes support through iOS 26.6.1 and iOS
27 beta 4. Vellune deliberately documents the narrower range that has been
implemented and validated here: **iOS/iPadOS 26 through 27 beta 3**. Versions
outside this range are unsupported until confirmed by physical-device testing.

### Physical-device diagnostics

Vellune includes an on-device regression suite that verifies sandbox access,
container discovery, structured preview, file analysis, Mach-O parsing, safe
export, and local search. Results are written to
`Documents/vellune-self-test.json` inside Vellune's own data container. Container
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
   git clone https://github.com/everettjf/vellune.git
   cd vellune
   ```

2. Open `Vellune.xcodeproj`.
3. Select the `Vellune` scheme and an iPhone or iPad destination.
4. Choose your development team under **Signing & Capabilities**.
5. Build and run.

Vellune uses the App Group identifier `group.com.eevv.Vellune` for the iOS 26
App Group access path. If you build under a different bundle identifier or
team, replace it with an App Group owned by your account in both
`Vellune/Vellune.entitlements` and `Vellune/Core/BadQueryClient.swift`.

## Project structure

```text
Vellune.xcodeproj/          Xcode project
Vellune/
  BadQuery/                 C bridge and sandbox-extension primitive
  Containers/               Container indexing and metadata resolution
  Core/                     File access, preview, and export
  Diagnostics/              On-device regression suite
  Model/                    Observable application state
  ContentView.swift         Adaptive iPad/iPhone interface
docs/                       GitHub Pages website
```

## Safety and scope

Vellune is experimental security-research software. It relies on private APIs
and behavior that can differ between OS builds. Use it only on devices and data
you own or are explicitly authorized to test.

The user interface is intentionally read-only. Export creates a copy in
Vellune's cache; it does not modify the source file. Diagnostics report failures
explicitly instead of assuming a path is accessible.

## Acknowledgements

Vellune exists because of the original
[`forcequitOS/bad_query`](https://github.com/forcequitOS/bad_query) sandbox
escape proof of concept. Thank you to **forcequitOS** and the project's
contributors for researching the issue and publishing a clear implementation
for the community.

The low-level container-query approach in Vellune is derived from that work.
Please credit and support the upstream project when reusing or extending it.

## Licensing status

The upstream `bad_query` repository does not currently declare an open-source
license. Consequently, the derived files under `Vellune/BadQuery/` are **not**
implicitly covered by a permissive license, and this repository intentionally
does not claim otherwise.

Before assigning a single open-source license to the complete repository,
obtain permission or a license clarification from the upstream author. The
remaining original Vellune code can be licensed separately once that boundary
is documented explicitly.

## Disclaimer

This project is provided for research and development. There is no warranty of
compatibility, reliability, or fitness for a particular purpose. Apple can
change or remove the private behavior Vellune depends on at any time.
