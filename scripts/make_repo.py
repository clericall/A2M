#!/usr/bin/env python3
"""Build a flat Sileo/Cydia repository from one or more .deb files.

Only the Python standard library is used. Control archives may be gzip, xz,
bz2, or zstd compressed; zstd requires the optional 'zstandard' module. Theos
gzip-compresses the control archive by default. The MusicDrop Makefile also
sets THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip for the package payload.

Usage:
    python3 scripts/make_repo.py --debs packages --out docs --clean
"""

from __future__ import annotations

import argparse
import bz2
import gzip
import hashlib
import io
import json
import lzma
import re
import shutil
import sys
import tarfile
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from typing import NoReturn

AR_MAGIC = b"!<arch>\n"


def fail(message: str) -> NoReturn:
    print(f"make_repo: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_ar_members(path: Path) -> dict[str, bytes]:
    data = path.read_bytes()
    if not data.startswith(AR_MAGIC):
        fail(f"{path} is not a Debian archive (bad ar magic)")

    members: dict[str, bytes] = {}
    offset = len(AR_MAGIC)
    while offset + 60 <= len(data):
        header = data[offset : offset + 60]
        if header[58:60] != b"`\n":
            fail(f"{path} has a corrupt ar header")
        name = header[0:16].decode("ascii", "replace").strip()
        if name.endswith("/"):
            name = name[:-1]
        try:
            size = int(header[48:58].decode("ascii").strip() or "0")
        except ValueError:
            fail(f"{path} has an invalid ar member size")
        body_start = offset + 60
        body_end = body_start + size
        if body_end > len(data):
            fail(f"{path} is truncated")
        if name not in {"//", "/"}:
            members[name] = data[body_start:body_end]
        offset = body_end + (size % 2)
    return members


def decompress_control(name: str, payload: bytes) -> bytes:
    if name.endswith(".gz") or payload[:2] == b"\x1f\x8b":
        return gzip.decompress(payload)
    if name.endswith(".xz") or payload[:6] == b"\xfd7zXZ\x00":
        return lzma.decompress(payload)
    if name.endswith(".bz2") or payload[:3] == b"BZh":
        return bz2.decompress(payload)
    if name.endswith(".zst") or payload[:4] == b"\x28\xb5\x2f\xfd":
        try:
            import zstandard  # type: ignore
        except ImportError:
            fail("control.tar.zst found but the 'zstandard' module is not installed")
        return zstandard.ZstdDecompressor().decompress(payload)
    if name.endswith(".tar") or payload[257:262] == b"ustar":
        return payload
    fail(f"unsupported control archive compression: {name}")


def read_control(deb: Path) -> str:
    members = read_ar_members(deb)
    if "debian-binary" not in members:
        fail(f"{deb} is missing debian-binary")

    control_name = next((name for name in members if name.startswith("control.tar")), None)
    if not control_name:
        fail(f"{deb} is missing control.tar")

    tar_bytes = decompress_control(control_name, members[control_name])
    try:
        with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as archive:
            for member in archive.getmembers():
                normalized = member.name.lstrip("./")
                if normalized == "control" and member.isfile():
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        break
                    return extracted.read().decode("utf-8", "replace")
    except tarfile.TarError as error:
        fail(f"{deb}: cannot read control archive: {error}")
    fail(f"{deb} has no control file")


def parse_control(text: str) -> list[tuple[str, str]]:
    fields: list[tuple[str, str]] = []
    current: str | None = None
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if not raw:
            continue
        if raw[0] in " \t":
            if current is None:
                fail("control file starts with a continuation line")
            key, value = fields[-1]
            fields[-1] = (key, value + "\n" + raw.rstrip())
            continue
        if ":" not in raw:
            fail(f"invalid control line: {raw!r}")
        key, value = raw.split(":", 1)
        current = key.strip()
        fields.append((current, value.lstrip(" ").rstrip()))
    return fields


def field_dict(fields: list[tuple[str, str]]) -> dict[str, str]:
    return {key.lower(): value for key, value in fields}


def format_paragraph(fields: list[tuple[str, str]]) -> str:
    return "".join(f"{key}: {value}\n" for key, value in fields) + "\n"


def safe_component(value: str) -> str:
    value = value.strip().replace(" ", "_")
    value = re.sub(r"[^A-Za-z0-9._+~-]+", "_", value)
    return value.strip("._") or "package"


def gzip_bytes(data: bytes) -> bytes:
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", compresslevel=9, mtime=0) as handle:
        handle.write(data)
    return buffer.getvalue()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_repository(args: argparse.Namespace) -> None:
    debs_dir = Path(args.debs).resolve()
    out_dir = Path(args.out).resolve()
    target_debs = out_dir / "debs"

    if not debs_dir.is_dir():
        fail(f"deb directory not found: {debs_dir}")
    sources = sorted(debs_dir.glob("*.deb"))
    if not sources:
        fail(f"no .deb files found in {debs_dir}")

    out_dir.mkdir(parents=True, exist_ok=True)
    target_debs.mkdir(parents=True, exist_ok=True)

    same_directory = debs_dir == target_debs
    if args.clean and not same_directory:
        for old in target_debs.glob("*.deb"):
            old.unlink()

    records: list[tuple[str, str, list[tuple[str, str]], dict[str, str]]] = []
    used_names: set[str] = set()
    repo_packages: list[dict[str, object]] = []

    for source in sources:
        control_text = read_control(source)
        original_fields = parse_control(control_text)
        values = field_dict(original_fields)
        for required in ("package", "version", "architecture"):
            if not values.get(required):
                fail(f"{source.name} control file is missing {required}")

        architecture = values["architecture"]
        if architecture != "iphoneos-arm64" and not args.allow_other_arch:
            fail(
                f"{source.name} targets {architecture}, not rootless iphoneos-arm64 "
                "(pass --allow-other-arch to override)"
            )

        display_name = values.get("name") or values["package"]
        version = values["version"]
        staged_name = f"{safe_component(display_name)}_{safe_component(version)}_{safe_component(architecture)}.deb"
        if staged_name in used_names:
            suffix = hashlib.sha256(source.read_bytes()).hexdigest()[:8]
            staged_name = staged_name[:-4] + f"_{suffix}.deb"
        used_names.add(staged_name)

        staged = target_debs / staged_name
        if source.resolve() != staged.resolve():
            shutil.copy2(source, staged)

        payload = staged.read_bytes()
        fields = [
            (key, value)
            for key, value in original_fields
            if key.lower() not in {"filename", "size", "md5sum", "sha1", "sha256"}
        ]
        fields.extend(
            [
                ("Filename", f"debs/{staged_name}"),
                ("Size", str(len(payload))),
                ("MD5sum", hashlib.md5(payload).hexdigest()),
                ("SHA1", hashlib.sha1(payload).hexdigest()),
                ("SHA256", hashlib.sha256(payload).hexdigest()),
            ]
        )

        paragraph = format_paragraph(fields)
        records.append((values["package"].lower(), version, fields, values))
        repo_packages.append(
            {
                "package": values["package"],
                "name": display_name,
                "version": version,
                "architecture": architecture,
                "description": values.get("description", "").split("\n")[0].strip(),
                "filename": f"debs/{staged_name}",
                "size": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
        )
        print(f"indexed {staged_name} ({values['package']} {version})")

    records.sort(key=lambda item: (item[0], item[1]))
    packages_text = "\n".join(format_paragraph(fields) for _, _, fields, _ in records)
    packages_bytes = packages_text.encode("utf-8")

    (out_dir / "Packages").write_bytes(packages_bytes)
    (out_dir / "Packages.gz").write_bytes(gzip_bytes(packages_bytes))
    (out_dir / "Packages.bz2").write_bytes(bz2.compress(packages_bytes, compresslevel=9))
    (out_dir / "Packages.xz").write_bytes(lzma.compress(packages_bytes, preset=9))

    architectures = sorted({str(item["architecture"]) for item in repo_packages})
    release_lines = [
        f"Origin: {args.origin}",
        f"Label: {args.label}",
        f"Suite: {args.suite}",
        f"Version: {args.release_version}",
        f"Codename: {args.codename}",
        f"Architectures: {' '.join(architectures)}",
        "Components: main",
        f"Description: {args.description}",
        "Icon: CydiaIcon.png",
        f"Date: {format_datetime(datetime.now(timezone.utc))}",
    ]
    if args.homepage:
        release_lines.append(f"Homepage: {args.homepage}")

    release_lines.append("")

    hash_targets = ["Packages", "Packages.gz", "Packages.bz2", "Packages.xz"]
    release_lines.append("MD5Sum:")
    for filename in hash_targets:
        data = (out_dir / filename).read_bytes()
        release_lines.append(f" {hashlib.md5(data).hexdigest()} {len(data)} {filename}")
    release_lines.append("SHA256:")
    for filename in hash_targets:
        data = (out_dir / filename).read_bytes()
        release_lines.append(f" {hashlib.sha256(data).hexdigest()} {len(data)} {filename}")
    (out_dir / "Release").write_text("\n".join(release_lines) + "\n", encoding="utf-8")

    primary = repo_packages[0]
    repo_info = {
        "name": args.label,
        "origin": args.origin,
        "description": args.description,
        "generated": datetime.now(timezone.utc).isoformat(),
        "packages": repo_packages,
        "package": primary["package"],
        "version": primary["version"],
        "architecture": primary["architecture"],
        "filename": primary["filename"],
        "size": primary["size"],
        "sha256": primary["sha256"],
    }
    (out_dir / "repo.json").write_text(json.dumps(repo_info, indent=2) + "\n", encoding="utf-8")

    print(f"wrote Packages, Release, and repo.json to {out_dir}")
    print(f"repo contains {len(repo_packages)} package(s)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a flat Sileo/Cydia repository")
    parser.add_argument("--debs", required=True, help="directory containing .deb files")
    parser.add_argument("--out", required=True, help="repository root to write (e.g. docs)")
    parser.add_argument("--clean", action="store_true", help="remove previously staged .deb files")
    parser.add_argument("--origin", default="MusicDrop")
    parser.add_argument("--label", default="MusicDrop")
    parser.add_argument("--suite", default="stable")
    parser.add_argument("--release-version", default="1.0")
    parser.add_argument("--codename", default="ios")
    parser.add_argument(
        "--description",
        default="MusicDrop - import your own audio files directly into the Music app.",
    )
    parser.add_argument("--homepage", default="")
    parser.add_argument("--allow-other-arch", action="store_true", help="index non-rootless packages")
    args = parser.parse_args()
    build_repository(args)


if __name__ == "__main__":
    main()
