# Every Texan FAFSA Completion Tracker

GitHub Pages version of the Every Texan FAFSA Completion Tracker (ArcGIS dashboard), served from `/docs`.

- `data-prep/build_data.R` reads `fafsa_districts_2026.geojson` and writes `docs/data/fafsa.json` and a simplified `docs/data/districts.geojson`.
- `docs/index.html` is the dashboard (MapLibre GL JS, no build step).

## Data

Texas Education Agency FAFSA completion reports (2022–23 through 2024–25) and Texas Academic Performance Reports, via the `fafsa_districts_2026` ArcGIS layer.

The ArcGIS layer only has traditional ISDs. To add charter districts, export the charter-inclusive dashboard table as `fafsa_long.csv` in the project root (columns `district_name`, `county_name`, `community_type`, `Sector`, `year`, `fafsa_completed`, `total_graduates`, `fafsa_completion_rate`; years formatted like `2024-2025`) and rerun `build_data.R`.

## Methods

- Completion rate = FAFSAs completed ÷ graduates, summed across districts.
- "Districts below 50%" counts districts with a rate under 50% and at least one completion.
- The lowest-rates table lists up to 25 districts with 30+ graduates and at least one completion. Rates under 40% are red.
- Districts split into several polygons are counted once.
