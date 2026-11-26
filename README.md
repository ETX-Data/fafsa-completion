# Every Texan FAFSA Completion Tracker

GitHub Pages version of the Every Texan FAFSA Completion Tracker (ArcGIS dashboard), served from `/docs`.

- `data-prep/build_data.R` reads `fafsa_districts_2026.geojson` and writes `docs/data/fafsa.json`, `docs/data/profiles.json`, a simplified `docs/data/districts.geojson`, and the Texas House/Senate files `docs/data/legislative.json` (school districts serving each legislative district) and `docs/data/legislative.geojson`.
- `docs/index.html` is the dashboard (MapLibre GL JS, no build step).

## Data

Texas Education Agency FAFSA completion reports (2022–23 through 2024–25) and Texas Academic Performance Reports, via the `fafsa_districts_2026` ArcGIS layer.

The ArcGIS layer only has traditional ISDs. To add charter districts, export the charter-inclusive dashboard table as `fafsa_long.csv` in the project root (columns `district_name`, `county_name`, `community_type`, `Sector`, `year`, `fafsa_completed`, `total_graduates`, `fafsa_completion_rate`; years formatted like `2024-2025`) and rerun `build_data.R`.

## Methods

- Completion rate = FAFSAs completed ÷ graduates, summed across districts. District-years whose completion count TEA suppressed are left out of both numerator and denominator.
- "Graduates without a FAFSA" = graduates − completions.
- "Districts below 50%" counts districts with a rate under 50% and at least one completion.
- The district table lists every district matching the filters (optionally only those with 30+ graduates), leaving out districts reporting zero completions. It sorts by any column and downloads as CSV. Rates under 40% are red. "Change" is percentage points since 2022–23.
- The district profile compares the district with its county, its community type ("similar districts"; all charters for charters) and the state for the selected school year.
- Texas House and Senate districts come from Census TIGER/Line 2026 (`tiger_download/`, fetched by `build_data.R`). A school district counts as serving a legislative district when their overlap is at least 5% of either one's area, or it is the school district's largest overlap, so one school district can count toward several legislative districts. Charter districts have no boundaries and are not included in legislative totals.
- Districts split into several polygons are counted once.
