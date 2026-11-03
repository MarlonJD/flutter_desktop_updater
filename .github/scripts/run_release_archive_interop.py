#!/usr/bin/env python3
"""Run the same probe against published packages and the checked-out candidate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import unquote, urljoin, urlsplit

REPO = Path(__file__).resolve().parents[2]
PROBE = REPO / ".github/scripts/release_archive_interop.dart"
VERSIONS = ("3.2.9", "3.2.10", "candidate")


def run(command, cwd=REPO, *, capture=False):
    executable = shutil.which(str(command[0])) or str(command[0])
    command = [executable, *map(str, command[1:])]
    if os.name == "nt" and executable.lower().endswith((".bat", ".cmd")):
        command = ["cmd.exe", "/d", "/c", *command]
    return subprocess.run(command, cwd=cwd, check=True, capture_output=capture, text=True, encoding="utf-8")


def file_uri_path(uri):
    value = unquote(urlsplit(uri).path)
    if os.name == "nt" and value.startswith("/") and len(value) > 2 and value[2] == ":":
        value = value[1:]
    return Path(value)


def package_provenance(config):
    packages = json.loads(config.read_text(encoding="utf-8"))["packages"]
    result = {}
    for name in ("desktop_updater", "cryptography_plus", "crypto", "archive"):
        package = next(p for p in packages if p["name"] == name)
        root = file_uri_path(urljoin(config.as_uri(), package["rootUri"]))
        pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
        version = next(line.split(":", 1)[1].strip() for line in pubspec.splitlines() if line.startswith("version:"))
        hashes = {}
        if name == "desktop_updater":
            for relative in ("lib/src/core/release_index.dart", "lib/src/core/release_index_signature_verifier.dart", "lib/src/release_cli/sign_command.dart", "lib/src/release_cli/release_publisher.dart"):
                hashes[relative] = hashlib.sha256((root / relative).read_bytes()).hexdigest()
        result[name] = {"version": version, "sourceSha256": hashes}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("produce", "consume"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--inputs", type=Path)
    parser.add_argument("--expected-fixtures", type=int, default=12)
    parser.add_argument("--versions", nargs="+", choices=VERSIONS, default=VERSIONS)
    args = parser.parse_args()
    if args.mode == "consume" and args.inputs is None:
        parser.error("consume requires --inputs")
    args.output = args.output.resolve()
    if args.inputs:
        args.inputs = args.inputs.resolve()
    with tempfile.TemporaryDirectory(prefix="archive-interop-packages-") as temporary:
        for version in args.versions:
            if version == "candidate":
                config = REPO / ".dart_tool/package_config.json"
            else:
                package = Path(temporary) / version
                package.mkdir()
                (package / "pubspec.yaml").write_text(
                    "name: archive_interop_consumer\nenvironment:\n  sdk: '>=3.6.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\n  desktop_updater: " + version + "\n", encoding="utf-8"
                )
                run(["flutter", "pub", "get"], cwd=package)
                config = package / ".dart_tool/package_config.json"
            provenance = package_provenance(config)
            if version != "candidate" and provenance["desktop_updater"]["version"] != version:
                raise RuntimeError("Resolved package version does not match the requested producer/reader")
            target = args.output / args.host / version
            command = ["dart", f"--packages={config}", PROBE, args.mode, target, f"{args.host}/{version}"]
            if args.mode == "consume":
                command += [args.inputs, str(args.expected_fixtures)]
            run(command)
            (target / "dependencies.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
            if args.mode == "produce":
                diagnostic = run(["dart", f"--packages={config}", REPO / ".github/scripts/diagnose_archive.dart", target / "build-3.json", target / "profile.json"], capture=True)
                report = json.loads(diagnostic.stdout)
                if not (report["archive"]["signatureValidWithThisProfile"] and report["archiveUnchanged"] and report["publicProfileUnchanged"]):
                    raise RuntimeError("The reporter diagnostic failed its signed positive control")
                (target / "diagnostics.json").write_text(diagnostic.stdout, encoding="utf-8")


if __name__ == "__main__":
    main()
