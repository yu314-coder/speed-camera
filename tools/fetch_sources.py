#!/usr/bin/env python3
"""Fetch public government traffic files with the macOS trust store via curl."""
import concurrent.futures
import csv
import json
import pathlib
import subprocess
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent
CACHE = ROOT / "cache"
IDS = ["178161", "144579", "176559", "172725", "172950", "178412", "144355",
       "171261", "173211", "146681", "156415", "109336", "178119", "178120"]


def download(url, path):
    encoded = urllib.parse.quote(url, safe=":/?&=%#,+")
    temporary = path.with_suffix(".partial")
    result = subprocess.run(["/usr/bin/curl", "--fail", "--location", "--max-time", "40",
                             "--silent", "--show-error", encoded, "--output", str(temporary)],
                            capture_output=True, text=True)
    if result.returncode:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(result.stderr.strip())
    temporary.replace(path)


def fetch(dataset_id):
    try:
        meta = CACHE / f"{dataset_id}_metadata.json"
        download(f"https://data.gov.tw/api/v2/rest/dataset/{dataset_id}", meta)
        data = json.loads(meta.read_text())["result"]
        resources = data["distribution"]
        results = []
        for index, resource in enumerate(resources):
            url = resource.get("resourceDownloadUrl", "")
            if resource.get("resourceFormat", "").upper() not in ("CSV", "JSON", "XLSX"):
                continue
            target = CACHE / f"{dataset_id}_{index}.bin"
            try:
                download(url, target)
                results.append({"index": index, "bytes": target.stat().st_size})
            except Exception as error:
                results.append({"index": index, "error": str(error)})
        return {"id": dataset_id, "title": data["title"], "resources": results}
    except Exception as error:
        return {"id": dataset_id, "error": str(error)}


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(fetch, IDS))
    (ROOT / "out" / "additional_fetch_report.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2))
    for result in results:
        print(json.dumps(result, ensure_ascii=False), flush=True)
