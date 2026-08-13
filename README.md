# Vellune

Vellune is an iPhone and iPad container explorer built around the `bad_query`
sandbox escape for iOS/iPadOS 26 through iOS/iPadOS 27 beta 3.

## Current scope

- Discovers application data containers with `fsgetpath` inode scanning.
- Resolves container UUIDs to bundle identifiers using container metadata.
- Indexes application, App Group, extension/plugin, internal daemon, system data,
  and System Group containers.
- Acquires sandbox extensions per operation and releases them immediately.
- Browses directories and previews text, JSON, property lists, and images.
- Copies an accessed file into Vellune's cache before presenting the share sheet.
- Generates a structured on-device regression report at
  `Documents/vellune-self-test.json`.

The current product UI is intentionally read-only. Arbitrary container writes
are not enabled by default.

## Project site

[Vellune on GitHub Pages](https://everettjf.github.io/vellune/)

## Requirements

- Xcode 27 beta
- iOS/iPadOS 26.0 or newer
- A physical device for `bad_query` validation

Simulator builds validate UI compatibility only; the sandbox escape is a
device-only capability.

## Build

Open `Vellune/Vellune.xcodeproj`, select an iPhone or iPad, and run the Vellune
scheme. The project uses automatic signing.

## Tested device

- iPad Air (`iPad15,3`), iPadOS 27.0 beta 3 (`24A5380l`)

The Diagnostics screen runs the regression suite on launch and exposes the
individual checks and timings.
