#!/usr/bin/env python3
"""
One-time migration: flat `marker` features -> the controller/zone/head/light model.

    ./migrate-zones.py in.geojson out.geojson

Every existing marker becomes a controller. `colorIdx` is frozen at the feature's
current array position, which is exactly what the old index-derived colouring
produced -- so the map looks identical the moment after migration. Nobody has to
relearn which colour is which box.

Ids become C<n> derived from the trailing number in the tag ("Box 10" -> C10) so
they are stable and human-readable. Tags are left alone: "Box 10" is what is
physically written on the hardware.

Safe to re-run. Already-migrated files pass through unchanged.
"""
import json
import re
import sys

PALETTE_LEN = 16


def tag_number(props, fallback):
    m = re.search(r"(\d+)\s*$", str(props.get("tag") or props.get("name") or ""))
    return int(m.group(1)) if m else fallback


def migrate(gj):
    feats = gj.get("features") or []
    out, seen_ids = [], set()
    converted = 0

    for i, f in enumerate(feats):
        p = dict(f.get("properties") or {})
        ftype = p.get("featureType")
        geom_type = (f.get("geometry") or {}).get("type")

        if ftype in ("controller", "zone", "head", "light"):
            out.append(f)                       # already migrated
            continue

        if ftype in (None, "", "marker"):
            ftype = "controller" if geom_type == "Point" else "zone"
            converted += 1

        n = tag_number(p, i + 1)
        prefix = "C" if ftype == "controller" else "Z"
        new_id = f"{prefix}{n}"
        while new_id in seen_ids:               # collision guard
            n += 1
            new_id = f"{prefix}{n}"
        seen_ids.add(new_id)

        props = {
            "id": new_id,
            "featureType": ftype,
            "tag": p.get("tag") or new_id,
            "name": p.get("name") or "",
            # freeze today's colour: the old code derived it from array position
            "colorIdx": i % PALETTE_LEN,
            "status": p.get("status") if p.get("status") in ("active", "flagged", "off") else "active",
            "notes": p.get("notes") or "",
        }
        if ftype == "controller":
            props["make"] = p.get("controller") or p.get("make") or ""
        else:
            props["controllerId"] = p.get("controllerId") or None
            props["valve"] = p.get("valve") or ""
            props["gpm"] = p.get("gpm") or ""
            props["schedule"] = p.get("schedule") or ""

        out.append({"type": "Feature", "geometry": f.get("geometry"), "properties": props})

    return {"type": "FeatureCollection", "features": out}, converted


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())

    with open(sys.argv[1], encoding="utf-8") as fh:
        gj = json.load(fh)

    if gj.get("type") != "FeatureCollection":
        sys.exit("input is not a GeoJSON FeatureCollection")

    result, converted = migrate(gj)

    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
        fh.write("\n")

    tally = {}
    for f in result["features"]:
        t = f["properties"].get("featureType", "?")
        tally[t] = tally.get(t, 0) + 1

    print(f"converted {converted} legacy feature(s)")
    for t, n in sorted(tally.items()):
        print(f"  {t}: {n}")
    print(f"wrote {sys.argv[2]}")


if __name__ == "__main__":
    main()
