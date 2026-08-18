# Auburn Fields HOA — Unit Maps

Generates two HTML maps for Auburn Fields HOA (Draper, UT) from the rental roll
and the parking-registration address list: owned vs. rented, per unit.

- `output/street_map.html` — schematic layout, grouped by street, house-number order
- `output/geo_map.html` — real Leaflet/OpenStreetMap map, rented units pinned (no API key needed)

## To update the data

1. Replace the files in `data/` with fresh exports:
   - `Rental Units 2026.xlsx` — the rental roll (Unit, Homeowner Address, Homeowner, Renter Occupied Unit)
   - `Auburn Fields Parking  (Responses).xlsx` — must have a `Registered Address` tab (Address, Registered)
2. Run:
   ```
   cd hoa-map
   uv run --with pandas --with openpyxl python3 build.py
   ```
3. Open `output/street_map.html` and `output/geo_map.html` in a browser (or copy them
   wherever you want — they're fully standalone, no server needed).

New addresses get geocoded automatically (OpenStreetMap Nominatim, rate-limited to
1 req/sec, no API key). Results are cached in `cache/geocode_cache.json` keyed by
address string, so re-runs only geocode addresses that weren't seen before.

## overrides.json

The rental roll sometimes has a row whose address doesn't match anything in the
`Registered Address` tab (e.g. a builder/model-home address, a typo, a renumbering).
The build script prints a `WARNING` for any such row and excludes it — unless you
add an entry to `overrides.json`:

```json
"unmatched_rentals": {
  "<exact Unit string from Rental Units 2026.xlsx>": {
    "action": "keep_as_extra",
    "note": "why this is being kept"
  }
}
```

`force_total_units` in the same file pins the "Total Units" stat shown on both maps
(useful when the registry count and the actual matched-row count diverge, as with
the Rimrock Construction entry — see the note in `overrides.json`).

## Editing the look

`templates/street_map_template.html` and `templates/geo_map_template.html` hold the
page design (CSS, layout, popup content). `build.py` just swaps in the data — edit
the templates directly for visual changes, then re-run `build.py`.
