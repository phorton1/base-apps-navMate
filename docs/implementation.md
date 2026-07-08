# navMate - Implementation Reference

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**Implementation** --
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

navMate is built bottom-up: each layer is exercisable before the layers above it exist. The console window (inherited from the [shark](https://github.com/phorton1/base-apps-shark/blob/master/docs/shark.md) pattern) provides a callable interface to lower layers before any wx panel or Leaflet canvas is present. Modules use a four-tier lexical prefix convention: `n_` (foundational), `nav` (portable logic), `nm` (wx components), `win` (wx panes). No module may import from a higher layer.

navMate links the [NET](https://github.com/phorton1/base-Pub-Ray/blob/master/NET/docs/readme.md) library directly into its process - not as a daemon or socket service. The NET layer provides the RAYNET protocol stack, WPMGR and TRACK services, and the HTTP server base. See the NET documentation for that layer's own module structure.

## 1. Foundation layer (n_, nav - non-wx)

`n_defs.pm` and `n_utils.pm` form the no-dependency base. Nothing in this layer carries any wx dependency, so it is exercisable from a console-only process.

### 1.1 n_defs.pm

- Constants, type vocabulary, and the current schema version (`$SCHEMA_VERSION = '13.1'`).
- Exports the 9-entry `$WP_TYPE_*` int enum, `@WP_TYPE_NAMES` (display strings indexed by wp_type int), and `%WP_DEFAULT_SYMS` (the constant-defined seed mapping for `key_values.wp_mapped_syms`).

### 1.2 n_utils.pm

- UUID generation; establishes `$data_dir` / `$temp_dir`.
- Hosts the shared info-text helpers (`latLonLineText`, `northEastLineText`, `symText`, `wpTypeText`, `depthText`, `tempKText`, `tsText`, `trackPointsText`, `routePointsText`, `uuidRefText`) that all three window detail panels use for converged formatting.
- Exports `implementationError($msg)` for the navOps rule predicates and executor backstops: it checks `$nmDialogs::suppress_error_dialog` to route the message either to `warning(0, 0, "IMPLEMENTATION ERROR: $msg", 2)` (test mode -- log-only, suppressable) or `error("IMPLEMENTATION ERROR: $msg", 2)` (live UI -- visible dialog); `call_level=2` attributes the log line to the navOps caller, not the helper.

### 1.3 navDB.pm

- The SQLite layer: owns the schema DDL and all raw CRUD against navMate.db, the `promoteWaypointOnlyBranches` post-import pass, and an in-place migration runner in `openDB` that upgrades known prior schema versions to `$SCHEMA_VERSION`.
- Exposes the wp_type/sym mapping vocabulary used across the data layer and spoke contract: `loadSymMap` (called from `openDB` to populate the cache `%_mapped_syms`), `symForWpType($wt)`, `wpTypeForSym($sym)`, `isMapped($wt, $sym)`.
- Write-boundary rule (`insertWaypoint`/`updateWaypoint`): a caller supplying `wp_type` without `sym` gets `sym` filled from `symForWpType($wp_type)`.

### 1.4 Visibility / outline / selection state

- **`navVisibility.pm`** - in-memory per-source visibility state (DB / E80 / FSH) backing the Leaflet canvas.
- **`navOutline.pm`** - persists tree expansion state per source under `$temp_dir`.
- **`navSelection.pm`** - persists named selection sets for winDatabase.

### 1.5 navPrefs.pm

- Wraps `Pub::Prefs` and re-exports its full API (except `initPrefs`), adding navMate constants (`$DEPTH_DISPLAY_METERS`, `$DEPTH_DISPLAY_FEET`, `$PREF_DEPTH_DISPLAY`) and `init_prefs()`, which calls `Pub::Prefs::initPrefs` against `$data_dir/navMate.prefs` with `$DEPTH_DISPLAY_FEET` as the default.
- Callers `use navPrefs` and get the complete `Pub::Prefs` API; no caller needs `use Pub::Prefs` directly.

## 2. Data transport (nav - non-wx)

This group moves data between navMate's SQLite store and external systems with no wx dependency.

### 2.1 navKML.pm

- Bidirectional KML import/export with ExtendedData UUID round-trip; the ongoing mechanism for all KML/GE interchange.
- The waypoint round-trip also preserves `wp_type` and `sym` via `nm_wp_type` / `nm_sym` ExtendedData fields -- see [KML Specification](kml_specification.md).

### 2.2 navFSH.pm

- Owns the FSH archive in-memory model (`$navFSH::fsh_db`), the `loadFSH` / `saveFSH` round-trip via the FSH library, the dirty bit (`markDirty` / `clearDirty`) that drives the `*`-prefix on the winFSH root label, and the `convertToWorkingCopy` transform that splits multi-segment tracks.

### 2.3 navGPX.pm

- Imports `.gpx` (always) and `.gdb` (when `gpsbabel` is on PATH) into a target DB collection, and exports any node's subtree to `.gpx` (flattened into `wpt`/`rte`/`trk` -- the collection hierarchy is not carried).
- Round-trips navMate identity via a `<navmate:uuid>` extension plus a synthesized `<opencpn:guid>` (which survives an OpenCPN detour where an unknown extension would not), and consumes those tags on import to reuse existing waypoints and rejoin route references instead of duplicating.

### 2.4 navUpload.pm

- Upload of collections to the E80 via WPMGR.

### 2.5 navOneTimeImport.pm

- Performed the initial database population from a GE export; no longer wired into any menu, slated for removal in a separate commit after Schema 12 has been verified end-to-end.

## 3. Context operations (nav)

These modules implement the context menu feature spanning all three tree panels (winDatabase, winE80, winFSH).

### 3.1 navClipboard.pm - clipboard + rule predicates

- Owns the clipboard state, generates the context menu item sets for every panel (no window directly inspects node types for menu decisions), and exports three silent rule predicates -- `_pasteRuleAllows`, `_deleteRuleAllows`, `_newRuleAllows` -- the single source of truth for "is this operation structurally valid in the current context?"
- Each menu generator (`getPasteMenuItems`, `getDeleteMenuItems`, `getNewMenuItems`) is a thin wrapper over its `_get*MenuItemsRaw` counterpart, filtered through the matching predicate (silently omitting rejected candidates).
- The preflight in `navOps.pm` (`_doPaste`, `_doDelete`, `_doNew`) calls the same predicate first and routes a rejection's `emit_as` tag to either `error()` (user_error -- friendly dialog) or `implementationError()` (impl_error -- IMPL ERROR prefix, suppressable in test mode). Menu and preflight cannot disagree because they consult the same predicate; executor backstops in navOpsDB/E80/FSH remain as defense-in-depth but should never fire post-predicate.

### 3.2 navOps.pm - dispatch + wp_type/sym seams

- The dispatch layer; routes each command to `navOpsDB.pm` (database-side), `navOpsE80.pm` (E80-side), or `navOpsFSH.pm` (FSH-side) per the hub-and-spoke model where navMate is the canonical rich representation and the E80 / FSH transports are lossy projections.
- The wp_type/sym hub-spoke seams live here:
    - `_pushFromE80` (in navOpsDB) handles MODIFY-from-spoke with the `isMapped` predicate: the spoke pushes sym; if the DB row's pair was in sync with the mapping, a reverse-map via `wpTypeForSym` may shift `wp_type`; off-map rows keep `wp_type` and only update sym.
    - `_insertFreshWaypoint` / `_pasteOneWaypointToDB` handle PASTE_NEW reverse-mapping (incoming spoke sym -> derive wp_type via `wpTypeForSym`, fallback nav).
    - The DB->spoke push paths in `navOpsE80` and `navOpsFSH` read `$wp->{sym}` from the source row.
- See [Spoke Contract](navOps_spoke_contract.md) for the full data-layer rule set.

### 3.3 navMatch.pm / navMatchC.pm - the matching engine

The track / waypoint matching engine (bbox, segment-distance, DTW pipeline), consumed by `winFind` (5.8) for cross-source matching.

- `navMatch.pm` is the pure-Perl reference implementation of the scorer. `navMatchC.pm` is the Inline::C kernel that mirrors the same cascade end-to-end (bbox prefilter stays in PP; everything from exact pass through DTW through classification runs in C, single packed-SV* round-trip per pair).
- `navMatch::scoreLineStringPair` is a dispatcher gated by `$navMatch::COMPARE_MODE` -- `'pp'` for the reference path, `'c'` for production speed, `'both'` for shadow-running C alongside PP with field-by-field divergence checks (first divergence per Find op pops an `error()` modal, subsequent ones go to log).
- `winFind::_doRefresh` calls `navMatch::resetDivergence()` at the top and `navMatch::reportCompareTiming()` at the end of each Find so cumulative PP-vs-C wall-time prints once per operation when shadow mode is on. Production default is `'c'`; flipping back to `'pp'` or `'both'` requires no code change beyond the constant.
- The C kernel's compiled `.dll` and Inline cache metadata live under `apps/navMate/_Inline/lib/` and `apps/navMate/_Inline/config-*` and are committed to the repo so fresh checkouts skip the first-run compile.

### 3.4 navDialogs.pm

- Shared modal dialogs used across this layer.

### 3.5 navTest.pm

- The HTTP-driven test dispatcher: receives commands from the `/api/test` endpoint, walks the tree to set selection and right-click state, and calls `onContextMenuCommand` directly -- the same code path as a real user interaction.

## 4. HTTP server (navServer + navLeaflet)

`navServer.pm` extends `h_server.pm` from the NET library to provide navMate's embedded HTTP server on port 9883.

### 4.1 Core /api/ endpoints

- Ring buffer log, command dispatch, database queries (`/api/nmdb`), GeoJSON features for Leaflet, and test dispatch.

### 4.2 Map waypoint editor

- Adds `GET /api/dest` (the focused tree pane's create-destination, republished each idle), `POST /waypoint/save` (`op=create|update|delete`, queued for `nmFrame::onIdle`), and `GET /waypoint/result` (the seq-matched outcome the browser polls).
- The save is applied pane-free by `navLeaflet::dispatchWaypointSave` -- works whether or not the source window is open, refreshing the pane's tree afterwards only if it is.
- The create-destination is resolved by the `winTreeBase::resolveMapDestination` virtual; the client only offers **Create Waypoint** when that destination exists (open window + appropriate selection).

### 4.3 navLeaflet orchestration

- The per-store create/modify/delete plus the map render live in `navLeaflet.pm` (moved out of navOpsE80 / navOpsFSH and winDatabase so the navOps clipboard layer carries no Leaflet code).
- Reuses the WPMGR / FSH machinery and `navDB`, calling the navOps spoke primitives in place (`_checkE80NameConflict` / `_e80WPRoutes` / `_e80DeleteWP`, `_checkFSHNameConflict` / `_buildFSHWpRecord` / `_fshSetWpLatLon` / `_fshWPRoutes`, `_newNavUUID`).

### 4.4 Move Waypoint

- The Map gesture reuses `op=update`, adding `lat`/`lon`: a position change re-derives the spoke's denormalized Mercator `north`/`east` (E80 in `e_wp_api::modifyWaypoint`, FSH via `navOps::_fshSetWpLatLon`, shared by create / editor / move).
- The move returns the referencing route UUIDs so `navLeaflet::_repushSpokeRoutes` (DB: the in-line route re-push) re-pushes their polylines -- DB/E80 resolve route members live, FSH carries denormalized route-member copies that the move updates in place.

### 4.5 /poll and /clear

- `/poll` is a pure version-probe carrying both the render `version` and a `reveal` counter -- `reveal` advances only on deliberate Show-on-Map / Find pushes (not on startup/revert restores or in-place waypoint create/edit), so the client auto-zooms only on reveals.
- The server has no notion of browser connect (the client detects its own reconnects via fetch timeouts in `_res/site/map.js`); the `/clear` handler sets a flag consumed by `pollClearMapPending()` and polled from `nmFrame::onIdle`.
- The Leaflet applet HTML/JS in `_res/site/` is served by this module.

### 4.6 Render storage

- Keyed `"$source:$uuid"` so DB / E80 / FSH versions of the same UUID coexist; `addRenderFeatures` derives source from each feature's `data_source` property and `removeRenderFeatures` takes it explicitly.

### 4.7 Lazy sym icons

- `/sym/native/NN.png` returns the 16x16 RGBA source for E80 / FSH (native red/blue art, sentinel-green keyed to alpha=0); `/sym/mask/NN.png` returns a chroma/lift mask for the browser to tint per-WP for DB markers.
- Both are built on first request into `sym_catalog/cache/leaflet_native_NN.png` and `sym_catalog/cache/leaflet_mask_NN.png` by `nmResources::ensureLeafletNative` / `ensureLeafletMask` and are mtime-gated against the source `symNN.png`.

## 5. wx layer (nm, win)

### 5.1 navMate.pm + nmFrame.pm - process + frame

- `navMate.pm` is the wx process boundary - it initializes the wx application and runs the main loop.
- `nmFrame.pm` is the application frame: it owns the top-level menu dispatch, status bar, and `onIdle` heartbeat that drives WPMGR callbacks, tree refresh, and test dispatch.

### 5.2 nmResources.pm

- Defines shared wx resource constants (IDs, menu constants).
- Sym-icon helpers: `symBitmap($i)` (cached 20x20 picker bitmap built lazily into `sym_catalog/cache/20x20_NN.png` from the 16x16 `apps/navMate/sym_catalog/symNN.png` source) and `makeSymComboBox($parent, $pos, $size, $multi_label)` (returns a populated `Wx::BitmapComboBox` over the 40 entries of `@E80_SYMS`).
- Leaflet sym cache builders `ensureLeafletNative($i)` / `ensureLeafletMask($i)` produce 16x16 RGBA PNGs under `sym_catalog/cache/leaflet_*` for the navServer `/sym/native/` and `/sym/mask/` endpoints. The mask encodes chroma in R and lift in G (`R=max-min`, `G=min`) so the browser can apply `out = userColor * chroma/255 + lift` per channel; the same chroma/lift encoding is used by `winTreeColors::_swatchBitmapForColoredSym` for the in-app tree-row colored swatch.

### 5.3 winTreeBase.pm

- The shared base class for the three tree panels (winDatabase, winE80, winFSH). Owns the common editor-on-top + detail-on-bottom layout (the `_layoutEditor` packer), the per-source three-state visibility checkbox plumbing, the editor field-widget registry, the Leaflet feature builders (`_buildWpFeature` / `_buildRouteFeature` / `_buildTrackFeature`), and the abstract hooks each subclass implements (`_wpDataSource`, `_wpLatLon`, `_wpColor`, `_trackColorABGR`, etc.).
- The map waypoint editor adds the `resolveMapDestination` virtual (default "unsupported"; each pane overrides it to map its current tree selection to a create-destination); the create/edit/delete write + render itself lives pane-free in `navLeaflet.pm`, which mirrors these feature builders for the window-closed case (`_buildSpokeWpFeature` / `_buildSpokeRouteFeature`).
- `_buildWpFeature` carries `sym` and `data_source` to the Leaflet wire; `map.js` routes WP rendering by both -- E80/FSH WPs use the native sym art, DB WPs tint the chroma/lift mask to the WP's ABGR color in a canvas, `label` / `sounding` retain their text-based rendering.

### 5.4 winDatabase.pm

- `winDatabase.pm` (with continuation `winDatabase2.pm`) presents the navMate SQLite database as a lazily-loaded wx tree. Children load on first expand; the editor uses absolute positioning with named constants; the tree carries per-node visibility state images (unchecked/checked/indeterminate); multi-instance (each View -> Database opens an additional panel).
- `onClearMap` handles the Leaflet clear-map event dispatched from `nmFrame::onIdle`; `resyncDbToLeaflet` re-publishes the DB visibles after a DB swap (e.g. revert) and once at startup (the server render set is empty on a fresh start while the visible flags persist in `navMate.json`).

### 5.5 winE80 / winFSH / winMonitor

- **`winE80.pm`** - presents the live E80 device state as a tree rebuilt whenever the NET version counter increments.
- **`winFSH.pm`** - the FSH archive browser; single-instance, backed by `$navFSH::fsh_db`, in-memory edits flushed on FSH -> Save File.
- **`winMonitor.pm`** - the console/log monitor panel.

### 5.6 winMultiEditor.pm

- The modal multi-item editor used from winDatabase and winFSH right-click menus when 2+ eligible items are selected. Descriptor-driven: each caller supplies fetch/commit closures and capability flags (color mode = ABGR or palette-index, `has_wp_type`, `has_sym`, comment_max) so the dialog itself has no per-spoke knowledge. See [winMultiEditor](winMultiEditor.md) for the descriptor protocol.
- The DB descriptor implements a **per-item conservative forward-map** at commit time: when the user changed `wp_type` in the dialog and left `sym` clean, each item's snapshot pair is checked against `isMapped` -- mapped items get `sym` auto-updated to the new wp_type's default; off-map items keep their hand-set sym.

### 5.7 winRename.pm

- The modal batch-rename dialog used from winDatabase and winFSH right-click menus on a homogeneous waypoint / route / track / group selection (N>=1). Renders a pattern with embedded `{N}` token into serially-numbered new names. Spoke-local: bypasses navOps.
- FSH applies per-type name uniqueness preflight plus the 15-char ceiling; DB is deliberately unconstrained.

### 5.8 winFind.pm

- The cross-source track-finder context-menu surface. Given a subject track / waypoint / route from any of the three panels, it scans every available source (DB, E80 in-memory, all FSH archives on disk) via `navMatch` (3.3) and presents the candidates ranked by an exact + DTW scorer cascade with lat-shift detection and coverage / quality split metrics.

### 5.9 winSymMapping.pm

- Provides the two Utils-menu dialogs over `key_values.wp_mapped_syms`.
- `showSymMappingDialog` is the Conservative editor: 9-row mapping over `@WP_TYPE_NAMES`, sym Choices populated via `nmResources::makeSymComboBox`, Reset-to-Defaults button, save runs uniqueness validation + preflight count + single-transaction update of the row plus conservative `UPDATE waypoints SET sym=:new WHERE wp_type=:wt AND sym=:old` per changed row, then calls `loadSymMap` to refresh the cache.
- `showForceSymResetDialog` is the per-row Force command: 9-row read-only display of the current mapping with live hand-set counts and per-row [Force] buttons that disable when count is 0.
- The single-editor live forward-map indicator in `winDatabase` (cached `$this->{_mapped}` recomputed on every Choice change) uses the same vocabulary.

## 6. Standalone tools

### 6.1 _e80_dedup.pm

- A standalone script (`package main`) for oldE80 archaeology - waypoint dedup and track strand matching against reference tracks. Run directly from the command line; not imported by the running application.

---

**Next:** [navOperations](navOperations.md)
