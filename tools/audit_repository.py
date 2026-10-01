#!/usr/bin/env python3
"""Audit the tracked tree without printing any matched credential values."""
import argparse
import fnmatch
import json
import pathlib
import re
import sqlite3
import struct
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN_FILES = (
    "*.p8", "*.p12", "*.pfx", "*.pem", "*.key", "*.cer", "*.mobileprovision",
    "*.ipa", "*.xcuserstate", "*.log", ".env", ".env.*", "AuthKey_*",
    "*.local.xcconfig", "ExportOptions*.plist",
)
FORBIDDEN_DIRECTORIES = {
    "xcuserdata", "private_keys", "DerivedData", ".build", ".swiftpm", ".local",
    "artifacts", "__pycache__",
}
CONTENT_RULES = {
    "absolute_personal_home_path": re.compile(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    "private_key": re.compile(rb"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"),
    "github_token": re.compile(rb"\bgh[opusr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}\b"),
    "openai_key": re.compile(rb"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}\b"),
    "personal_signing_team": re.compile(rb"\b(?:DEVELOPMENT_TEAM|DevelopmentTeam)\s*(?:=|:)\s*[A-Z0-9]{10}\b"),
    "private_chat_link": re.compile(rb"https://chatgpt\.com/c/[0-9a-f-]{30,}"),
}


def png_metadata(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return []
    offset, found = 8, []
    while offset + 12 <= len(data):
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if offset + size + 12 > len(data):
            found.append("invalid_png_chunk")
            break
        if kind in (b"tEXt", b"zTXt", b"iTXt", b"eXIf"):
            found.append("png_text_or_exif_metadata")
        offset += size + 12
        if kind == b"IEND":
            break
    return found


def inspect_database(path):
    checked = 0
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("SQLite integrity check failed")
        tables = [row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        for table in tables:
            # Inspect logical text as well as raw bytes; SQLite may encode text differently.
            quoted = '"' + table.replace('"', '""') + '"'
            for row in db.execute("SELECT * FROM " + quoted):
                for value in row:
                    if isinstance(value, str):
                        checked += 1
                        encoded = value.encode()
                        for rule, pattern in CONTENT_RULES.items():
                            if pattern.search(encoded):
                                raise ValueError(rule)
    return checked


def audit():
    records = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=ROOT).split(b"\0")
    findings, files, database_text_fields = [], 0, 0
    for record in records:
        if not record:
            continue
        mode, _, stage_and_name = record.split(b" ", 2)
        stage, encoded_name = stage_and_name.split(b"\t", 1)
        name = encoded_name.decode()
        relative = pathlib.PurePosixPath(name)
        files += 1
        if mode != b"100644" and mode != b"100755":
            findings.append({"path": name, "rule": "symlink_submodule_or_unmerged_file"})
            continue
        if stage != b"0":
            findings.append({"path": name, "rule": "unmerged_index"})
        if any(part in FORBIDDEN_DIRECTORIES for part in relative.parts) or name.startswith(("tools/cache/", "tools/out/")):
            findings.append({"path": name, "rule": "local_state_directory"})
        if any(fnmatch.fnmatch(relative.name, pattern) for pattern in FORBIDDEN_FILES) and relative.name != ".env.example":
            findings.append({"path": name, "rule": "credential_or_local_artifact_filename"})
        # Inspect the exact indexed blob, not a potentially different working copy.
        data = subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)
        for rule, pattern in CONTENT_RULES.items():
            if pattern.search(data):
                findings.append({"path": name, "rule": rule})
        for rule in png_metadata(data):
            findings.append({"path": name, "rule": rule})
        if relative.suffix == ".db":
            if (ROOT / name).read_bytes() != data:
                findings.append({"path": name, "rule": "database_differs_from_index"})
                continue
            try:
                database_text_fields += inspect_database(ROOT / name)
            except (ValueError, sqlite3.Error) as error:
                findings.append({"path": name, "rule": str(error)})
    if not files:
        findings.append({"path": ".", "rule": "no_tracked_files"})
    return {"status": "failed" if findings else "passed", "tracked_files": files,
            "sqlite_text_fields_checked": database_text_fields, "findings": findings,
            "limitations": "Point-in-time staged-tree audit; use a full-history secret scanner too. Email attribution is permitted."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=pathlib.Path)
    args = parser.parse_args()
    report = audit()
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["status"] == "passed" else 1)


if __name__ == "__main__":
    main()
