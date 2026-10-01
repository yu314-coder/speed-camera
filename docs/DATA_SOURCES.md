# Traffic Data, Confidence and Coverage

## Sources

| Official source | Use | Limitation |
| --- | --- | --- |
| [Government catalog](https://data.gov.tw/datasets/export/csv) | Discovery and metadata | Metadata date is not a coordinate survey date |
| [7320 National Police](https://data.gov.tw/dataset/7320) | Enforcement points | Dual headers, direction and speed conflicts require validation |
| [13940 Freeway cameras](https://data.gov.tw/dataset/13940) | Freeway enforcement | Text/km-only locations are not guessed into alert points |
| [126156 New Taipei sections](https://data.gov.tw/dataset/126156) | Section endpoints | A point alone does not establish a complete corridor |
| Local police IDs in `source_manifest` | County/city records | Coverage, format and freshness vary |
| [Freeway shapes](https://tisvcloud.freeway.gov.tw/history/motc20/SectionShape.xml) and [sections](https://tisvcloud.freeway.gov.tw/history/motc20/Section.xml) | Road geometry/limits | Not nationwide city-road coverage |
| [Highway Bureau public data](https://thbapp.thb.gov.tw/opendata/) | Provincial geometry/CCTV | Individual video URLs may fail |
| [40476 Freeway speed rules](https://data.gov.tw/dataset/40476) | 20 rules, three shared footnotes | Segment, direction and heavy-vehicle exceptions |
| [121671 Taipei speed rules](https://data.gov.tw/dataset/121671) | 31 exceptions, three conditional 30 km/h entries | Not a complete geocoded Taipei network |
| [THB expressway table](https://www.thb.gov.tw/News_ExpresswaySpeedLimit.aspx?PageSize=10&n=165&sms=13790) | 30 reviewed website rows | Three pages only; six inaccessible-page rows omitted |
| [105021 speed signs](https://data.gov.tw/dataset/105021), [169929 enforcement](https://data.gov.tw/dataset/169929) | Candidate resources | Latest audited responses were non-data HTML |
| [26376 expressway statistics](https://data.gov.tw/dataset/26376) | Supplementary candidate | Published CSV returned HTTP 502 |

Public CCTV inventories: `https://tisvcloud.freeway.gov.tw/history/motc20/CCTV.xml` and `https://cctv-maintain.thb.gov.tw/opendataCCTVs.xml`. Playback uses per-record published government URLs, not invented replacement URLs or TDX credentials.

## Trust

- **A / Official:** explicit coordinate with usable road/direction context and successful validation. Matching and GPS gates must also pass before an alert.
- **B / Limited:** explicit coordinate with weak/conflicting context. Optional display, not default alert eligibility.
- **C / Estimated:** inferred/display-only road range. Not a surveyed endpoint or production alert corridor.
- **D / Excluded:** unsupported/PDF/statistical/non-geocodable material, reported rather than silently trusted.

All bundled camera points use published coordinates. Verified sections need coordinate-backed endpoints and sane connected geometry. Unresolved endpoints stay gray. Conflicting limits suppress alerts rather than choosing an arbitrary value. Deduplication preserves provenance and favors stronger/newer usable records.

Raw reference rules remain separate from geocoded road limits. For example, Tai 64 14.500-28.668 km specifies straight-road 70 / curve 60 and excludes the Minsheng overpass frontage road. It cannot become a universal Tai 64 speed or a guessed GPS limit.

## Freshness

The original camera/geometry build timestamp is September 30, 2026 UTC. Speed references were checked October 2 Taiwan time; Taipei metadata says December 12, 2025 and freeway metadata June 6, 2025. The THB website rows supply no surveyed update date. Download time is not an official rule-change date.

Runtime daily refresh covers national-police enforcement and freeway/provincial CCTV, while idle/online, with cooldowns and atomic valid-snapshot replacement. Failed feeds retain previous working records. Road/section geometry and speed references remain release-audited bundle data; not every county file or missing section endpoint is refreshed automatically.

Before release, run the full pipeline and review failures/coverage. Manually audit website reference snapshots. No single verified nationwide city-road speed table was found in this audited source set. Never turn a recent build date into a completeness claim.

## Attribution

National Police Agency and local police agencies (2026): enforcement and section datasets identified in `source_manifest`. Freeway Bureau (2026): public sections, shapes and CCTV; Highway Bureau (2026): provincial geometry/CCTV and expressway tables; Taipei Traffic Engineering Office: dataset 121671 with its retained metadata date.

Datasets whose catalog metadata declares license 1 are made available under Taiwan's [Open Government Data License, version 1.0](https://data.gov.tw/license). Preserve attribution and verify provider-specific terms, including [Highway Bureau public-data terms](https://thbapp.thb.gov.tw/opendata/). This project is not endorsed by these authorities.

OpenStreetMap contributors: derived display geometry and `osm_section_display_shapes.json` are under [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/). Estimated geometry is not an enforcement boundary. No permanent Apple route geometry is bundled.

The database retains source authority, dates and quality status. Generated local reports are excluded from Git because they may contain machine paths/diagnostics; these public docs retain the substantive coverage caveats.
