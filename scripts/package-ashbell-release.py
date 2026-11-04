#!/usr/bin/env python3
"""Assemble a complete, offline-installable Ashbell desktop release.

Requires freshly built AArch64 devui and the selected upstream datad binary plus
its own version.json. Does not download, publish, or include device data.
SPDX-License-Identifier: MIT
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ("version.json", "u60pro-devui-aarch64", "zwrt-datad-aarch64",
          "ui.tar.gz", "start.sh", "ashbell-devui.sh", "LICENSE", "NOTICE.md")


def elf(path):
    content = path.read_bytes()
    if len(content) < 64 or content[:6] != b"\x7fELF\x02\x01" or content[18:20] != b"\xb7\x00":
        raise ValueError(f"Not an AArch64 ELF: {path}")
    return content


def add(tar, name, content, mode=0o644):
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = mode
    info.mtime = 0
    tar.addfile(info, io.BytesIO(content))


def build(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((args.manifest or ROOT / "version.json").read_text())
    datad = json.loads(args.datad_version.read_text())["datad"]
    if datad.get("asset") != "zwrt-datad-aarch64" or not datad.get("version"):
        raise ValueError("datad version manifest is missing its version or expected asset name")
    manifest["datad"] = datad
    manifest["distribution"] = "ashbell"
    manifest["manager"] = {"version": "1.1.2", "asset": "ashbell-devui.tar.gz"}
    payload = {
        "version.json": (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode(),
        "u60pro-devui-aarch64": elf(args.devui),
        "zwrt-datad-aarch64": elf(args.datad),
        "start.sh": (ROOT / "scripts/start.sh").read_bytes(),
        "ashbell-devui.sh": (ROOT / "scripts/ashbell-devui.sh").read_bytes(),
        "LICENSE": (ROOT / "LICENSE").read_bytes(),
        "NOTICE.md": (ROOT / "NOTICE.md").read_bytes(),
    }
    ui_buffer = io.BytesIO()
    names = []
    with tarfile.open(fileobj=ui_buffer, mode="w:gz", format=tarfile.USTAR_FORMAT) as tar:
        for path in sorted((ROOT / "ui").rglob("*")):
            rel = path.relative_to(ROOT / "ui")
            if any(part.startswith(".") for part in rel.parts):
                continue
            if path.is_symlink():
                raise ValueError(f"UI cannot include symlinks: {rel}")
            if not path.is_file():
                continue
            name = rel.as_posix()
            if not re.fullmatch(r"[A-Za-z0-9_./-]+", name):
                raise ValueError(f"Unsupported UI filename: {name}")
            content = path.read_bytes()
            add(tar, name, content, 0o755 if path.suffix == ".sh" else 0o644)
            names.append(name)
    required = {"style.css", "00-overview.html", "01-signal.html", "02-functions.html", "subpages/settings.html",
                "subpages/wifi.html", "subpages/shellcrash.html",
                "subpages/shellcrash-mode.sh", "subpages/wifi-control.sh", "subpages/wifi-info.sh"}
    if not required.issubset(names):
        raise ValueError("UI missing required files: " + ", ".join(sorted(required - set(names))))
    payload["ui.tar.gz"] = ui_buffer.getvalue()
    checksum = "".join(f"{hashlib.sha256(payload[name]).hexdigest()}  {name}\n" for name in ASSETS).encode()
    for name, content in payload.items():
        (output / name).write_bytes(content)
    (output / "SHA256SUMS").write_bytes(checksum)
    bundle = output / "ashbell-devui.tar.gz"
    with tarfile.open(bundle, "w:gz", format=tarfile.USTAR_FORMAT) as tar:
        for name in ASSETS:
            add(tar, name, payload[name], 0o755 if name.endswith(".sh") or name.endswith("aarch64") else 0o644)
        add(tar, "SHA256SUMS", checksum)
    (output / "ashbell-devui.tar.gz.sha256").write_text(
        f"{hashlib.sha256(bundle.read_bytes()).hexdigest()}  ashbell-devui.tar.gz\n")
    plugin = ROOT / "integrations/ufi-tools/Ashbell桌面管理.html"
    if plugin.is_file():
        (output / plugin.name).write_bytes(plugin.read_bytes())
        (output / "ashbell-desktop-manager.js").write_bytes(plugin.read_bytes())
        (output / "Ashbell桌面管理.txt").write_bytes(plugin.read_bytes())
    print(f"Created {bundle} ({bundle.stat().st_size:,} bytes; {len(names)} UI files)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, help="Optional renderer/UI manifest (defaults to repository version.json)")
    parser.add_argument("--devui", required=True, type=Path, help="Freshly built AArch64 renderer")
    parser.add_argument("--datad", required=True, type=Path, help="Selected AArch64 datad binary")
    parser.add_argument("--datad-version", required=True, type=Path, help="Matching datad version.json")
    parser.add_argument("--output", required=True, type=Path, help="Release output directory")
    build(parser.parse_args())
