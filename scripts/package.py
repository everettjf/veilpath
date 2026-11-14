#!/usr/bin/env python3
"""Build local Release IPAs. Never upload packages or signing material."""

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GROUP_KEY = "com.apple.security.application-groups"
GROUP = "group.com.xnu.veilpath"


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def capture(*args):
    return run(*args, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def entitlements(app):
    return plistlib.loads(capture("codesign", "--display", "--entitlements", ":-", app))


def inspect_ipa(ipa, mode):
    with zipfile.ZipFile(ipa) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f"IPA CRC validation failed: {bad}")
        infos = [x for x in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", x)]
        if len(infos) != 1:
            raise ValueError("Expected one device application under Payload")
        info = plistlib.loads(archive.read(infos[0]))
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("The IPA must contain an iPhoneOS app, never a simulator build")
        prefix = infos[0].removesuffix("Info.plist")
        profile = prefix + "embedded.mobileprovision" in archive.namelist()
        if profile != (mode != "sideload"):
            raise ValueError("Unexpected embedded provisioning profile for this package mode")
        return info


def build(args):
    output = args.output.expanduser().resolve()
    # Artifacts contain signing state and belong outside the tracked source tree.
    if output == ROOT or ROOT in output.parents:
        raise ValueError("Choose an output directory outside the repository (for example /tmp/veilpath-packages)")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="veilpath-package-") as temporary:
        work = Path(temporary)
        archive = work / "Veilpath.xcarchive"
        log = output / f"{args.mode}-build.log"
        command = ["xcodebuild", "-project", ROOT / "Veilpath.xcodeproj", "-scheme", "Veilpath",
                   "-configuration", "Release", "-destination", "generic/platform=iOS",
                   "-derivedDataPath", work / "DerivedData", "-archivePath", archive]
        if args.mode == "sideload":
            command += ["CODE_SIGNING_ALLOWED=NO"]
        else:
            command += ["-allowProvisioningUpdates"]
            if args.team_id:
                command += [f"DEVELOPMENT_TEAM={args.team_id}"]
        print(f"Archiving Release for {args.mode}; log: {log}", flush=True)
        with log.open("w") as stream:
            run(*command, "archive", stdout=stream, stderr=subprocess.STDOUT)

        app = archive / "Products/Applications/Veilpath.app"
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        label = {"sideload": "resign", "development": "development", "ad-hoc": "ad-hoc"}[args.mode]
        stem = f"Veilpath-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}-{label}"
        if not re.fullmatch(r"[A-Za-z0-9._-]+", stem):
            raise ValueError("Unsafe version or build number")
        destination = output / (stem + ".ipa")
        metadata = output / (stem + ".json")
        checksum = output / (stem + ".sha256")
        if any(x.exists() for x in (destination, metadata, checksum)):
            raise FileExistsError("Package already exists; use a new output directory or a new version/build")

        if args.mode == "sideload":
            payload = work / "Payload"
            payload.mkdir()
            staged = payload / app.name
            run("ditto", app, staged)
            # The signature is deliberately ad hoc (no Apple identity). It carries
            # App Group entitlements so installers know what to provision when
            # re-signing. It is not an Apple Ad Hoc distribution signature.
            for profile in staged.rglob("embedded.mobileprovision"):
                profile.unlink()
            nested = [x for x in staged.rglob("*") if x.suffix in (".framework", ".dylib", ".appex") and not x.is_symlink()]
            if any(x.suffix == ".appex" for x in nested):
                raise ValueError("New app extensions need an explicit per-target signing configuration")
            for item in sorted(nested, key=lambda x: len(x.parts), reverse=True):
                run("codesign", "--force", "--sign", "-", "--timestamp=none", item)
            run("codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der",
                "--entitlements", ROOT / "Veilpath/Veilpath.entitlements", staged)
            signed_app = staged
            candidate = work / "candidate.ipa"
            run("ditto", "-c", "-k", "--keepParent", "--norsrc", payload, candidate)
        else:
            options = {"method": "debugging" if args.mode == "development" else "release-testing",
                       "destination": "export", "signingStyle": "automatic", "thinning": "<none>",
                       "manageAppVersionAndBuildNumber": False}
            if args.team_id:
                options["teamID"] = args.team_id
            options_path = work / "ExportOptions.plist"
            options_path.write_bytes(plistlib.dumps(options))
            exported = work / "Export"
            with log.open("a") as stream:
                run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", exported,
                    "-exportOptionsPlist", options_path, "-allowProvisioningUpdates",
                    stdout=stream, stderr=subprocess.STDOUT)
            candidates = list(exported.glob("*.ipa"))
            if len(candidates) != 1:
                raise ValueError("Xcode did not export exactly one IPA")
            candidate = candidates[0]
            unpacked = work / "Verified Export"
            run("ditto", "-x", "-k", candidate, unpacked)
            apps = list((unpacked / "Payload").glob("*.app"))
            if len(apps) != 1:
                raise ValueError("Expected one exported application")
            signed_app = apps[0]

        run("codesign", "--verify", "--deep", "--strict", signed_app)
        permissions = entitlements(signed_app)
        if permissions.get(GROUP_KEY) != [GROUP]:
            raise ValueError("Missing or changed App Group entitlement in the generated package")
        architectures = capture("xcrun", "lipo", "-archs", signed_app / info["CFBundleExecutable"]).decode().split()
        if architectures != ["arm64"]:
            raise ValueError(f"Unexpected device architectures: {architectures}")
        packaged_info = inspect_ipa(candidate, args.mode)
        for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "MinimumOSVersion"):
            if packaged_info[key] != info[key]:
                raise ValueError(f"Export changed {key}")
        hasher = hashlib.sha256()
        with candidate.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(chunk)
        digest = hasher.hexdigest()
        result = {"file": destination.name, "mode": args.mode, "requiresResigning": args.mode == "sideload",
                  "version": info["CFBundleShortVersionString"], "buildVersion": info["CFBundleVersion"],
                  "bundleIdentifier": info["CFBundleIdentifier"], "minOSVersion": info["MinimumOSVersion"],
                  "architectures": architectures, "entitlementKeys": sorted(permissions), "appGroups": [GROUP],
                  "size": candidate.stat().st_size, "sha256": digest,
                  "createdAt": datetime.now(timezone.utc).isoformat(),
                  "sourceCommit": capture("git", "-C", ROOT, "rev-parse", "HEAD").decode().strip(),
                  "sourceDirty": bool(capture("git", "-C", ROOT, "status", "--porcelain")),
                  "validation": "Archive, arm64, IPA CRC, signature structure, App Group entitlement; installer channels not certified"}
        shutil.copyfile(candidate, destination)
        metadata.write_text(json.dumps(result, indent=2) + "\n")
        checksum.write_text(f"{digest}  {destination.name}\n")
        print(f"Created {destination}\nSHA-256 {digest}", flush=True)
        if args.mode == "sideload":
            print("Re-sign with a valid App Group-capable profile before installation.")
        else:
            print("Install only on devices permitted by the embedded profile; keep this local testing package private.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["sideload", "development", "ad-hoc"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--team-id", help="Apple team for signed exports (defaults to the Xcode project)")
    args = parser.parse_args()
    if args.team_id and not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("--team-id must be a 10-character Apple team identifier")
    if args.mode == "sideload" and args.team_id:
        parser.error("--team-id is not used by a re-signing package")
    try:
        build(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Packaging failed: {error}") from error


if __name__ == "__main__":
    main()
