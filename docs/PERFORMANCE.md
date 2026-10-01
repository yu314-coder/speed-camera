# Performance and Validation

Map work uses debounced queries, actor-isolated SQLite, spatial indexes, bounded statement/geometry caches and retained annotations. Shared standard-range camera bitmaps are keyed by category, confidence display, appearance and scale. Their NSCache targets 2 MB of accounted pixels and 64 entries; these advisory limits are not an app-wide RAM ceiling.

Clusters reuse an icon/count view without shadows instead of producing images per count. CCTV groups stay separate; mixed enforcement uses an orange shield. Opaque main controls replace blur layers. Layer counts are recomputed with new viewport data, not every GPS/UI update.

Search buffers text in a native field and debounces Apple completions. Its retained map canvas is detached while editing and restored without losing camera data. Deadline/generation checks reject outdated search/route/ETA responses. Startup failures, stale GPS and retries remain visible rather than presenting old data as current.

CCTV uses one foreground stream, bounded compressed buffers, newest-only frames and off-main-actor decoding/downsampling. Display is limited to two frames per second. Dismissal/backgrounding releases images and cancels playback; failures have visible status and cooldowns.

## October 2, 2026 Measurement

Same iPhone 17 simulator, iOS 27.0, Debug, three panning iterations:

| Metric | Before | Final |
| --- | ---: | ---: |
| App CPU time | 6.387 s | 5.327 s |
| Gesture wall time | 7.534 s | 6.325 s |
| Mean physical memory | 156.5 MB | 148.1 MB |

The final run measured approximately 17% lower CPU time. Other optimization runs measured about 124.5-189.2 MB RAM, so total RAM was **not consistently lower**. No guaranteed memory reduction is claimed. MapKit caches, warm-up, system load and XCTest accessibility traversal affect results. These are not physical-device FPS/battery/GPS measurements.

The map/data pass verified 183 iOS units, eight simulator UI cases, 85 shared macOS cases and 20 pipeline cases. Shared cases overlap iOS coverage. After the final compact-cluster change, nine map-style units plus speed-library UI and the panning benchmark passed again. Both Release targets built unsigned.

The additive reference/UI pass left all 6,395 camera rows, 7,273 road rows and 38 section rows unchanged. It added 84 separate reference rules and a snapshot revision. Bundled resources were checked against source hashes.

Real-device RAM/battery/frame rate, GPS/compass/tunnel behavior, stacked-road matching, background notification delivery and expanded Notification Center rendering still need hardware validation. Build/upload success does not establish those outcomes; some valid government inventory URLs fail upstream.
