#!/usr/bin/env python3
"""Materialize the pinned, Google-signed Windows Chrome Stable oracle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from typing import Any
import urllib.parse
import urllib.request


def sha256(path: Path) -> str:
    """Hash a file without loading it into memory."""

    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_profile(path: Path) -> dict[str, Any]:
    """Load and validate the immutable official Stable package record."""

    root = json.loads(path.read_text(encoding="utf-8"))
    stable = root.get("google_chrome_stable") or {}
    version = str(stable.get("version") or "")
    package_url = str(stable.get("package_url") or "")
    package_sha256 = str(stable.get("package_sha256") or "")
    package_size = stable.get("package_size")
    installer_name = str(stable.get("installer_name") or "")
    parsed_url = urllib.parse.urlparse(package_url)
    assert re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", version), stable
    assert stable.get("platform") == "win64", stable
    assert stable.get("omaha_app_id") == (
        "{8A69D345-D564-463C-AFF1-A69D9E530F96}"
    ), stable
    assert parsed_url.scheme == "https", package_url
    assert parsed_url.hostname == "dl.google.com", package_url
    assert parsed_url.path.endswith(".crx3"), package_url
    assert version in parsed_url.path, package_url
    assert re.fullmatch(r"[0-9a-f]{64}", package_sha256), stable
    assert isinstance(package_size, int) and package_size > 0, stable
    assert installer_name == (
        f"{version}_chrome_installer_uncompressed.exe"
    ), stable
    return stable


def download(url: str, destination: Path) -> None:
    """Download one immutable package using the Python standard library."""

    request = urllib.request.Request(url, headers={"User-Agent": "DarkPanda CI"})
    with urllib.request.urlopen(request, timeout=60) as response:
        with destination.open("wb") as output:
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                output.write(chunk)


def run(command: list[str]) -> None:
    """Run one materialization command and preserve its diagnostics."""

    subprocess.run(command, check=True)


def powershell_json(script: str, path: Path) -> dict[str, Any]:
    """Run a path-safe PowerShell metadata query."""

    environment = dict(os.environ, DARKPANDA_BINARY_PATH=str(path))
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", script],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    return json.loads(result.stdout)


def authenticode(path: Path) -> dict[str, str]:
    """Require a valid Google Authenticode signature."""

    evidence = powershell_json(
        "$s=Get-AuthenticodeSignature -LiteralPath $env:DARKPANDA_BINARY_PATH;"
        "@{Status=[string]$s.Status;Subject=$s.SignerCertificate.Subject}"
        "|ConvertTo-Json -Compress",
        path,
    )
    assert evidence.get("Status") == "Valid", evidence
    assert "Google LLC" in str(evidence.get("Subject")), evidence
    return {key: str(value) for key, value in evidence.items()}


def version_info(path: Path, product: str, version: str) -> dict[str, str]:
    """Require exact Windows product and version metadata."""

    evidence = powershell_json(
        "$v=(Get-Item -LiteralPath $env:DARKPANDA_BINARY_PATH).VersionInfo;"
        "@{ProductName=$v.ProductName;ProductVersion=$v.ProductVersion;"
        "FileDescription=$v.FileDescription}|ConvertTo-Json -Compress",
        path,
    )
    assert evidence.get("ProductName") == product, evidence
    assert evidence.get("ProductVersion") == version, evidence
    return {key: str(value) for key, value in evidence.items()}


def main() -> None:
    """Download, verify, and unpack the official portable oracle."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seven-zip", required=True, type=Path)
    args = parser.parse_args()

    if os.name != "nt":
        raise RuntimeError("the Google Chrome Stable oracle requires Windows")
    stable = load_profile(args.profile)
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise RuntimeError(f"output directory is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="darkpanda-chrome-stable-") as temporary:
        temporary_path = Path(temporary)
        package = temporary_path / "google-chrome-stable.crx3"
        download(stable["package_url"], package)
        assert package.stat().st_size == stable["package_size"], package
        assert sha256(package) == stable["package_sha256"], package

        installer_dir = temporary_path / "installer"
        installer_dir.mkdir()
        run(
            [
                str(args.seven_zip),
                "x",
                "-y",
                f"-o{installer_dir}",
                str(package),
                stable["installer_name"],
                "manifest.json",
            ]
        )
        manifest = json.loads(
            (installer_dir / "manifest.json").read_text(encoding="utf-8")
        )
        assert manifest == {
            "manifest_version": 2,
            "name": stable["installer_name"],
            "version": stable["version"],
        }, manifest
        installer = installer_dir / stable["installer_name"]
        installer_signature = authenticode(installer)
        installer_version = version_info(
            installer, "Google Chrome Installer", stable["version"]
        )

        run(
            [
                str(args.seven_zip),
                "x",
                "-y",
                f"-o{output}",
                str(installer),
                "Chrome-bin/*",
            ]
        )

        chrome = output / "Chrome-bin" / "chrome.exe"
        if not chrome.is_file():
            raise RuntimeError(f"portable Chrome executable is missing: {chrome}")
        chrome_signature = authenticode(chrome)
        chrome_version = version_info(chrome, "Google Chrome", stable["version"])
        evidence = {
            "schema": "darkpanda-google-chrome-stable-materialization/v1",
            "version": stable["version"],
            "platform": stable["platform"],
            "package": {
                "url": stable["package_url"],
                "size": package.stat().st_size,
                "sha256": sha256(package),
            },
            "installer": {
                "name": installer.name,
                "sha256": sha256(installer),
                "signature": installer_signature,
                "versionInfo": installer_version,
            },
            "chrome": {
                "path": str(chrome.relative_to(output)),
                "sha256": sha256(chrome),
                "signature": chrome_signature,
                "versionInfo": chrome_version,
            },
        }
        (output / "materialization.json").write_text(
            json.dumps(evidence, indent=2), encoding="utf-8"
        )
        print(json.dumps(evidence, separators=(",", ":")))
        print("Google Chrome Stable materialization: PASS")


if __name__ == "__main__":
    main()
