#!/usr/bin/env python3
"""Compile the producer and run Foundation fixtures without starting XCTest."""
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    library = root / "WebDriverAgentLib"
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True
    ).strip()
    developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    platform = Path(developer) / "Platforms/iPhoneSimulator.platform/Developer"
    with tempfile.TemporaryDirectory(prefix="handkite-scoped-check-") as scratch:
        scratch = Path(scratch)
        headers = {}
        for header in sorted(list(library.rglob("*.h")) + list((root / "PrivateHeaders").rglob("*.h"))):
            if header.name in headers:
                continue
            headers[header.name] = str(header)
        overlay = scratch / "headers.json"
        overlay.write_text(json.dumps({"version": 0, "roots": [{
            "type": "directory", "name": str(scratch / "include/WebDriverAgentLib"),
            "contents": [{"type": "file", "name": name, "external-contents": path}
                         for name, path in sorted(headers.items())],
        }]}))
        command = ["xcrun", "clang", "-fsyntax-only", "-fobjc-arc", "-fblocks", "-fmodules",
                   "-fmodules-cache-path=" + str(scratch / "modules"),
                   "-isysroot", sdk, "-target", "arm64-apple-ios15.0-simulator",
                   "-Wno-nullability-completeness", "-ivfsoverlay", str(overlay),
                   "-I", str(scratch / "include")]
        for framework in ["Frameworks", "PrivateFrameworks"]:
            command += ["-F", str(platform / "Library" / framework)]
        for parent in sorted({p.parent for p in root.rglob("*.h")}):
            command += ["-I", str(parent)]
        for name in ["FBFindElementCommands.m", "FBSessionCommands.m"]:
            result = subprocess.run(command + [str(library / "Commands" / name)], capture_output=True, text=True)
            if result.returncode:
                print(result.stderr)
                raise SystemExit(result.returncode)
        executable = scratch / "membership-test"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        "-framework", "Foundation", str(root / "Scripts/test-scoped-membership.m"),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
