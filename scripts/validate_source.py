#!/usr/bin/env python3
"""Validate the shared AltStore Classic/SideStore source without publishing anything."""

import argparse
import hashlib
import io
import json
import plistlib
import re
import zipfile
from datetime import datetime
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
SITE = "https://xnu.app/veilpath/"
SOURCE_URL = SITE + "source.json"
BUNDLE = "com.xnu.veilpath"
GROUP_KEY = "com.apple.security.application-groups"
RELEASES = "https://github.com/everettjf/veilpath/releases/download/"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fetch(url):
    with urlopen(Request(url, headers={"User-Agent": "Veilpath-Source-Validator"}), timeout=60) as response:
        require(response.geturl().startswith("https://"), "Download redirected away from HTTPS")
        return response.read()


def validate(source, online=False):
    require(source["identifier"] == "com.xnu.veilpath.source", "Keep the source identifier stable")
    require(source["sourceURL"] == SOURCE_URL, "Keep the subscription URL stable")
    require(source["name"] and isinstance(source["news"], list), "Missing source name/news")
    require(len(source["apps"]) == 1, "Expected one Veilpath listing")
    app = source["apps"][0]
    require(app["bundleIdentifier"] == BUNDLE, "Bundle identifier mismatch")
    for field in ("name", "developerName", "localizedDescription"):
        require(isinstance(app[field], str) and app[field], f"Missing app {field}")
    require("marketplaceID" not in app, "This is a Classic IPA source, not a PAL source")
    require(app["appPermissions"] == {"entitlements": [GROUP_KEY], "privacy": {}},
            "Review any change to the requested permissions against the actual IPA")
    for url in [source["iconURL"], app["iconURL"], *app["screenshots"]]:
        require(url.startswith(SITE + "assets/"), "Expected a website image")
        path = Path(url.removeprefix(SITE))
        require(".." not in path.parts and (ROOT / "docs" / path).is_file(), "Missing local source image")
        if online:
            require(fetch(url).startswith(b"\x89PNG\r\n\x1a\n"), "Expected a downloadable PNG")

    require(app["versions"], "Source must contain at least one published version")
    previous = None
    for version in app["versions"]:
        number, build = version["version"], version["buildVersion"]
        require(re.fullmatch(r"\d+\.\d+\.\d+", number), "Expected a three-component app version")
        require(re.fullmatch(r"\d+", build), "Expected a numeric build string")
        key = (*map(int, number.split(".")), int(build))
        require(previous is None or key < previous, "Versions must be unique and newest first")
        previous = key
        require(datetime.fromisoformat(version["date"].replace("Z", "+00:00")).tzinfo is not None,
                "Release date must include its time zone")
        filename = f"Veilpath-{number}-{build}-resign.ipa"
        expected_url = f"{RELEASES}v{number}/{filename}"
        require(version["downloadURL"] == expected_url, "Only versioned public re-signing IPAs are allowed")
        require(type(version["size"]) is int and version["size"] > 0, "Invalid IPA byte size")
        require(version["minOSVersion"] == "26.0", "Review OS compatibility before changing the minimum")
        if not online:
            continue

        metadata = json.loads(fetch(expected_url.removesuffix(".ipa") + ".json"))
        require(metadata["mode"] == "sideload" and metadata["requiresResigning"] is True,
                "Development and Apple Ad Hoc packages must remain private")
        require(metadata["sourceDirty"] is False, "Published packages must come from a clean source commit")
        require(metadata["file"] == filename and metadata["bundleIdentifier"] == BUNDLE,
                "Build metadata identity mismatch")
        require(metadata["appGroups"] == ["group.com.xnu.veilpath"] and
                metadata["entitlementKeys"] == app["appPermissions"]["entitlements"],
                "Build metadata permissions mismatch")
        for field in ("version", "buildVersion", "minOSVersion", "size"):
            require(metadata[field] == version[field], f"Build metadata mismatch: {field}")

        ipa = fetch(expected_url)
        require(len(ipa) == version["size"], "Downloaded IPA size mismatch")
        require(hashlib.sha256(ipa).hexdigest() == metadata["sha256"], "Downloaded IPA SHA-256 mismatch")
        with zipfile.ZipFile(io.BytesIO(ipa)) as archive:
            require(archive.testzip() is None, "IPA ZIP CRC failure")
            require(not any(name.endswith(".mobileprovision") for name in archive.namelist()),
                    "Public IPA contains a provisioning profile")
            infos = [name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
            require(len(infos) == 1, "Expected one device app")
            info = plistlib.loads(archive.read(infos[0]))
            require(info["CFBundleIdentifier"] == BUNDLE and info["CFBundleSupportedPlatforms"] == ["iPhoneOS"],
                    "IPA is not the expected device application")
            for field, plist_key in (("version", "CFBundleShortVersionString"),
                                     ("buildVersion", "CFBundleVersion"), ("minOSVersion", "MinimumOSVersion")):
                require(version[field] == info[plist_key], f"IPA Info.plist mismatch: {field}")
            privacy = {key: value for key, value in info.items() if key.startswith("NS") and key.endswith("UsageDescription")}
            require(privacy == app["appPermissions"]["privacy"], "IPA privacy declaration mismatch")
        print(f"Verified public IPA {number} ({build}): {len(ipa)} bytes, SHA-256, CRC, identity, no profile")
    print(f"Validated source: {len(app['versions'])} version(s); installer runtime testing remains separate")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--online", action="store_true", help="Download public images, build metadata, and IPAs for verification")
    parser.add_argument("--live", action="store_true", help="Also require the deployed source to match docs/source.json (implies --online)")
    args = parser.parse_args()
    source = json.loads((ROOT / "docs/source.json").read_text())
    if args.live:
        require(json.loads(fetch(SOURCE_URL)) == source, "Deployed source differs from docs/source.json")
    validate(source, online=args.online or args.live)


if __name__ == "__main__":
    main()
