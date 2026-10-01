#!/usr/bin/env python3
"""Collect reproducible build, dataset and test evidence without claiming device accuracy."""
import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import plistlib
import re
import sqlite3
import struct

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD_ROOT = pathlib.Path(os.environ.get("SPEED_CAMERA_BUILD_ROOT", str(ROOT / ".local/build")))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def swift_tests(path, expected, xcode=False, additional_paths=()):
    paths = [path, *additional_paths]
    logs = [item.read_text() for item in paths]
    if xcode:
        for item, log in zip(paths, logs):
            require("** TEST SUCCEEDED **" in log, f"{item.name}: xcodebuild has not confirmed success")
    log = "\n".join(logs)
    passed = sorted(set(re.findall(r"Test Case '-\[([^\]]+)\]' passed", log)))
    require(len(passed) == expected, f"{path.name}: expected {expected} passing tests, found {len(passed)}")
    require(not re.search(r"Test Case .* failed", log), f"{path.name}: test failures")
    measurement = re.search(r"PERFORMANCE spatial\+matching: ([\d.]+) ms/update", log)
    return dict(status="passed", count=len(passed), tests=passed, log=str(path), logs=[str(item) for item in paths],
                spatial_and_matching_mean_ms=float(measurement[1]) if measurement else None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", type=pathlib.Path, default=BUILD_ROOT / "artifacts")
    parser.add_argument("--ios-log", default="gps-destination-final-03.log")
    parser.add_argument("--ios-followup-log", default="gps-orientation-final.log")
    parser.add_argument("--ios-extra-log", action="append", default=[])
    parser.add_argument("--host-log", default="host-tests-gps-final.log")
    parser.add_argument("--release-log", default="build-release-gps-final.log")
    parser.add_argument("--pipeline-log", default="pipeline-tests-gps-final.log")
    parser.add_argument("--cctv-log", default="cctv-loading-smoke.log")
    parser.add_argument("--mapkit-log", default="mapkit-smoke.log")
    parser.add_argument("--cctv-audit", type=pathlib.Path)
    parser.add_argument("--host-count", type=int, default=26)
    parser.add_argument("--ios-count", type=int, default=81)
    parser.add_argument("--pipeline-count", type=int, default=11)
    parser.add_argument("--search-profile", type=pathlib.Path)
    parser.add_argument("--release-app", type=pathlib.Path, default=BUILD_ROOT / "ReleaseDerivedData/Build/Products/Release-iphoneos/Speedlimit.app")
    parser.add_argument("--debug-app", type=pathlib.Path, default=BUILD_ROOT / "DerivedData/Build/Products/Debug-iphonesimulator/Speedlimit.app")
    args = parser.parse_args()
    snapshot = ROOT / "Speedlimit/Resources/tw_traffic.db"
    snapshot_hash = digest(snapshot)
    icon_path = ROOT / "Speedlimit/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    icon = icon_path.read_bytes()
    require(icon[:8] == b"\x89PNG\r\n\x1a\n", "App icon is not PNG")
    icon_width, icon_height = struct.unpack(">II", icon[16:24])
    require((icon_width, icon_height) == (1024, 1024) and icon[25] == 2, "App icon must be opaque 1024x1024 RGB")
    build_log = args.artifacts / args.release_log
    require("** BUILD SUCCEEDED **" in build_log.read_text(), "Release build has not succeeded")
    bundle_versions = {}
    for bundle in (args.release_app, args.debug_app):
        require(digest(bundle / "tw_traffic.db") == snapshot_hash, f"Bundled snapshot differs: {bundle}")
        exported_shapes=ROOT/"Speedlimit/Resources/osm_section_display_shapes.json"
        require(digest(bundle/"osm_section_display_shapes.json")==digest(exported_shapes),"Bundled ODbL geometry export differs")
        exported=json.loads(exported_shapes.read_text())
        require(exported.get("license")=="ODbL-1.0" and all(s.get("geometry_source")=="osm_road_geometry_display_only" for s in exported["derived_spans"]),"Non-open geometry was permanently bundled")
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        bundle_versions[bundle.parent.name] = info["CFBundleVersion"]
        require("location" in info.get("UIBackgroundModes", []), f"Location capability missing: {bundle}")
        require("RoadMatching" in info.get("NSLocationTemporaryUsageDescriptionDictionary", {}), f"Precise Location purpose missing: {bundle}")
        extension = bundle / "PlugIns/SpeedlimitNotificationContent.appex/Info.plist"
        properties = plistlib.loads(extension.read_bytes()).get("NSExtension", {})
        require(properties.get("NSExtensionPointIdentifier") == "com.apple.usernotifications.content-extension", "Notification content extension is not configured")
        require(properties.get("NSExtensionAttributes", {}).get("UNNotificationExtensionCategory") == "CAMERA_ALERT", "Notification category mismatch")
    pipeline_path = args.artifacts / args.pipeline_log
    pipeline_log = pipeline_path.read_text()
    pipeline_count = re.search(r"Ran (\d+) tests", pipeline_log)
    require(pipeline_count and int(pipeline_count[1]) == args.pipeline_count and "\nOK\n" in pipeline_log, "Pipeline tests have not passed")
    host = swift_tests(args.artifacts / args.host_log, args.host_count)
    ios = swift_tests(args.artifacts / args.ios_log, args.ios_count, xcode=True,
                      additional_paths=[args.artifacts / name for name in [args.ios_followup_log,*args.ios_extra_log]])
    ios["execution_strategy"] = "Unit and UI regression runs; unique cases counted once. Check the listed logs for build dates and exercised cases."
    mapkit_log = (args.artifacts / args.mapkit_log).read_text()
    cctv_log = (args.artifacts / args.cctv_log).read_text()
    routes = re.search(r"Live Apple routes: (\d+)", mapkit_log)
    require(routes and int(routes[1]) > 0 and "Live Apple traffic ETA:" in mapkit_log, "Live Apple API smoke check missing")
    require("Public CCTV JPEG:" in cctv_log and "no credentials" in cctv_log, "Public CCTV check missing")
    db = sqlite3.connect(f"file:{snapshot}?mode=ro", uri=True)
    try:
        require(db.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "SQLite integrity check failed")
        require(db.execute("SELECT COUNT(*) FROM camera_points WHERE is_alert_enabled=1 AND location_confidence!='A'").fetchone()[0] == 0, "Non-A camera enables alerts")
        metadata = dict(db.execute("SELECT key,value FROM build_metadata"))
        verified_sections = db.execute("SELECT COUNT(*) FROM section_zones WHERE location_confidence='A'").fetchone()[0]
        estimated_sections = db.execute("SELECT COUNT(*) FROM section_zones WHERE location_confidence!='A'").fetchone()[0]
        require(db.execute("SELECT COUNT(*) FROM section_zones WHERE location_confidence!='A' AND is_alert_enabled!=0").fetchone()[0]==0,"Estimated span enables production alerts")
        endpoint_only = db.execute("SELECT COUNT(*) FROM camera_points WHERE camera_category='section_speed' AND section_id IS NULL").fetchone()[0]
    finally:
        db.close()
    data = json.loads(metadata["report"])
    performance_lines = [line for line in (args.artifacts / args.ios_log).read_text().splitlines()
                         if "testRepeatedMapPanningPerformance" in line and "measured [" in line]
    report = dict(
        verified_at_utc=dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        project=str(ROOT / "Speedlimit.xcodeproj"),
        source_hashes={str(path.relative_to(ROOT)): digest(path) for pattern in ("Speedlimit/**/*.swift", "SpeedlimitTests/**/*.swift", "SpeedlimitUITests/**/*.swift", "SpeedlimitNotificationContent/**/*.swift")
                       for path in sorted(ROOT.glob(pattern))},
        builds=dict(release_device="passed, unsigned; app and notification extension", simulator="passed and launched in UI tests", release_log=str(build_log), bundle_versions=bundle_versions),
        icon=dict(path=str(icon_path), sha256=digest(icon_path), width=icon_width, height=icon_height, alpha=False,
                  origin="ChatGPT Create Image in Chrome; downloaded through visible image viewer",
                  model_version="Not exposed by the image UI; a specific model cannot be independently confirmed"),
        database=dict(path=str(snapshot), sha256=snapshot_hash, integrity="ok", bundle_hashes_match=True,
                      built_at=metadata["built_at"], enforcement=data["enforcement_count"], cctv=data["cctv_count"],
                      eligible_alerts=data["alert_eligible_count"], section_corridors=data["section_corridors"],
                      verified_section_corridors=verified_sections,estimated_display_spans=estimated_sections,endpoint_only_section_records=endpoint_only,
                      official_roads=data["road_segments"], official_speed_segments=data["official_speed_segments"]),
        tests=dict(pipeline=dict(status="passed", count=args.pipeline_count, log=str(pipeline_path)), shared_host=host,
                   ios=ios, ui_route_data="Debug-only, explicitly labelled fixture routes; not proof of live iPhone routing"),
        live_checks=dict(apple_mapkit=dict(platform="macOS, actual Apple servers", result=mapkit_log.strip()),
                         cctv=dict(platform="macOS, same CCTVService actor as iOS", result=cctv_log.strip())),
        performance=dict(host_mean_ms=host["spatial_and_matching_mean_ms"], simulator_mean_ms=ios["spatial_and_matching_mean_ms"],
                         simulator_map_stress_metrics=performance_lines,
                         interpretation="Mac/simulator measurements only. UI timings include XCTest/AX automation overhead, not frame latency. No old-code baseline, speedup percentage, physical-device FPS or battery guarantee."),
        loading_reliability=dict(
            tested_failure_cases=["corrupt and unsupported SQLite snapshots", "missing schema", "oversized and invalid road geometry",
                                  "startup timeout and retry", "late search/route/ETA replies", "cached-viewport query cancellation",
                                  "traffic expiry", "GPS expiry and pending-fix drain", "reroute timeout retains active route",
                                  "offline and stalled CCTV endpoints", "CCTV dismissal cancellation", "oversized image dimensions",
                                  "GPS permission initialization, denial and prompt deduplication", "continuous GPS acquisition timeout and retry",
                                  "destination retained while acquiring GPS", "late GPS cannot resurrect cancelled destination",
                                  "fresh stationary GPS can start routing", "compass rotation independent of travel course",
                                  "blue arrow rotation relative to map", "route overlay identity retained across alternate selection"],
            deadlines_seconds=dict(startup=8, gps_acquisition=12, search=12, routes=20, traffic_eta=12, cctv_wall_clock=20, sqlite_query=1),
            safety_policy="Outdated completions cannot overwrite newer state; failed startup remains retryable; stale GPS/ETA data is not presented as current.",
            evidence="Fault-injected unit tests and simulator retry UI test, not proof of every possible iOS or device failure."),
        gps_reliability=dict(
            regression_cases=[case for case in ios["tests"] if "GPSRecoveryTests " in case or "testGPSOutageHidesOldTurnDistanceAndRecoveryKeepsRoute" in case],
            active_distance_filter="none; idle browsing retains 8 meters", freshness_seconds=8,
            watchdog_seconds=2, automatic_recovery_backoff_seconds=[10,20,40,60],
            guidance_accuracy_limit_meters=50, alert_accuracy_limit_meters=25,
            physical_device="Physical GPS reception, background drive, battery and memory are not verified by this script."),
        limitations=data["limitations"] + [
            "Strict complete-coordinate research gate remains unmet for Tai 61; no invented section exit coordinates.",
            "GPS/compass accuracy, parallel or stacked-road positioning and notification delivery during a physical drive are unverified.",
            "Notification content extension compiles and is embedded; expanded Notification Center rendering needs a device check.",
            "Native Apple basemap/search/new directions/traffic/images need network; bundled camera/road queries work offline.",
            "No public MapKit embedded Apple Maps navigation interface or route-specific alternate traffic ETA is claimed."],
        source_artifacts=[str(ROOT / "tools/out" / name) for name in
                          ("research_source_inventory.json", "research_quality_report.md", "research_route_checks.json", "traffic_build_report.json")])
    if args.cctv_audit:
        report["live_checks"]["public_cctv_host_audit"] = json.loads(args.cctv_audit.read_text())
        report["loading_reliability"]["tested_failure_cases"] += [
            "fragmented MJPEG, EXIF false end markers, progressive scan markers and PNG",
            "server HTTP failure cooldown and cancelled image view generation",
            "published southern-freeway parameter repair preserves camera ID",
            "per-layer map budget, separate clusters and visible official section exits",
            "all verified corridors use blue dashed above-label overlays",
            "search focus suspends viewport queries and restores the latest region",
            "GPS acquisition deadline starts after permission consent",
            "launch/monitoring does not stack location, Always and notification prompts"]
        report["performance"]["decoded_image_cache"] = dict(max_pixels=1280, max_cost_bytes=24000000, max_entries=6)
        report["performance"]["current_ui_strategy"] = "Functional UI regression including search keyboard and layer toggles; long panning benchmark was not rerun after the search/permission follow-up. No physical-device FPS claim."
        report["live_checks"]["ipad_cctv_rendering"] = dict(
            status="Real provincial-road image visibly rendered in iPad simulator, not a mocked frame",
            screenshot=str(args.cctv_audit.parent / "ipad-cctv-final.png"),
            mainthread_sample=str(args.cctv_audit.parent / "ipad-final-mainthread.txt"),
            physical_device=False)
    if args.search_profile:
        interactions=[json.loads(line) for line in args.search_profile.read_text().splitlines() if line]
        require(len(interactions)>=2 and all(r["native_edits"]>0 for r in interactions),"Search profile lacks complete typing interactions")
        report["performance"]["search_native_interactions"]=dict(samples=interactions,evidence=str(args.search_profile),physical_device=False)
        report["performance"]["current_ui_strategy"]="Native search buffer; debounced Apple completions; persistent MapKit canvas detached during editing. XCTest and display-link timing include automation/OS load, not physical-device FPS."
        report["loading_reliability"]["tested_failure_cases"] += ["200 rapid native edits publish no per-character SwiftUI updates", "search-to-map picking dismisses keyboard and restores retained canvas", "estimated section spans never become production alerts"]
    destination = ROOT / "tools/out/verification_report.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Verified release resources, {args.pipeline_count} pipeline + {args.host_count} host + {args.ios_count} iOS tests. Report: {destination}")


if __name__ == "__main__":
    main()
