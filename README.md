# Speed Camera

<img src="Speedlimit/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="Speed Camera app icon" width="128" height="128">

An offline-first iPhone and iPad app for Taiwan enforcement cameras, section-speed corridors, published speed limits and public traffic CCTV. Built with SwiftUI, MapKit, Core Location and SQLite.

Always obey posted signs. Coverage is partial and official files can contain errors. A camera warning is not a guarantee that a road has no other enforcement. Configure navigation and view CCTV only while safely stopped.

## Features

- Apple Maps basemap, native place search, map-point destination selection and alternate driving routes inside the app.
- App-built route guidance using public `MKDirections`, with traffic-aware ETA when Apple provides it. This is not Apple's proprietary embedded navigation interface.
- Separate speed, red-light, section-speed, other-enforcement and CCTV layers; configurable notifications with expanded Notification Center cards. No Live Activities.
- Conservative road/direction/forward-distance matching. Altitude is supplementary evidence, not proof of which stacked road you are on.
- Blue dashed verified section corridors, pale-blue estimated display spans and gray unresolved endpoints. Estimated spans do not authorize alerts.
- Colored numbered groups: category icons for single-type groups, orange shields for mixed enforcement, blue video badges for CCTV. Tap a group to zoom.
- Optional current-road panel, hidden by default, and a searchable offline speed-reference library with complete conditions, source links and dates.
- Public CCTV MJPEG playback without TDX credentials or app API keys. Image-only sources use labelled periodic snapshots; failed official feeds report errors.
- Optional daily checks for national-police camera data and freeway/provincial CCTV inventories. Failed sources retain their last working records; iOS controls background scheduling.

## Bundled Coverage

Camera/road snapshot: **September 30, 2026 (UTC)**. Additive speed-reference audit: **October 2, 2026 (Taiwan time)**. A fetch date is not a survey date.

| Data | Count |
| --- | ---: |
| Enforcement points | 2,257 |
| Public CCTV points | 4,138 |
| Alert-eligible camera records | 1,683 |
| Road segments | 7,273 |
| Coordinate-backed speed-limit segments | 453 |
| Section corridors | 38 |
| Verified corridors | 22 |
| Estimated display-only spans | 16 |
| Unresolved section endpoints | 11 |
| Published speed-reference rules | 84 |

The 84 references comprise 34 Taipei, 20 freeway and 30 expressway entries. Direction, kilometre, curve, frontage-road and vehicle restrictions are retained. They are **not geocoded** and never set a GPS limit from a road-name guess or authorize alerts. Only confidence-A camera records are alert-eligible by default.

County-only enforcement and verified section geometry remain release-audited bundle data. The runtime updater does not refresh every dataset or invent new section corridors. See [data sources and limitations](docs/DATA_SOURCES.md).

## Build

Requirements: macOS, Xcode with the iOS SDK, XcodeGen and Python 3. Minimum iOS/iPadOS 17; most recently verified with Xcode 27.0.

```sh
xcodegen generate
open Speedlimit.xcodeproj
```

Select the `Speedlimit` scheme and a device/simulator. For physical devices, choose **your own team** in Signing & Capabilities for both `Speedlimit` and `SpeedlimitNotificationContent`; change bundle identifiers if needed. Developer signing identities are not checked in.

The bundled database is included, so a download is not required to launch. Camera queries work offline; new Apple search/routes, traffic, uncached map tiles and CCTV need network. Runtime APIs use operating-system facilities or public government feeds; no app API key is required.

```sh
export BUILD_ROOT="${BUILD_ROOT:-$PWD/.local/build}"
mkdir -p "$BUILD_ROOT"
xcodebuild -project Speedlimit.xcodeproj -scheme Speedlimit \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_ROOT/ReleaseDerivedData" \
  CODE_SIGNING_ALLOWED=NO build
```

Use any build-output volume by overriding `BUILD_ROOT`. This unsigned command validates compilation, not sideloading or App Store delivery. Signing credentials and export options must stay local. Both targets declare `ITSAppUsesNonExemptEncryption=false`.

## Test

```sh
export BUILD_ROOT="${BUILD_ROOT:-$PWD/.local/build}"
mkdir -p "$BUILD_ROOT/tmp"
export TMPDIR="$BUILD_ROOT/tmp/"
export SPEED_CAMERA_TEST_TMPDIR="$BUILD_ROOT/test-data"
python3 -m unittest discover -s tools -p 'test_pipeline.py' -v
swift test -c release --scratch-path "$BUILD_ROOT/SwiftPM"
xcodebuild -project Speedlimit.xcodeproj -scheme Speedlimit \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

Choose an installed simulator name. Shared macOS cases overlap iOS unit tests. UI fixture routes/locations are Debug-only and disabled in Release. Live CCTV tests require `SPEEDLIMIT_LIVE_CCTV_TESTS=1` and depend on government-server availability.

The October 2 map/data pass verified 183 iOS unit cases, eight simulator UI cases, 85 shared macOS cases, 20 pipeline cases and an unsigned Release build of both targets. These do not establish real-device GPS, background notification delivery, battery or FPS. See [performance notes](docs/PERFORMANCE.md).

## Data Pipeline

```sh
mkdir -p tools/cache tools/out
python3 tools/fetch_sources.py
python3 tools/fetch_section_shapes.py --refresh
python3 tools/build_tw_traffic_db.py --refresh
```

Review `tools/out/traffic_build_report.json` before releasing. Validate required sources and retain the previous audited snapshot if a rebuild loses coverage. The builder parses supported formats, deduplicates records, validates geometry, records unsupported/unavailable resources and atomically publishes an integrity-checked SQLite database.

`tools/speed_references.py` supports additive reference imports from an audited cache without changing camera/corridor rows. `tools/fixtures/speed_references/` contains frozen public regression inputs with contact fields removed, **not a live cache**. The reviewed expressway website snapshot is partial, not an automatically refreshed complete inventory. Rebuilt data may have different counts; review both coverage and snapshot-dependent test expectations.

Caches, generated reports and build output are Git-ignored. `SPEED_CAMERA_BUILD_ROOT` sets portable defaults for `tools/verify_build.py`; pass appropriate log paths/counts for the actual run instead of treating historical defaults as fresh test execution.

## Architecture

```text
Speedlimit/Core/                  Models, geometry, matching, alert policy
Speedlimit/Services/              SQLite, location, Apple search/routes, feeds, CCTV
Speedlimit/Features/              Map, search, camera details, speed library, settings
Speedlimit/Resources/             Audited database and attributed OSM display shapes
SpeedlimitNotificationContent/    Expanded Notification Center camera card
SpeedlimitTests/                  Logic, recovery, data and rendering tests
SpeedlimitUITests/                Search, map, navigation and CCTV scenarios
tools/                           Builders, fixtures and verification
project.yml                      Reproducible XcodeGen specification
Package.swift                    Shared-core macOS test package
```

Rendering retains unchanged annotations, shares cached icons and uses compact cluster views. Viewport queries are debounced; search detaches the retained map canvas while editing. Route/road work uses indexed geometry and bounded caches. CCTV uses one foreground stream, a newest-frame queue, off-main-actor downsampling and a two-frame-per-second display ceiling. Dismissal/backgrounding stops playback and releases frames.

## Privacy and Security

No developer API credentials, certificates, device identifiers, personal route logs, Xcode user state or local machine paths are intentionally published. Location matching runs on-device. Apple search/directions may send relevant location/search/route information to Apple; government servers receive data/video requests and normal network metadata. Network use is not promised to be anonymous.

There is no custom analytics backend or TDX secret requirement. Location, notifications and optional background permissions are separate. Unsuitable/stale GPS pauses guidance and alerts. Start monitoring/navigation before leaving the app; force-quitting stops monitoring and iOS may limit delivery.

See [SECURITY.md](SECURITY.md). Publication audits are point-in-time checks, not a guarantee against future accidental commits.

## Attribution and Licensing

Traffic records are credited to Taiwan's National Police Agency, local police agencies, Freeway Bureau, Highway Bureau and Taipei Traffic Engineering Office. Dataset-specific provenance and terms are in [DATA_SOURCES.md](docs/DATA_SOURCES.md) and the bundled `source_manifest`.

OpenStreetMap contributors supply limited **display-only** road shapes under ODbL 1.0, exported in `Speedlimit/Resources/osm_section_display_shapes.json`. Apple basemap/directions are provided at runtime; no Apple route database is redistributed.

Third-party data retains its original terms. No separate source-code license has been selected; public visibility alone is not a general software license.
