#!/usr/bin/env python3
"""
Rebuilds the Auburn Fields HOA unit maps from the source spreadsheets.

Usage:
    uv run --with pandas --with openpyxl python3 build.py

Inputs (edit these files to update the data):
    data/Rental Units 2026.xlsx           - rental roll (Unit, Homeowner Address, Homeowner, Renter Occupied Unit)
    data/Auburn Fields Parking  (Responses).xlsx  - "Registered Address" tab (Address, Registered)
    overrides.json                        - manual fixes for rental rows that don't match any registered address

Outputs:
    output/street_map.html   - schematic street-by-street layout, owned vs rented
    output/geo_map.html      - real Leaflet/OpenStreetMap map, rented units marked

Geocoding is cached in cache/geocode_cache.json keyed by address string, so only
new/changed addresses hit Nominatim (rate-limited to 1 req/sec, no API key needed).
"""
import json
import re
import time
import urllib.request
import urllib.parse
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).parent
DATA_DIR = ROOT / "data"
CACHE_DIR = ROOT / "cache"
OUTPUT_DIR = ROOT / "output"
TEMPLATES_DIR = ROOT / "templates"

RENTAL_XLSX = DATA_DIR / "Rental Units 2026.xlsx"
PARKING_XLSX = DATA_DIR / "Auburn Fields Parking  (Responses).xlsx"
OVERRIDES_JSON = ROOT / "overrides.json"
GEOCODE_CACHE = CACHE_DIR / "geocode_cache.json"

DIR_WORDS = {"S", "SO", "SOUTH", "E", "EAST", "N", "NORTH", "W", "WEST"}
SUFFIX_MAP = {
    "LANE": "LN", "DRIVE": "DR", "STREET": "ST", "CIRCLE": "CIR",
    "AVENUE": "AVE", "COURT": "CT", "PLACE": "PL",
}
STREET_FULL = {
    "SHADOW VIEW LN": "Shadow View Lane",
    "AUTUMN BRANCH WAY": "Autumn Branch Way",
    "AUBURN FIELDS WAY": "Auburn Fields Way",
    "HARVEST BEND WAY": "Harvest Bend Way",
}
STREET_ORDER = ["SHADOW VIEW LN", "AUTUMN BRANCH WAY", "AUBURN FIELDS WAY", "HARVEST BEND WAY"]


def norm(addr):
    s = str(addr).upper().replace(".", "")
    parts = s.split()
    num = parts[0]
    rest = [p for p in parts[1:] if p not in DIR_WORDS]
    rest = [SUFFIX_MAP.get(p, p) for p in rest]
    return num + " " + " ".join(rest)


def street_of(addr):
    s = str(addr).upper().replace(".", "")
    parts = [p for p in s.split()[1:] if p not in DIR_WORDS]
    parts = [SUFFIX_MAP.get(p, p) for p in parts]
    return " ".join(parts)


def load_data():
    r = pd.read_excel(RENTAL_XLSX, sheet_name="Sheet1")
    r.columns = ["Unit", "HomeownerAddress", "Homeowner", "RenterOccupied"]
    r = r.iloc[1:].reset_index(drop=True)
    r["norm"] = r["Unit"].apply(norm)

    a = pd.read_excel(PARKING_XLSX, sheet_name="Registered Address")
    a.columns = ["Address", "Registered", "c2", "c3", "c4"]
    a = a[a["Address"].astype(str).str.match(r"^\d")].reset_index(drop=True)
    a["num"] = a["Address"].astype(str).str.extract(r"^(\d+)").astype(int)
    a["street"] = a["Address"].apply(street_of)
    a["registered"] = a["Registered"] == "✅"
    a["norm"] = a["Address"].apply(norm)

    return r, a


def match(r, a, overrides):
    rental_owner = dict(zip(r["norm"], r["Homeowner"]))
    matched_norms = set(a["norm"])

    rows = []
    for _, row in a.iterrows():
        rows.append({
            "address": row["Address"],
            "num": int(row["num"]),
            "street": row["street"],
            "registered": bool(row["registered"]),
            "rented": row["norm"] in rental_owner,
            "owner": rental_owner.get(row["norm"]),
        })

    unmatched = r[~r["norm"].isin(matched_norms)]
    override_map = overrides.get("unmatched_rentals", {})
    for _, row in unmatched.iterrows():
        ov = override_map.get(row["Unit"])
        if ov and ov.get("action") == "keep_as_extra":
            rows.append({
                "address": row["Unit"],
                "num": int(re.match(r"^(\d+)", row["Unit"]).group(1)),
                "street": street_of(row["Unit"]),
                "registered": None,
                "rented": True,
                "owner": row["Homeowner"],
                "extra": True,
            })
        else:
            print(f"WARNING: unmatched rental '{row['Unit']}' has no override entry — excluded. "
                  f"Add it to overrides.json if it should count.")

    return rows


def geocode(num, street_full, cache_session):
    params = {
        "street": f"{num} {street_full}", "city": "Draper", "state": "Utah",
        "postalcode": "84020", "country": "US", "format": "json", "limit": 1,
    }
    url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "auburn-fields-hoa-map/1.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
    if data:
        return float(data[0]["lat"]), float(data[0]["lon"])
    return None, None


def add_coords(rows):
    cache = {}
    if GEOCODE_CACHE.exists():
        for u in json.load(open(GEOCODE_CACHE)):
            cache[u["address"]] = u

    updated = False
    for row in rows:
        cached = cache.get(row["address"])
        if cached and cached.get("lat") is not None:
            row["lat"], row["lon"] = cached["lat"], cached["lon"]
            continue
        street_full = STREET_FULL.get(row["street"], row["street"].title())
        print(f"geocoding {row['address']} ...")
        lat, lon = geocode(row["num"], street_full, cache)
        row["lat"], row["lon"] = lat, lon
        updated = True
        time.sleep(1.1)

    if updated:
        CACHE_DIR.mkdir(exist_ok=True)
        json.dump(rows, open(GEOCODE_CACHE, "w"), indent=2)

    return rows


def build_street_map(rows, summary):
    streets = {}
    for row in rows:
        streets.setdefault(row["street"], []).append(row)
    for s in streets:
        streets[s].sort(key=lambda x: x["num"])

    template = (TEMPLATES_DIR / "street_map_template.html").read_text()
    data = {"summary": summary, "streets": streets}
    html = template.replace("__DATA_JSON__", json.dumps(data))
    OUTPUT_DIR.mkdir(exist_ok=True)
    (OUTPUT_DIR / "street_map.html").write_text(html)
    print(f"wrote {OUTPUT_DIR / 'street_map.html'}")


def build_geo_map(rows, summary):
    slim = [
        {"address": u["address"], "rented": u["rented"], "owner": u.get("owner"),
         "lat": u["lat"], "lon": u["lon"]}
        for u in rows if u.get("lat") is not None
    ]
    template = (TEMPLATES_DIR / "geo_map_template.html").read_text()
    html = template.replace("__UNITS_JSON__", json.dumps(slim))
    html = html.replace("__TOTAL_UNITS__", str(summary["total"]))
    OUTPUT_DIR.mkdir(exist_ok=True)
    (OUTPUT_DIR / "geo_map.html").write_text(html)
    print(f"wrote {OUTPUT_DIR / 'geo_map.html'}")


def main():
    overrides = json.load(open(OVERRIDES_JSON)) if OVERRIDES_JSON.exists() else {}
    r, a = load_data()
    rows = match(r, a, overrides)
    rows = add_coords(rows)

    total = overrides.get("force_total_units", len(rows))
    rented = sum(1 for x in rows if x["rented"])
    summary = {"total": total, "rented": rented, "owned": total - rented}
    print("summary:", summary)

    build_street_map(rows, summary)
    build_geo_map(rows, summary)


if __name__ == "__main__":
    main()
