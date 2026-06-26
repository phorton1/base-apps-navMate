# navMate - Data Model

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**Data Model** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**[Spoke Contract](navOps_spoke_contract.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)** --
**[Testing](testing.md)** --
**[winFSH](winFSH.md)** --
**[winMultiEditor](winMultiEditor.md)** --
**[E80Config](e80_config.md)** --
**[Timed Tracks](timed_tracks.md)**

repos: **[phorton1](https://github.com/phorton1)** --
**[Ray Library](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/readme.md)** --
**[shark Tool](https://github.com/phorton1/base-apps-shark/blob/master/docs/shark.md)** --
**navMate App**

## Core Objects - WRT

navMate manages four first-class navigation objects, collectively referred to as
**WRTG** (Waypoints, Routes, Tracks, Groups):

- **Waypoint** - a named geographic point with position, type, and optional metadata.
- **Route** - an ordered sequence of waypoints defining a planned path.
- **Track** - a recorded sequence of positions representing a path actually travelled;
  the primary historical record.
- **Group** - a waypoint-only collection that maps one-to-one to an E80 WPMGR group
  on upload; the organizational unit for waypoint sets pushed to the chartplotter.

Routes are forward-looking planning artifacts. Tracks are historical voyage records.
The historical dataset is almost entirely Tracks and Waypoints - Routes were not used
historically and should not be assumed as the primary historical structure.

A group is a waypoint-only leaf collection stored with `node_type='group'` in the
collections table. Groups have no sub-collections, routes, or tracks - only direct
waypoints. On upload, each group maps one-to-one to an E80 WPMGR group. Group
membership is structural: a waypoint belongs to whichever group collection it resides
in, not via a separate association table.

## Storage

SQLite is the authoritative store. All WRT objects are persisted locally. The E80
and any other connected device are peers that navMate syncs with - not masters that
navMate caches.

navMate may carry metadata, organizational structure, and historical depth that has
no equivalent on any connected device. The schema is not constrained to what the E80
wire protocol can represent.

## Object Identity - UUIDs

All objects are identified by UUID. navMate is UUID-primary: name lookup is a
convenience layer, not the identity mechanism. E80 object names are not unique and
cannot serve as reliable identifiers across sync operations.

navMate-created UUIDs use byte 1 = `0x4E` (`N` for navMate), which does not collide
with E80-native UUIDs (byte 1 = `0xB2`) or RNS-created UUIDs (byte 1 = `0x82`).
Bytes 4-5 hold a persistent counter from navMate's SQLite store; bytes 6-7 provide
intra-tick uniqueness. The full UUID structure is documented in [WPMGR.md](https://github.com/phorton1/base-Pub-Ray/blob/master/NET/docs/WPMGR.md).

**UUID collision risk after E80 factory reset.** When navMate imports objects from an
E80 it preserves the original E80-native UUIDs (byte 1 = `0xB2`). If that E80 is
subsequently factory-reset, its internal UUID counter restarts and may regenerate UUIDs
that overlap the ones already stored in navMate. Pushing those navMate objects back to
the reset E80 could collide with newly-generated E80 UUIDs. This risk exists whenever
E80-native UUIDs are round-tripped through navMate and is not currently mitigated;
it is noted here for future sync-layer design.

## Schema

navMate uses SQLite as its authoritative data store. The schema version is tracked
in the `key_values` table and incremented on migrations.

### collections

The collection tree is the organizational hierarchy for all WRT objects. Every
WRT object exists in exactly one collection.

```sql
collections (
  uuid          TEXT PRIMARY KEY,
  name          TEXT    NOT NULL,
  parent_uuid   TEXT    NOT NULL DEFAULT '' REFERENCES collections(uuid),  -- '' = root-level node (schema 13.0)
  node_type     TEXT    NOT NULL DEFAULT 'branch',  -- 'branch' or 'group'
  comment       TEXT    NOT NULL DEFAULT '',
  position      REAL    NOT NULL DEFAULT 0,         -- display order within parent (schema 10.0)
  source        TEXT    NOT NULL DEFAULT '',        -- see Provenance Columns (schema 11.3)
  created_ts    INTEGER NOT NULL DEFAULT 0,         -- see Provenance Columns (schema 11.3)
  modified_ts   INTEGER NOT NULL DEFAULT 0          -- see Provenance Columns (schema 11.3)
)
```

Collections form the organizational hierarchy. Two `node_type` values are stored in
the DB:

| node_type | Meaning |
|-----------|---------|
| `'branch'` | General organizer - may hold any WRT objects and sub-collections |
| `'group'`  | Waypoint-only leaf collection - maps one-to-one to an E80 WPMGR group on upload |

A post-import pass (`promoteWaypointOnlyBranches`) promotes any `branch` that has
waypoints and no sub-collections, routes, or tracks to `node_type='group'`.
Mixed-content `branch` collections (waypoints alongside tracks or routes, for example)
remain `branch`. Every WRT object belongs to exactly one collection via a non-null
`collection_uuid` foreign key.

### waypoints

```sql
waypoints (
  uuid              TEXT PRIMARY KEY,    -- navMate UUID (byte 1 = 0x4E)
  name              TEXT NOT NULL,
  comment           TEXT DEFAULT '',
  lat               REAL NOT NULL,       -- degrees WGS84
  lon               REAL NOT NULL,       -- degrees WGS84
  wp_type           INTEGER NOT NULL DEFAULT 0,  -- enum; see Waypoint Types (schema 12.0)
  sym               INTEGER NOT NULL DEFAULT 0,  -- 0..35 E80 wire symbol (schema 12.0); see Sym
  color             TEXT    NOT NULL DEFAULT '', -- aabbggrr hex; '' -> 'FFFFFFFF' type default (schema 13.0)
  depth_cm          INTEGER NOT NULL DEFAULT 0,  -- non-zero only for sounding waypoints
  temp_k            INTEGER NOT NULL DEFAULT 0,  -- water temperature x 100 Kelvin (schema 11.2); 0 = no reading (schema 13.0)
  created_ts        INTEGER NOT NULL DEFAULT 0,  -- Unix epoch seconds; never NULL; see Provenance Columns
  ts_source         TEXT    NOT NULL DEFAULT '', -- see Timestamp Sources
  source            TEXT    NOT NULL DEFAULT '', -- see Provenance Columns
  collection_uuid   TEXT NOT NULL REFERENCES collections(uuid),
  db_version        INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0); see Version Columns
  e80_version       INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0)
  kml_version       INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0)
  position          REAL    NOT NULL DEFAULT 0,  -- display order within collection (schema 10.0)
  modified_ts       INTEGER NOT NULL DEFAULT 0   -- Unix epoch seconds; see Provenance Columns (schema 11.3)
)
```

### Waypoint Types

`wp_type` is an INTEGER enum (schema 12.0). The 9 values, their constant names in
`apps/navMate/n_defs.pm`, and their default `sym` from `%WP_DEFAULT_SYMS` (the
seed mapping; the in-effect mapping lives in `key_values.wp_mapped_syms` and is
editable via Utils -> Waypoint Sym Mapping...):

| Int | Constant | Display name | Default sym | Sym name |
|---|---|---|---|---|
| 0 | `$WP_TYPE_NAV`       | `nav`       | 2  | SQUARE    |
| 1 | `$WP_TYPE_ROUTE_PT`  | `route_pt`  | 4  | DIAMOND   |
| 2 | `$WP_TYPE_SOUNDING`  | `sounding`  | 11 | CIRCLE_M   |
| 3 | `$WP_TYPE_LABEL`     | `label`     | 3  | TRIANGLE   |
| 4 | `$WP_TYPE_HAZARD`    | `hazard`    | 7  | SKULL      |
| 5 | `$WP_TYPE_SHIPWRECK` | `shipwreck` | 14 | SHIPWRECK  |
| 6 | `$WP_TYPE_FISH`      | `fish`      | 25 | FISH       |
| 7 | `$WP_TYPE_DIVING`    | `diving`    | 23 | BLUE_FLAG  |
| 8 | `$WP_TYPE_POI`       | `poi`       | 9  | TRIANGLE_I |

Display-string lookup uses `@WP_TYPE_NAMES` indexed by wp_type int.

`wp_type` is a navMate-only concept. E80 and FSH wire records have no equivalent
field; only the `sym` carries through to the spokes. At spoke->hub PASTE_NEW the
incoming sym reverse-maps to a wp_type via `wpTypeForSym` (the spoke contract
defines the full rule; see [Spoke Contract](navOps_spoke_contract.md)).

### Sym

`sym` (schema 12.0) is the E80 wire-protocol symbol index, 0..35, indexing into
`@E80_SYMS` in `NET/a_utils.pm` (formerly `@WPICON_TABLE`). The E80 firmware
accepts and renders sym indices up to 39, but its waypoint editor will not
present sym 36..39 for selection, so they cannot be set or edited round-trip on
the head unit; navMate caps at 0..35 to keep every stored sym editable on the
E80. The four extra constants (`$E80_SYM_MAN_OVERBOARD` etc., 36..39) remain
defined in `a_utils.pm` for posterity but are not exported and do not appear in
`@E80_SYMS`. navMate stores the index; the icon catalog lives in
`apps/navMate/sym_catalog/sym*.png` (16x16 cleanly-drawn icons, green sentinel
for transparent regions) for UI display.

The `wp_type -> sym` mapping is **not** hardcoded in navMate. It is JSON-encoded
in `key_values.wp_mapped_syms` and seeded at `openDB` from `%WP_DEFAULT_SYMS` if
the row is absent. The Conservative dialog (Utils -> Waypoint Sym Mapping...)
edits the mapping with a conservative DB sweep: changing a `wp_type`'s mapped sym
updates all waypoints that were `isMapped(wp_type, sym)` at the start of the edit;
off-map (hand-set) syms are preserved. The Force command (Utils -> Force Reset
Syms by Type...) overrides all hand-set syms for a single wp_type back to the
mapped default. The runtime helpers `loadSymMap` / `symForWpType` / `wpTypeForSym`
/ `isMapped` in `navDB.pm` are the canonical vocabulary.

`navDB::insertWaypoint` / `updateWaypoint` apply a write-boundary rule: if the
caller supplies `wp_type` but no `sym`, `sym` is filled from `symForWpType($wp_type)`.
Most callers therefore stop caring about `sym` for default-wp_type waypoints;
explicit `sym` still wins when passed.

### Other waypoint fields

Tilde (`~`) suffixes in `name` carry additional semantics for `label` waypoints
(see KML Import Rules below).

`depth_cm` is non-zero only for sounding waypoints. The name field holds the
original display string (the integer depth in feet); `depth_cm` holds the metric
conversion (feet x 30.48) for programmatic use.

`color` is the hex color resolved from the KML style at import time. For `nav`
waypoints the color encodes significance (green = anchorage, red = major hub,
yellow = notable, cyan = visited/secondary). For `sounding` waypoints color is
derived from depth (not stored separately). Stored `NOT NULL DEFAULT ''` (schema
13.0); `navDB::_normalizeColor` resolves `''`/unset to `'FFFFFFFF'` (white) at the
write boundary, so a stored color is always a valid 8-char hex string.

### routes

```sql
routes (
  uuid              TEXT PRIMARY KEY,
  name              TEXT    NOT NULL,
  comment           TEXT    NOT NULL DEFAULT '',
  color             TEXT    NOT NULL DEFAULT '',  -- aabbggrr hex; '' -> 'FFFFFFFF' (schema 13.0)
  collection_uuid   TEXT NOT NULL REFERENCES collections(uuid),
  db_version        INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0); see Version Columns
  e80_version       INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0)
  kml_version       INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0)
  position          REAL    NOT NULL DEFAULT 0,  -- display order within collection (schema 10.0)
  source            TEXT    NOT NULL DEFAULT '', -- see Provenance Columns (schema 11.3)
  created_ts        INTEGER NOT NULL DEFAULT 0,  -- see Provenance Columns (schema 11.3)
  modified_ts       INTEGER NOT NULL DEFAULT 0   -- see Provenance Columns (schema 11.3)
)

route_waypoints (
  route_uuid    TEXT NOT NULL REFERENCES routes(uuid),
  wp_uuid       TEXT NOT NULL REFERENCES waypoints(uuid),
  position      INTEGER NOT NULL,    -- 1-based sequence
  PRIMARY KEY (route_uuid, position)
)
```

Waypoints in routes are first-class objects in the `waypoints` table -
independently queryable and reusable across multiple routes. Route geometry
(the connecting LineString) is generated on demand; it is not stored.

### tracks

The `uuid` column is the identity UUID (equivalent to `mta_uuid` at the FSH/E80
boundary). `companion_uuid` is the paired TRK block UUID from the TRACKS protocol or
FSH file. `companion_uuid` in the DB and KML maps directly to `trk_uuid` at the
FSH/E80 boundary. Rows imported before schema 11.1 had `companion_uuid = NULL`,
normalized to `''` in schema 13.0.

```sql
tracks (
  uuid              TEXT PRIMARY KEY,    -- identity UUID (= mta_uuid at FSH/E80 boundary)
  name              TEXT    NOT NULL,
  comment           TEXT    NOT NULL DEFAULT '', -- editable in winDatabase track editor (schema 12.0)
  color             TEXT    NOT NULL DEFAULT '', -- aabbggrr hex; '' -> 'FFFFFFFF' (schema 13.0)
  ts_start          INTEGER NOT NULL DEFAULT 0,  -- derived summary; removal candidate (no consumers)
  ts_end            INTEGER NOT NULL DEFAULT 0,  -- derived summary; removal candidate (no consumers)
  ts_source         TEXT    NOT NULL DEFAULT '', -- see Timestamp Sources
  point_count       INTEGER NOT NULL DEFAULT 0,
  collection_uuid   TEXT NOT NULL REFERENCES collections(uuid),
  db_version        INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0); see Version Columns
  e80_version       INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0)
  kml_version       INTEGER NOT NULL DEFAULT 0,  -- inert reserved column (schema 13.0)
  position          REAL    NOT NULL DEFAULT 0,  -- display order within collection (schema 10.0)
  companion_uuid    TEXT    NOT NULL DEFAULT '', -- paired TRK block UUID (= trk_uuid at FSH/E80 boundary; schema 11.1)
  source            TEXT    NOT NULL DEFAULT '', -- see Provenance Columns (schema 11.3)
  created_ts        INTEGER NOT NULL DEFAULT 0,  -- see Provenance Columns (schema 11.3)
  modified_ts       INTEGER NOT NULL DEFAULT 0   -- see Provenance Columns (schema 11.3)
)

track_points (
  track_uuid    TEXT NOT NULL REFERENCES tracks(uuid),
  position      INTEGER NOT NULL,
  lat           REAL NOT NULL,
  lon           REAL NOT NULL,
  depth_cm      INTEGER NOT NULL DEFAULT 0,   -- 0 when sourced from KML (schema 13.0)
  temp_k        INTEGER NOT NULL DEFAULT 0,   -- 0 when sourced from KML (schema 13.0)
  ts            INTEGER NOT NULL DEFAULT 0,   -- 0 when sourced from KML (schema 13.0)
  PRIMARY KEY (track_uuid, position)
)
```

`depth_cm`, `temp_k`, and `ts` in `track_points` are `0` when absent (schema 13.0;
previously nullable). E80 TRACK protocol downloads carry this data; KML imports do
not -- and on the E80 the per-point time and depth are recorded only when
**timed-track recording** is enabled on the (custom-firmware) unit (see
[Timed Tracks](timed_tracks.md)); a stock track downloads with these `0`. `0` is the
canonical "no reading" sentinel -- consistent with `depth_cm` /
`temp_k` on `waypoints`, and safe because no real marine reading is `0` Kelvin and
these columns have no aggregate consumers that a `0` would skew. See the no-NULLs
invariant under [Design Decisions](#design-decisions).

### key_values

A general-purpose metadata table used to persist application-level values that
do not belong in the WRT or working set tables.

```sql
key_values (
  key    TEXT PRIMARY KEY,
  value  TEXT
)
```

Initial entries:

| key | Purpose |
|-----|---------|
| `schema_version` | Current value `'13.0'`; `openDB` in `navDB.pm` migrates known prior versions in place |
| `uuid_counter` | Integer; persistent counter for navMate UUID generation (bytes 4-5 of the UUID) |
| `fsh_uuid_counter` | Integer; persistent counter for FSH-flavored UUID generation (`newFSHUUID`) |
| `wp_mapped_syms` | JSON-encoded `{wp_type_int: sym_int}` mapping in effect (schema 12.0). Seeded from `%WP_DEFAULT_SYMS` at first `openDB`; editable via Utils -> Waypoint Sym Mapping... The Remapping dialog enforces uniqueness (each sym maps to at most one wp_type). Cached in memory as `%_mapped_syms` by `navDB::loadSymMap`, called from `openDB`. |

The `uuid_counter` entry is incremented atomically within the same transaction as
each new object INSERT, ensuring the counter and the database objects it identifies
never diverge.

## Provenance Columns

Every WGRT table (`waypoints`, `routes`, `tracks`, `collections`) carries the
same three provenance columns, added in schema 11.3:

| Column | Type | Meaning |
|---|---|---|
| `source` | TEXT | Originating subsystem for the row. Known values include `'onetimeImport'` (legacy KML rebuild), `'navMate'` (created interactively in winDatabase), and importer-specific strings such as `'import_gdb:<file>'` set by `gpsImport` and the Michelle reconciliation pass. The set is open-ended -- new importers may introduce new values. |
| `created_ts` | INTEGER | Unix epoch seconds at row creation. `NOT NULL DEFAULT 0`; the insert trigger backfills `0`. |
| `modified_ts` | INTEGER | Unix epoch seconds at last UPDATE. `NOT NULL DEFAULT 0` (schema 13.0); never persists as `0` -- the triggers always resolve it to a real timestamp. |

`created_ts` and `modified_ts` are auto-populated by SQLite triggers
(`<table>_insert_ts`, `<table>_update_ts`) installed by `_createTriggers` in
`navDB.pm`. The triggers are idempotent (`CREATE TRIGGER IF NOT EXISTS`) and
re-installed on every `openDB`, so both fresh databases and migrated databases
end up with the triggers active.

Trigger semantics (schema 13.0 uses `0` -- not NULL -- as the "fill me in" sentinel,
so every column can be `NOT NULL` and a naive raw / `insert_record` write still lands
correct data):

- **Insert trigger.** AFTER INSERT, `created_ts` and `modified_ts` are resolved with
  `CASE ... > 0`: an explicit positive value wins; a `0` (or omitted column, which
  defaults to `0`) is replaced with `strftime('%s','now')`. `modified_ts` falls back
  to `NEW.created_ts` before the current time, so an INSERT that sets `created_ts` but
  not `modified_ts` initializes both to the same value. The `collections` insert
  trigger additionally normalizes a `''` `node_type` to `'branch'`.
- **Update trigger.** AFTER UPDATE, `modified_ts` is touched to `strftime('%s','now')`
  when the UPDATE left it unchanged OR explicitly set it to `0`
  (`WHEN OLD.modified_ts IS NEW.modified_ts OR NEW.modified_ts = 0`). So a normal edit
  and a deliberate "pass 0 to refresh" both bump it, while an explicit positive
  `modified_ts` wins.
- **Recursion safety** relies on SQLite's default `PRAGMA recursive_triggers = OFF`
  so the trigger's own UPDATE does not re-fire the trigger.

The deeper semantics of `modified_ts` -- particularly when a transport-layer
sync should and should not bump it -- are still being worked out in the
navOperations layer; see [navOperations](navOperations.md).

## Text Backup

`ExportToText` and `ImportFromText` (available in the Database menu) provide a
plain-text backup of the full database - one INSERT per row across all tables.
This is a general-purpose backup utility, independent of any KML or E80 transport.
ImportFromText calls `resetDB()` before importing to ensure a clean schema.

## Design Decisions

**No NULLs in the database (schema 13.0).** Every column in every table is
`NOT NULL DEFAULT ''` (text) or `NOT NULL DEFAULT 0` (numeric). navMate follows the
"database-machinery" school: the engine owns the invariants via constraints,
`DEFAULT`s, and triggers, so even a sparse raw / `insert_record` write lands correct,
NULL-free data, and a stray NULL fails loud as a constraint violation rather than
silently corrupting a read. `''` is the canonical empty/root text value
(`parent_uuid=''` is a root-level collection); `0` is the canonical numeric "none"
sentinel (`temp_k`, `depth_cm`, the version columns) and the triggers' "fill me in"
signal for timestamps. Core inserts are deliberately raw SQL that *cooperates* with
the triggers and defaults -- `insert_record` is **not** used on the WGRT tables,
because its force-`0`/`''` on every column would bypass the `DEFAULT`s and defeat the
timestamp triggers' sentinel logic. See [Schema 13 Migration](#schema-13-migration).

**lat/lon as REAL degrees - no northing/easting in the schema.** The 1e7 integer
scaling used in WPMGR wire packets, and the Mercator northing/easting values used
alongside them, are translation artifacts. They are computed at wire-encode time
inside the transport layer and never appear in the schema.

**Timestamps are never NULL.** `created_ts` on waypoints and `ts_start` on tracks
are always populated. When no GPS or source timestamp is available, the import
timestamp is used. `ts_source` records which case applies.

**Track direction is a transport concern, not a schema concern.** Track upload
to the E80 is supported by the TRACK writer-session protocol
([NET/docs/notes/TRACK_writing.md](https://github.com/phorton1/base-Pub-Ray/blob/master/NET/docs/notes/TRACK_writing.md),
confirmed live 2026-05-27); the navOps wiring is pending. The schema stores
tracks without encoding assumptions about how they arrived.

**Route waypoints are first-class objects.** A waypoint that appears in a route
is stored once in `waypoints` and referenced by `route_waypoints.wp_uuid`. It is
not inlined as route geometry. The same waypoint can appear in multiple routes.

**The collection invariant.** Every waypoint, route, and track exists in exactly
one collection. `collection_uuid` is `NOT NULL` on all three WRT tables. Collections
are typed via `node_type`: `'branch'` for general organizer folders, `'group'` for
waypoint-only leaf collections that map to E80 WPMGR groups.

**`position` is a REAL (float) ordering key, not an integer sequence.** `collections`,
`waypoints`, `routes`, and `tracks` each carry a `position REAL NOT NULL DEFAULT 0`
column (schema 10.0). Using REAL allows new items to be inserted between any two existing
neighbors by taking the midpoint value - no surrounding rows need to be renumbered.
`route_waypoints.position` and `track_points.position` are separate INTEGER
primary-key components and are not part of the FLOAT scheme.

**Position invariants:**

- Position values are positive REALs. **0 is reserved as below-floor** and is
  not a legitimate stored position; any row at position=0 after the initial
  `Compact Positions` operation indicates a forgotten position assignment by
  some caller of the insert/move primitives.
- **Siblings within a container have distinct positions.** Container identity:
  `parent_uuid` for sub-collections, `collection_uuid` for waypoints, routes,
  and tracks.
- Positions may shrink below 1.0 via paste-before-first (MIN/2, MIN/4, ...)
  and grow without bound via append (MAX+1, MAX+2, ...). Both directions are
  symmetric and require no surrounding-row renumbering until the 31-bit
  subdivision precision ceiling is approached.

**Position computing rules** (implemented in `navDB.pm` helpers and consumed
by `navOpsDB.pm`, `navOps.pm`, `winDatabase.pm`, and importers):

| Operation | Rule |
|---|---|
| PASTE / PASTE_NEW on container, N items | Push-down stack at top: `pos_i = upper * (i+1) / (N+1)` where `upper = MIN(positions)` if non-empty else `N+1`. Devolves to 1..N for empty containers. |
| PASTE_BEFORE on anchor | Fractional between anchor and nearest-lower neighbor. No lower neighbor -> neighbor = 0. |
| PASTE_AFTER on anchor | Fractional between anchor and nearest-upper neighbor. No upper neighbor -> neighbor = anchor + 1. |
| NEW-X (new branch, new waypoint, ...) | Push-down stack of 1 item = MIN/2, or 1.0 if container is empty. |
| Move (cut+paste) | Same as the corresponding paste rule. |
| Import (ImportGPS, future importers) | Push-down stack of N items into destination. |

**Compaction.** The `Database -> Compact Positions` main-menu command renumbers
every container's children to 1.0, 2.0, 3.0, ... in current sorted order.
Used once to normalize legacy zero-positions on an older database, and
thereafter as the precision-wall reclamation tool when subdivisions approach
the 31-bit ceiling. Idempotent on an already-compacted DB.

The position allocator additionally renumbers a single container automatically
when its sibling per-slot gap falls below a precision threshold (`eps = 1e-9`
in `navDB.pm`). The automatic renumber preserves order, does not bump
`db_version` on the touched rows, and is indistinguishable from the
user-invoked Compact except for being triggered on the worst-case insertion
sites rather than the whole DB. Each automatic trigger emits a warning-color
log line `AutoCompact FLOAT positions for container <coll_uuid>` -- this is
the direct evidence the trigger fired, useful for audit and for tests.

**Renderer.** The `winDatabase` renderer (`_populateNode`) merges
sub-collections and direct objects (waypoints, routes, tracks) into a single
position-sorted list -- a container's children are ordered by `position`
across types. The `winE80` renderer continues to segregate by type
(Groups -> Routes -> Tracks), which is structural to the E80 and not a
positional choice. This asymmetry is what justifies placing the
waypoint-before-route dependency reorder in the DB->E80 push path
(`navOpsE80::_pushToE80`) rather than in the E80->DB paste path: an
E80-sourced clipboard arrives in dependency-correct order by construction,
but a DB-sourced clipboard may carry routes ahead of their referenced
waypoints because the DB tree permits arbitrary interleave.

**Version columns are inert reserved fields (schema 13.0).** `db_version`,
`e80_version`, and `kml_version` are present on `waypoints`, `routes`, and `tracks`
(not on `collections` or `route_waypoints`), all `INTEGER NOT NULL DEFAULT 0`. The
sync-versioning scheme they were intended for was **never built** -- nothing in the
code reads or compares them. In schema 13.0 the `db_version` auto-increment machinery
was removed (its only real side effect -- an mtime touch on route-membership edits --
is now an explicit `modified_ts` UPDATE), and all three are left at `0` as reserved
slots whose semantics can be defined, and prototyped against real columns, later
without a further schema change. A future design would compare a bumped `db_version`
against per-spoke `e80_version` / `kml_version` to detect what changed since the last
push; that comparison is the part that does not yet exist.

## Timestamp Sources

`ts_source` on `waypoints` and `tracks` records the provenance and reliability
of the *position-acquisition* timestamp (`waypoints.created_ts`,
`tracks.ts_start`). It is a domain field, distinct from the
[Provenance Columns](#provenance-columns) `created_ts` / `modified_ts` /
`source` that apply uniformly across all four WGRT tables. (`routes` and
`collections` have no `ts_source` -- they have no acquired-position timestamp
to characterize.)

| ts_source | Meaning |
|-----------|---------|
| `'e80'` | From E80 TRACK or WPMGR protocol - GPS-derived, most reliable |
| `'kml_timespan'` | From KML `gx:TimeSpan` - track-level span, accurate |
| `'phorton'` | Enriched from phorton.com `map_data/` index - see Data Migration |
| `'import'` | No temporal information available; value is the import timestamp |
| `'gdb'` | From a `.gpx` / `.gdb` import via `gpsImport` (per-point timestamps) |
| `'nav'` | Created interactively in winDatabase (`New Waypoint` etc.) |
| `'user'` | Set by navOpsDB on user-driven waypoint creation paths |

The list is open-ended; `n_defs.pm` exports the canonical four (`$TS_SOURCE_E80`,
`$TS_SOURCE_KML_TIMESPAN`, `$TS_SOURCE_PHORTON`, `$TS_SOURCE_IMPORT`) but
importers and editors are not constrained to it.

`ts_source = 'phorton'` is set once during the voyage log import pass and is
non-reversible - it records that the phorton.com enrichment has been applied.

GE-created objects (waypoints or tracks added interactively in Google Earth) carry
no timestamp in their KML export. These receive `ts_source = 'import'`.

## KML and GE

navMate uses KML as a bidirectional transport with Google Earth. The full KML
structure, round-trip semantics, and GE workflow are documented in
[KML Specification](kml_specification.md) and [GE Notes](ge_notes.md).

## Sync Model

navMate operates fully - browse, edit, organize - with no transport active. The local SQLite database is always sufficient for local work.
Transports are optional, user-activated concerns, not permanent connections
navMate depends on.

## Schema 12 Migration

`openDB` in `navDB.pm` carries the 11.3 -> 12.0 migration in place:

- `waypoints.wp_type`: TEXT -> INTEGER. Values mapped: `'nav'->0`, `'sounding'->2`,
  `'label'->3`, anything else -> 0.
- `waypoints.sym`: new INTEGER NOT NULL. Backfilled from the wp_type at migration
  time using `%WP_DEFAULT_SYMS` (the seed mapping).
- **Route-member classification**: any waypoint referenced in `route_waypoints`
  is reclassified to `$WP_TYPE_ROUTE_PT` (1) / `$E80_SYM_DIAMOND` (4) regardless
  of its prior string. Route membership wins over the prior wp_type.
- `tracks.comment`: new TEXT DEFAULT ''.
- `key_values.wp_mapped_syms`: seeded.

SQLite cannot `ALTER COLUMN TYPE`, so the migration rebuilds the `waypoints`
table (CREATE NEW + INSERT...SELECT + DROP OLD + RENAME) under one transaction.
Triggers are recreated on the renamed table by `_createTriggers` at the end of
`openDB`.

## Schema 13 Migration

`openDB` carries the 12.0 -> 13.0 migration (`_migrateTo13` in `navDB.pm`): the
no-NULLs hardening. Every column becomes `NOT NULL DEFAULT ''`/`0`. SQLite cannot add
a constraint to an existing column, so each of the five tables (`collections`,
`waypoints`, `routes`, `tracks`, `track_points`) is rebuilt -- drop the timestamp
triggers, rename the table aside, recreate it from `$db_def` via the **same**
`createTable()` a fresh install uses, copy the data with `COALESCE` normalizing every
prior NULL to its `''`/`0` canonical, drop the old table. Because both the
fresh-create path and the migration build from the one `$db_def`, a migrated database
and a freshly created one converge on byte-identical schemas. `_createTriggers` (with
the 0-sentinel bodies) reinstalls the triggers at the end of `openDB`.

Notable normalizations: `collections.parent_uuid` roots `NULL -> ''` (tree reads use
`parent_uuid=''`); `color NULL -> ''`; `temp_k` / `depth_cm` / `ts` / `ts_end`
`NULL -> 0`; the version columns `NULL -> 0`. 13.0 is a **major** schema bump, so the
cross-major guard in `openDB` refuses to open a 13.0 database under code that expects
an earlier major ("reimport required"), while a 12.x database migrates up in place.

## Data Migration

The initial database was populated from a Google Earth export by
`navOneTimeImport.pm`. That migration is complete, and the file is slated for
removal in a separate commit after Schema 12 has been verified end-to-end.
The Utils -> OneTimeImportKML menu entry has already been removed.

navMate is the primary UX for managing navigation data. The DB is canonical; KML
round-trip via Google Earth remains a practical secondary path (full wp_type and
sym round-trip via `nm_wp_type` and `nm_sym` ExtendedData -- see
[KML Specification](kml_specification.md)). `navKML.pm` handles all ongoing KML
import/export operations.

---

**Next:** [UI Model](ui_model.md)
