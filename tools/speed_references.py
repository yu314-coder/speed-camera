"""Published speed rules, kept separate from geocoded roads and camera alerts."""
import argparse
import contextlib
import csv
import datetime as dt
import hashlib
import io
import json
import pathlib
import re
import sqlite3
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA = """
CREATE TABLE IF NOT EXISTS speed_limit_references (
 id TEXT PRIMARY KEY,road_name TEXT NOT NULL,road_ref TEXT NOT NULL,
 segment_description TEXT NOT NULL,speed_limit_text TEXT NOT NULL,speed_limit_kph INTEGER,
 conditions TEXT NOT NULL,source_dataset_id TEXT NOT NULL,source_authority TEXT NOT NULL,
 source_updated_at TEXT NOT NULL,source_url TEXT NOT NULL,fetched_at_utc TEXT NOT NULL,
 publication_status TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS speed_reference_source ON speed_limit_references(source_dataset_id);
"""


def decode_csv(data):
    for encoding in ("utf-8-sig", "cp950", "big5"):
        try:
            return list(csv.DictReader(io.StringIO(data.decode(encoding))))
        except UnicodeError:
            pass
    raise ValueError("Unsupported reference CSV encoding")


def road_ref(name):
    match = re.search(r"(台|國道)\s*(\d+)(甲|乙|丙|丁)?", name.replace("臺", "台"))
    return "".join(p or "" for p in match.groups()) if match else ""


def reference_record(road, segment, limit, notes, source, updated, fetched, url, status):
    # Multiple limits stay verbatim, never reduced to the first number.
    match = re.fullmatch(r"\s*(\d{2,3})(?:\s*\(公里/小時\))?\s*", limit)
    numeric = int(match[1]) if match and 10 <= int(match[1]) <= 130 else None
    authority = "臺北市交通管制工程處" if source == "121671" else (
        "交通部高速公路局" if source == "40476" else "交通部公路局")
    identity = hashlib.sha256(json.dumps([source, road, segment, limit, notes], ensure_ascii=False).encode()).hexdigest()[:24]
    return dict(id=source+":"+identity, road_name=road, road_ref=road_ref(road),
                segment_description=segment, speed_limit_text=limit, speed_limit_kph=numeric,
                conditions=notes, source_dataset_id=source, source_authority=authority,
                source_updated_at=updated, source_url=url, fetched_at_utc=fetched, publication_status=status)


def csv_references(rows, source, updated, fetched):
    result = []
    footnotes = [row.get("路線", "").strip() for row in rows
                 if source == "40476" and row.get("路線", "").startswith("註")]
    for row in rows:
        segment = row.get("路段", "").strip()
        limit = row.get("速限", "").strip()
        notes = row.get("備註", "").strip()
        if not limit and source == "121671":
            reason = row.get("原因", "")
            values = set(re.findall(r"速限(?:為)?\s*(\d{2,3})\s*公里", reason))
            if len(values) == 1:
                limit = next(iter(values))+"(公里/小時)"
            notes = " · ".join(v for v in [reason, row.get("路寬", ""), notes] if v)
        road = row.get("公路名稱", row.get("路線", "臺北市"))
        if source == "121671" and row.get("類別"):
            road += " · "+row["類別"]
        if footnotes:
            notes = "\n".join([notes] + footnotes).strip()
        if segment and limit:
            result.append(reference_record(road, segment, limit, notes, source, updated, fetched,
                                          "https://data.gov.tw/dataset/"+source, "official_csv_reference"))
    return result


def load_catalogue(cache):
    records = []
    for source in ("121671", "40476"):
        meta_path = cache/f"{source}_metadata.json"
        if not meta_path.exists():
            continue
        meta = json.loads(meta_path.read_text()); meta = meta.get("result", meta)
        for index, resource in enumerate(meta.get("distribution", [])):
            path = cache/f"{source}_{index}.bin"
            if resource.get("resourceFormat", "").upper() != "CSV" or not path.exists():
                continue
            fetched = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).isoformat(timespec="seconds")
            records += csv_references(decode_csv(path.read_bytes()), source, meta.get("modifiedDate", ""), fetched)
    reviewed = cache/"thb_speed_references.json"
    if reviewed.exists():
        document = json.loads(reviewed.read_text())
        if document.get("status") != "reviewed_web_snapshot_not_machine_feed" or len(document.get("rows", [])) > 100:
            raise ValueError("Unreviewed expressway reference snapshot")
        for row in document["rows"]:
            url = urllib.parse.urlsplit(row["url"])
            if url.scheme != "https" or url.hostname != "www.thb.gov.tw" or url.path != "/News_ExpresswaySpeedLimit.aspx":
                raise ValueError("Unexpected expressway reference authority")
            if not road_ref(row["road"]) or not row["segment"] or not row["speed"]:
                raise ValueError("Incomplete expressway reference")
            records.append(reference_record(row["road"], row["segment"], row["speed"], row["notes"],
                           "thb_expressway_limits", "", document["checked_at_utc"], row["url"], document["status"]))
    return sorted({r["id"]: r for r in records}.values(), key=lambda r: (r["source_dataset_id"], r["road_name"], r["id"]))


def write_catalogue(connection, records):
    connection.executescript(SCHEMA)
    connection.execute("DELETE FROM speed_limit_references")
    for record in records:
        keys = list(record)
        connection.execute(f"INSERT INTO speed_limit_references ({','.join(keys)}) VALUES ({','.join('?' for _ in keys)})", list(record.values()))
    if records:
        checked = max(r["fetched_at_utc"] for r in records)
        connection.execute("INSERT OR REPLACE INTO build_metadata VALUES (?,?)", ("speed_references_checked_at", checked))


def reference_manifest(records):
    names = {"121671": "臺北市市區道路速限表", "40476": "行車速限資訊",
             "thb_expressway_limits": "公路局快速公路速限參考表 (partial reviewed snapshot)"}
    result = []
    for source_id in sorted({r["source_dataset_id"] for r in records}):
        selected = [r for r in records if r["source_dataset_id"] == source_id]
        first = selected[0]
        result.append(dict(dataset_id=source_id, dataset_name=names[source_id], authority=first["source_authority"],
                           metadata_updated_at=first["source_updated_at"], fetch_time_utc=max(r["fetched_at_utc"] for r in selected),
                           record_count=len(selected), status=first["publication_status"], url=first["source_url"]))
    return result


def augment(database, cache):
    records = load_catalogue(cache)
    if not records:
        raise ValueError("No validated speed references; preserve the previous snapshot")
    temporary = database.with_suffix(".speed-new.db")
    try:
        with contextlib.closing(sqlite3.connect(database)) as source, contextlib.closing(sqlite3.connect(temporary)) as target:
            source.backup(target)
            write_catalogue(target, records)
            revision = hashlib.sha256(json.dumps(records, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
            target.execute("INSERT OR REPLACE INTO build_metadata VALUES (?,?)", ("snapshot_revision", "speed-references:"+revision))
            for manifest in reference_manifest(records):
                target.execute("INSERT OR REPLACE INTO source_manifest VALUES (?,?,?,?,?,?,?,?)", (
                    manifest["dataset_id"], manifest["dataset_name"], manifest["authority"], manifest["metadata_updated_at"],
                    manifest["fetch_time_utc"], manifest["record_count"], manifest["status"], manifest["url"]))
            target.commit()
            if target.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise ValueError("Reference snapshot failed SQLite integrity check")
        temporary.replace(database)
    finally:
        temporary.unlink(missing_ok=True)
    return dict(reference_count=len(records), by_source={s:sum(r["source_dataset_id"] == s for r in records)
                for s in sorted({r["source_dataset_id"] for r in records})}, geocoded_references=0,
                camera_geometry_changed=False, used_for_alerts=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=pathlib.Path, default=ROOT/"Speedlimit/Resources/tw_traffic.db")
    parser.add_argument("--cache", type=pathlib.Path, default=ROOT/"tools/cache")
    args = parser.parse_args()
    print(json.dumps(augment(args.database, args.cache), indent=2))
