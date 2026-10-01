# Frozen Public Reference Inputs

These are regression fixtures for the audited September/October 2026 snapshot, not fresh downloads for another release. Metadata contains only source modification date and resource format/URL; publisher contact fields are omitted.

- `121671_0.bin`, `121671_1.bin`: official Taipei CSV bytes in their original encoding.
- `40476_0.bin`: official freeway CSV, including its three shared footnotes.
- `thb_speed_references.json`: 30 exact Highway Bureau website rows, original checked time/source URLs and explicit partial-snapshot status.

Attribution and caveats are in `docs/DATA_SOURCES.md`. Tests preserve conditional limits and verify that additive imports do not change camera/corridor rows. A fixture checkout timestamp is not a newly verified source-update date.
