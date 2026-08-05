# Irrigation Map — Multi-Feature Design

Design for extending the Auburn Fields irrigation map from a flat marker list to a
four-type hierarchical model: controllers, zones, sprinkler heads, and light poles.

**Status:** implemented and deployed 2026-07-26 (all three phases)
**Supersedes:** the flat `featureType: "marker"` model

## Changes made during implementation

Three things diverged from the plan once it met the real data and a real test:

1. **13 controllers, not 12.** The physical diagram had a Box 13. The palette grew
   from 12 to 16 slots so it gets its own color instead of wrapping back onto
   Box 10's yellow. The first 12 colors are byte-identical to the previous build.
2. **Client-side public filtering was not enough.** `zones.geojson` is served by
   Apache and readable by anyone, so filtering in JS hid operational detail from
   the *view* while still shipping it to the *browser* — the design doc claimed
   otherwise. Corrected: the full set now lives in the Apache-denied
   `irrigation-admin/` directory behind a capability-gated read endpoint, and the
   save endpoint derives a filtered public copy on every write.
3. **Tags kept as "Box N".** The plan renamed tags to `C1`…`C13`; the hardware is
   physically labelled "Box N", so only the internal `id` uses the `C` prefix.

Zoom-gating was also dropped as redundant — marker clustering already handles head
density, and hiding heads entirely below a zoom threshold was strictly worse UX
than showing them as cluster bubbles.

---

## Decisions

| Question | Decision |
|---|---|
| Hierarchy | Controller → Zone → Head (3 levels) |
| Existing 12 markers | Become the 12 controllers |
| Controller color | Auto-assigned from palette |
| Zone color | Auto-assigned from palette |
| Head color | Inherited from parent zone |
| Light pole color | Fixed yellow, not palette-assigned |
| Head count (projected) | 150–400 → clustering required |
| Head data entry | Rapid-place mode, no per-click prompts |
| Zone geometry | Polygons drawn over time; heads auto-link by containment |
| Public map | Zones + light poles only |

---

## Data model

Single `zones.geojson` holds all four types, discriminated by `featureType`.
Filename kept as-is to avoid breaking the fetch path in both HTML builds and the
Export button, even though it now holds more than zones.

### Controller (Point)

```json
{
  "type": "Feature",
  "geometry": { "type": "Point", "coordinates": [-111.8709, 40.5383] },
  "properties": {
    "id": "C1",
    "featureType": "controller",
    "tag": "C1",
    "name": "Controller 1 — Auburn Fields Way",
    "colorIdx": 0,
    "status": "active",
    "make": "",
    "notes": ""
  }
}
```

### Zone (Polygon; Point tolerated during migration)

```json
{
  "properties": {
    "id": "Z5",
    "featureType": "zone",
    "controllerId": "C1",
    "tag": "Z5",
    "name": "Building 15 Frontage",
    "colorIdx": 4,
    "status": "active",
    "valve": "2",
    "gpm": "18",
    "schedule": "MWF 5:00a",
    "notes": ""
  }
}
```

### Sprinkler head (Point)

```json
{
  "properties": {
    "id": "H-a3f2",
    "featureType": "head",
    "zoneId": "Z5",
    "tag": "H-12",
    "name": "",
    "headType": "rotor",
    "status": "active",
    "notes": ""
  }
}
```

`zoneId` is set automatically by point-in-polygon test at placement time.
`null` means the head landed outside every zone polygon — see *Unassigned heads*.

### Light pole (Point)

```json
{
  "properties": {
    "id": "L-7",
    "featureType": "light",
    "tag": "LP-7",
    "name": "Pole 7 — Shadow View Ln",
    "status": "active",
    "lampType": "LED",
    "notes": ""
  }
}
```

### Color resolution

```
controller → ZONE_COLORS[controller.colorIdx]
zone       → ZONE_COLORS[zone.colorIdx]
head       → color of parent zone, looked up via zoneId
head (unassigned) → #94A3B8 gray, dashed ring
light      → #FDD835 always
```

**`colorIdx` is stored in the data, not derived from array position.**

The current implementation uses `DATA.features.indexOf(f)`, which means deleting
any feature silently recolors everything after it. Storing the index makes colors
stable across edits, imports, and reorders — the property that matters most once
board members are learning the map by color.

New features take `max(existing colorIdx) + 1`, wrapping at the palette length.

---

## Visual specification

| Type | Shape | Size | Color | Label | Renders at zoom |
|---|---|---|---|---|---|
| Controller | Rounded square, grid glyph | 34×34 | own palette color | permanent, tag | all |
| Zone | Polygon, 2.5px stroke, 25% fill | — | own palette color | permanent, centered | all |
| Head | Filled circle, white ring | 11×11 | parent zone color | hover only | ≥ 18 |
| Light | Circle with radiating rays | 24×24 | `#FDD835` | hover only | ≥ 17 |

**Shape carries type; color carries identity.** Color is never the only thing
distinguishing two feature types — that breaks for colorblind users and at small
sizes. A controller and a zone can share a palette color and still be instantly
distinguishable because one is a square and one is an area.

Icon rationale:
- **Controller** — square reads as fixed infrastructure, and squares survive being
  drawn small far better than teardrops.
- **Head** — small dot. Individually low-importance, collectively a density map.
  At 400 features anything larger than ~12px is visual noise.
- **Light** — radiating rays are universally read as illumination, and the fixed
  yellow means a resident never has to consult a legend.

Heads are deliberately not tap targets at normal zoom. They become tappable at
zoom 19+, which is where you'd be if you cared about an individual head.

---

## Layer and performance strategy

Four independent Leaflet layer groups, each separately toggleable:

```
controllerLayer   always on
zoneLayer         always on
headLayer         clustered; individual heads at zoom ≥ 18
lightLayer        zoom ≥ 17
```

For 150–400 heads:

- `L.markerClusterGroup` (Leaflet.markercluster — CDN, no API key)
- Cluster bubble tinted by the dominant zone color inside it
- `disableClusteringAtZoom: 19`
- `chunkedLoading: true` so initial render doesn't block the main thread
- `L.canvas()` renderer for zone polygons — SVG paths plus 400 DOM markers is
  measurably slow on phones

---

## Sidebar redesign

The current flat list does not survive four types and 400 features. Replace with
a collapsible tree:

```
IRRIGATION ZONES
  Board Admin

▸ LAYERS
  ☑ Controllers        12
  ☑ Zones              12
  ☑ Sprinkler heads   247
  ☑ Light poles        31

▸ STATUS
  ● Active            288
  ⚑ Flagged             9
  ○ Off                 5

▾ CONTROLLERS
  ■ C1   Auburn Fields Way          4 zones
       Z1  Building 1 Frontage     18 heads
       Z4  Center Green            22 heads
  ■ C2   Shadow View Ln            3 zones
       …
```

Collapsed to the controller level by default.

**Heads are never listed individually.** 400 rows is not a browsable list. You
find a head by clicking it on the map; the rail exists to navigate the hierarchy
above it. Head counts roll up to their zone.

Status filtering cross-cuts all four types rather than applying only to zones.

---

## Rapid-place mode

The interaction that makes several hundred heads realistic to enter.

```
Edit → "Place heads"
  cursor → crosshair
  banner → "Placing heads — click to drop. Esc to stop."

  click → head dropped at cursor
          point-in-polygon against all zone polygons
            inside Z5  → zoneId = Z5, inherits Z5 color, tag = next free H-n
            inside none → zoneId = null, gray + dashed ring
  click → next head, no prompt
  …
  Esc   → exit; toast "Placed 34 heads in Zone 5"
```

No dialog between clicks. Naming is deferred and usually skipped entirely — most
heads only ever need a position and a parent zone.

**Undo:** `Ctrl+Z` removes the last-placed head within the session.

### Unassigned heads

A head dropped outside every zone polygon renders gray with a dashed ring, and the
rail shows an `N unassigned` counter while any exist. This makes misplacement
visible immediately rather than discovered months later, and gives a concrete
worklist for cleanup. Clicking an unassigned head offers a zone dropdown.

---

## Public vs admin builds

Both builds come from one source, gated by the existing `MODE` constant.

| | Public | Admin |
|---|---|---|
| Zones | ✅ | ✅ |
| Light poles | ✅ | ✅ |
| Controllers | ❌ | ✅ |
| Sprinkler heads | ❌ | ✅ |
| Layer toggles | zones, lights | all four |
| Draw / edit | ❌ | ✅ |
| Import / export | ❌ | ✅ |
| Popup fields | name, status, notes | + controller, valve, gpm, schedule, head count |

The public build **filters at load**, not via CSS hiding:

```js
DATA.features = DATA.features.filter(f =>
  ['zone', 'light'].includes(f.properties.featureType));
```

Operational detail — valve numbers, controller makes, head positions — should not
be sitting in a resident's browser at all, even hidden. Filtering at load also
keeps the public map fast, since it never builds the 400-head cluster layer.

---

## Migration

Current state: 12 Point features with `featureType: "marker"`.
Target: 12 controllers.

One-time transform:

```
for each feature, in current array order:
  featureType : "marker" → "controller"
  id          : M1 → C1
  tag         : Z1 → C1
  colorIdx    : <current array index>
  name        : unchanged
  geometry    : unchanged
```

Setting `colorIdx` from the current array index **freezes today's colors**. The map
looks identical the moment after migration — no surprise recolor for board members
who have already started learning which color is which controller.

Zones, heads, and lights start empty.

---

## Hard dependency: saving

This is the blocker to flag before Phase 3.

The current workflow is *export a file → `kubectl cp` it back*. That is survivable
for 12 markers. It is not survivable for rapid-place: a board member placing heads
for an hour who closes the tab without exporting loses all of it, with no warning
and no recovery.

**Phase 3 must not ship before a real save path exists.** Two options, in order of
preference:

1. **Save endpoint** — an authenticated `POST` in the irrigation mu-plugin that
   writes `zones.geojson` directly, with a Save button and a dirty-state indicator.
   Board members never touch a file.
2. **Browser upload** (the previously-planned "Option A") — an upload form plus a
   PHP handler. Still a manual step, but removes `kubectl` from the loop.

Interim mitigation regardless of which lands: a `beforeunload` warning whenever
there are unsaved changes.

---

## Phasing

**Phase 1 — foundation.** No visible change.
- Migrate 12 markers → controllers
- Add `featureType`, `colorIdx`, and parent-link fields
- Replace index-derived colors with stored `colorIdx`
- Split rendering into four layer groups
- *Ships:* identical-looking map on a model that can grow

**Phase 2 — zones and lights.**
- Zone polygon drawing, assigned to a controller
- Light pole type, icon, and status
- Rail tree
- Public build filtered to zones + lights
- *Ships:* residents get a real zone map; board gets light inventory

**Phase 3 — sprinkler heads.** Gated on the save path above.
- Clustering and zoom-gating
- Rapid-place mode
- Point-in-polygon auto-linking
- Unassigned-head handling
- *Ships:* full head inventory

Phases 1 and 2 are independently shippable. Phase 3 is last both because it is the
largest and because auto-linking heads requires zone polygons to exist first.

---

## As-built layout

Source of truth is now in the repo. The two deployed HTML copies are build
artifacts, generated from one file by a token swap — which is what stops the
admin and public builds from drifting apart the way they did previously.

| Path | Role |
|---|---|
| `kubernetes/apps/hoa/irrigation-map/irrigation-map.src.html` | canonical source, `__MODE__` placeholder |
| `kubernetes/apps/hoa/irrigation-map/build.sh` | `./build.sh [deploy]` — builds both variants |
| `kubernetes/apps/hoa/irrigation-map/migrate-zones.py` | one-time legacy migration, idempotent |
| `kubernetes/apps/hoa/irrigation-plugin.yaml` | mu-plugin: gate, data endpoint, save endpoint |

Runtime state in the pod:

| Path | Access |
|---|---|
| `uploads/irrigation-admin/irrigation-admin.html` | Apache-denied; served by the plugin with the nonce injected |
| `uploads/irrigation-admin/zones.geojson` | Apache-denied; full set, board only |
| `uploads/irrigation-maps/irrigation-map.html` | public |
| `uploads/irrigation-maps/zones.geojson` | public; zones + lights only, derived on save |

Every CDN asset carries a SHA-384 Subresource Integrity hash. This page renders
inside a logged-in WordPress editor session, so an unpinned CDN script would be a
path to session compromise.

## Verified

| Check | Result |
|---|---|
| Public map HTML / data | 200 |
| Admin HTML direct fetch | 403 |
| **Full data direct fetch** | **403** |
| `/irrigation-admin` anonymous | 302 to login |
| `/irrigation-admin/data` anonymous | 401 |
| `POST /save` anonymous | 401 |
| `POST /save` wrong method | 405 |
| `POST /save` bad nonce | 403 |
| `POST /save` malformed body | 400 |
| `POST /save` authenticated editor | 200, writes full + filtered copies, `.bak` retained |
| Public copy leak check | 0 controller/head features |

One bug surfaced during testing and was fixed: WordPress sets a 404 status on
unrouted paths before `template_redirect` runs, so `/irrigation-admin/data`
returned a correct body under a 404 status. The admin JS checks `response.ok`,
so the map would have silently failed to load. Both non-JSON endpoints now set
`status_header(200)` explicitly.
