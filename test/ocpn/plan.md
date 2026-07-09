# ocpn Module -- Plan

DB <-> OpenCPN (oESeries plugin) cross-panel operations: inbound inventory ingest + PASTE into the DB, outbound push/paste enqueuing `commands[]`, the two-sided identity (navMate-origin table-free vs foreign mint), the sym <-> icon fidelity boundary, and the ocpn-specific guards. navMate is the HTTP **server**; the plugin is the polling client. The test exercises the **real plugin under real OpenCPN** talking to navMate, end to end and automated.

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md). For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md). For execution, see [`runbook.md`](runbook.md). Durable as-built architecture: [`../../docs/opencpn.md`](../../docs/opencpn.md); the wire is owned in the oESeries repo `protocol.md`.

---

## The two servers

Two distinct HTTP servers, both with an `/api` -- always qualify which:

- **navMate** -- `http://localhost:9883`. `/api/ocpn` (the plugin POSTs its inventory here; `?dump=1` reads navMate's `ocdb`), `/api/test`, `/api/nmdb`, `/api/command`, `/api/log`. This is ours.
- **OpenCPN** -- `https://localhost:8443`. `/api/rx_object` (POST a GPX body to import objects into the running OpenCPN), `/api/get-version`, `/api/ping`. Source-verified in oe `peer_client.cpp` / `pincode.cpp`; self-signed TLS (`curl -k`).

## Module Scope

- Inbound: the plugin POSTs its COMPLETE inventory (protocol sec 12) to navMate `/api/ocpn`; navMate parses it into the `ocdb`, mirrors it in `winOCPN`, and a user PASTE / PASTE_NEW crosses into `navMate.db` via the same `_pasteDB` path every spoke uses.
- Outbound: PUSH from the DB pane and PASTE into the OCPN pane ENQUEUE a `commands[]` batch; the plugin polls navMate, applies them in OpenCPN, and POSTs `results[]`.
- Identity (protocol sec 4): navMate-origin GUIDs reverse table-free via the `navIdentity` codec (no `ocpn_guid_map` row); foreign GUIDs mint a `0x4f` uuid on first sight + persist a map row.
- Fidelity boundary (protocol sec 7): icon `->` sym on ingest, sym `->` icon on push; the `icon -> sym -> wp_type` chain on cross-spoke paste to E80/FSH; multi-line comment round-trip (LF on the wire) and newline `->` space at the E80/FSH boundary.
- ocpn-specific gate differences vs the device/file spokes: upsert-by-GUID (no collision gate, sec 9), unbounded strings (no truncation gate), manifestation XOR, foreign-GUID idempotency, outbound = queued commands.

OpenCPN is the first **peer** spoke: a poll-driven HTTP client, not an in-process model (FSH) or request/reply device (E80). Ingest never mutates `navMate.db` until a PASTE; outbound never pushes synchronously -- it enqueues, and the plugin applies on its own clock, so outbound and idempotency steps **wait-and-poll**, they do not assume synchronous completion.

## How the test is driven

The real oESeries plugin under real OpenCPN IS the test -- fully automated, not optional:

- **Seed OpenCPN.** POST `seed.gpx` to OpenCPN's `https://localhost:8443/api/rx_object` (`curl -k`), so the running OpenCPN holds the fixture objects. OpenCPN honors `opencpn:guid` on import, so the seed's exact GUIDs (navMate-MAGIC and foreign) are preserved.
- **Inbound.** The plugin, pointed at navMate, POSTs its inventory to navMate `/api/ocpn` on its poll clock. Assertions read navMate's `ocdb` via `/api/ocpn?dump=1`.
- **PASTE / push.** navOps operations driven via navMate `/api/test` (exactly like the db/e80/fsh modules); DB-side effects verified via `/api/nmdb`.
- **Outbound effect.** A push enqueues; the plugin polls navMate, applies in OpenCPN, POSTs `results[]`; observed via navMate `dumpState` and the plugin's next inventory.

**Everything is driven through the real plugin + `/api/test`.** There is no mock inventory and no JSON fixture; nothing is hand-POSTed to `/api/ocpn`. The guards (below) exercise navOps preflight rejections via `/api/test`, exactly like the positives -- they are not tests of the ingest endpoint.

## Fixture

`_fixtures/ocpn/seed.gpx` -- the single, git-tracked fixture (OpenCPN GPX). Pushed into OpenCPN via `/api/rx_object` at baseline. Covers the matrix: navMate-origin mark, foreign marks, the tricky IconNames, multi-line / long / non-ASCII (XML-entity) comments, a route with a shared vertex, a route-owned pure vertex, and a track. Every object is annotated in the file header. The inbound inventory navMate ingests is whatever the real plugin emits for this OpenCPN state -- not a checked-in artifact. Guard bodies are inline in the runbook.

The navMate side is the same parasitized `C:/dat/Rhapsody/navMate.db`, reverted to git baseline per module (master_plan Fixtures). navMate-origin ocpn objects reuse existing DB shapes: `[IsolatedWP1]` (uuid `9e4e10cc5e03093e`) is seeded into OpenCPN as `[OCPN_NM_MARK]`, GUID = the codec's synth of that uuid.

## Baseline

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. navMate: `op=refresh`, then `op=suppress&val=1`
3. navMate: `op=clear_ocpn` -- zero the `ocdb`, reconciliation guid-map, and pending command/results/dt (`navOCPN::resetState`; the `clear_e80` analog). Restart is the only reset without it.
4. Seed OpenCPN: back up `C:\ProgramData\opencpn\navobj.db` to a fixed path + write a marker; put an empty `navobj.db` in place; launch `C:\Program Files (x86)\OpenCPN\opencpn.exe` (oESeries plugin pointed at navMate); POST `seed.gpx` to `https://localhost:8443/api/rx_object?...&force=1`.
5. Wait for the plugin's first inventory POST to land (`/api/ocpn?dump=1` non-empty); `cmd=mark+ocpn+module+reset`.

Teardown: kill `opencpn.exe`; restore `navobj.db` from the backup; clear the marker. FAILSAFE "restore navObjs.db" works from any session (fixed backup path + marker).

After setup: `/api/nmdb` returns the git-baseline DB; `/api/ocpn?dump=1` returns the fixture inventory (marks + routes + tracks + the persistent guid map); `/api/db` (render set) is empty.

## Pre-flight rules invoked (selected)

- **Identity (sec 4)** -- navMate-origin GUID reverses table-free, reconciles to the existing DB uuid, NO mint; foreign GUID mints `0x4f` uuid + `ocpn_guid_map` row, idempotent on re-POST.
- **Mark vs vertex (sec 5)** -- the plugin classifies each point; a shared point reconciles by GUID to ONE nav uuid (the ~84-double-count fix), never duplicated.
- **Manifestation XOR (sec 8, OUTBOUND)** -- a navMate waypoint that is a route member manifests ONCE on push (standalone mark XOR route vertex), route-membership-structural.
- **`ocpn` fidelity boundary (sec 7)** -- `iconForSym` on push, `symForIcon` on ingest (many-to-one fold + configurable catch-all default sym); NO truncation gate (unbounded strings); the raw foreign `IconName` shadows via `spoke_shadow.data`.
- **`ocpn_to_db` chain** -- `icon -> sym -> wpTypeForSym -> wp_type`: an ingested foreign mark's wp_type is a function of BOTH editable maps composed (`sym_icons` + `wp_mapped_syms`).
- **`db_to_e80` / `db_to_fsh` lossy transform on cross-spoke paste** -- name/comment length truncation AND newline `->` single space (flatten-then-truncate); route/track color not in the E80/FSH palette.
- **Generation / dt gate (sec 3/13)** -- `navmate_dt` advances only on `enqueueCommands` (ingest never advances it: echo-no-remint); monotonic, single-minter, never rolls back; a reimport restarts it (the generation token).

---

## Test Inventory

Positives first (`ocpn.<N>`), guards second (`ocpn.G<N>`). Tests build state progressively; independence is at the module boundary only. Drive path is noted per group above; assertions read navMate `/api/ocpn?dump=1` and `/api/nmdb`.

### Positive Tests -- inbound (OpenCPN -> hub)

| Test    | What it verifies |
|---------|------------------|
| ocpn.1  | The plugin's inventory populates navMate's `ocdb`: fixture marks/routes/tracks present; counts exact; the shared point (`[OCPN_SHARED_PT]`, both a `<wpt>` and an `<rtept>`) reconciled to ONE uuid, NOT double-counted. |
| ocpn.2  | navMate-origin ingest: `[OCPN_NM_MARK]` GUID reverses table-free to `9e4e10cc5e03093e` ([IsolatedWP1]); no foreign mint-map row for it. |
| ocpn.3  | Foreign ingest: `[OCPN_HAZARD]` mints a `0x4f` uuid + one reconcile-map row; the ocdb carries the raw icon `Hazard-Danger` (the icon->sym fold, Hazard-Danger->7, is a DB-side property checked at PASTE/ocpn.5 -- the dump exposes the IconName, not the sym). |
| ocpn.4  | Idempotent re-ingest: on the plugin's next inventory POST (same OpenCPN state), same uuids, no duplicate map rows, `ocdb` REBUILT (full-state replace, sec 12), `navmate_dt` NOT advanced (echo-no-remint). |
| ocpn.5  | PASTE `[OCPN_HAZARD]` to DB: reuses the minted `0x4f` uuid; icon `Hazard-Danger` folds to sym 7 (`wp_type` 4); MULTI-LINE comment stored as canonical LF; `spoke_shadow.data` carries `icon_name=Hazard-Danger` + the full category-B superset (booleans intact). |
| ocpn.6a | Route embedded-waypoints range-copy: from the ocpn pane, multi-select the route's route-point nodes (`rp:<route>:<wp>` for each ordered child pulled from `/api/ocpn?dump=1`) -> COPY -> PASTE into the collection. Materializes every vertex as a DB waypoint at its `0x4f` uuid, INCLUDING the pure vertices (RteMid/RteEnd) not surfaced as standalone marks. |
| ocpn.6b | Route paste (members-first): COPY the `[OCPN_ROUTE]` node -> PASTE into the collection. The route references the now-existing member waypoints (from 6a); the shared start point `[OCPN_SHARED_PT]` is the SINGLE DB waypoint referenced by both the standalone mark and the route (one uuid), NOT re-created. |
| ocpn.7  | PASTE `[OCPN_TRACK]` to DB: track + points (exact lat/lon/ts, no depth); PRESERVES the foreign `0x4f` uuid + writes a `spoke_shadow` row so it round-trips like a mark. Colorless by design (protocol carries no track color/style). |
| ocpn.8  | PASTE_NEW a foreign mark to DB: fresh navMate `0x4e` uuid; original OpenCPN GUID NOT preserved and NO `spoke_shadow` row (identity-free fresh object). |
| ocpn.9  | Catch-all sym + R3: `[OCPN_CAFE]` (icon `Marks-Beacon-Red`, not in the 36-map) folds to the default sym (2); non-ASCII name + comment preserved codepoint-exact through ingest and PASTE. |
| ocpn.10 | Reverse fold + no-truncate: `[OCPN_DEEPREEF]` (icon `Info-Fish-Reef`) folds to sym 27; the >255-char comment stored UNTRUNCATED (ocpn has no length gate). |

### Positive Tests -- outbound (hub -> OpenCPN)

| Test    | What it verifies |
|---------|------------------|
| ocpn.11 | PUSH a DB mark ([IsolatedWP2]) to OCPN (via `/api/test`): enqueues an `add` command; `navmate_dt` advances; the plugin applies it; the command `guid` is the synthesized navMate GUID (reversible). Verified via `dumpState` + the plugin's next inventory. |
| ocpn.12 | PUSH a DB route ([TestRoute]) to OCPN: one full-embed route command (route + per-vertex, sec 8); member WP GUIDs are the synthesized navMate GUIDs. |
| ocpn.13 | Manifestation XOR: a DB waypoint that is a route member manifests ONCE on push; the guid-map + dt keep it idempotent (no phantom mark echo). |
| ocpn.14 | Echo-no-remint: an unchanged re-ingest (ocpn.4) queues ZERO commands (ingest never mints). |
| ocpn.15 | Results ack: the plugin POSTs `results[]`; navMate resolves the pending batch; re-drives on `ok:false` (idempotent: add-existing = update, delete-absent = ok). |

### Positive Tests -- cross-spoke (the chain)

| Test    | What it verifies |
|---------|------------------|
| ocpn.16 | `[OCPN_HAZARD]` -> DB -> E80 (via `/api/test`): the `icon -> sym -> wp_type` chain lands sensibly (sym 7); the multi-line comment is FLATTENED to a single line (newline -> space) and truncated at `$E80_MAX_COMMENT`. |
| ocpn.17 | `[OCPN_HAZARD]` -> DB -> FSH: same chain, FSH boundary (`$FSH_MAX_COMMENT`, flatten-then-truncate). |
| ocpn.18 | Round-trip drift: push a fish-variant DB mark to OCPN, let it re-ingest, confirm the sym round-trips or folds to the documented representative -- captures the known wonky-reverse behavior, not a silent surprise. |

### Positive Tests -- extended-data round-trip (option-b + identity)

| Test    | What it verifies |
|---------|------------------|
| ocpn.19 | navMate-origin B round-trip (option-b): give a navMate-origin mark an OpenCPN B-superset edit (set e.g. a range-ring / scamin in OpenCPN, or seed it), then PUSH-to-DB (`CTX_CMD_PUSH` from the ocpn pane -- PASTE is gated at the same uuid, so PUSH is the sync verb) into its EXISTING DB record. Assert a `spoke_shadow` row now exists keyed by its `nav_uuid` (native_id = its synthesized GUID) carrying the B-superset; then PUSH the DB mark back to OCPN and confirm the B-superset is RESTORED from the shadow. Identity stays table-free -- the row is extended-data, not identity. |
| ocpn.20 | Foreign track round-trip: the `[OCPN_TRACK]` pasted in ocpn.7 (`0x4f` + shadow) is PUSHed back to OCPN and re-emits its ORIGINAL OpenCPN GUID (from the shadow), not a fresh navMate-minted one. |

### Guard Tests

Guards are the navOps **context-menu preflight REJECTIONS**, driven via `/api/test` (the same panel/select/cmd context-menu-in-lieu mechanism the positives use), NOT crafted POSTs to `/api/ocpn`. They mirror the db/e80/fsh guard pattern -- menu-shape, content-vs-destination (D6), and the collision gate -- adapted to the OpenCPN tree (no groups; My Waypoints + Routes/Tracks headers) and its lossless outbound path. Each asserts the rejection message fired AND nothing was enqueued (`navmate_dt` unchanged) / no DB row changed. The `db_cut_to_spoke` / `ocpn_invalid_paste_dest` / `spoke_*` / `route_point_at_non_route` tokens are the `_pasteRuleAllows` predicates (`navClipboard.pm`); the collision gate is the shared spoke->DB uuid preflight (`navOps.pm`). Rejections emit `error()` (user_error) or `implementationError()` (impl_error, a `WARNING: IMPLEMENTATION ERROR` sentinel under `suppress=1`).

Because OpenCPN has no groups, the group-shaped fsh guards (group-at-my_waypoints, group-at-named-group) have no analog; Route/Track stand in for the content-vs-destination cases. Because OpenCPN outbound is lossless (no truncation/palette gate), there is no name-collision-on-push or post-truncation-collision guard either.

| Test    | What it verifies | parallels |
|---------|------------------|-----------|
| ocpn.G1 | DB-Cut to an OpenCPN destination blocked: CUT a DB waypoint, PASTE at ocpn My Waypoints -> `Cannot paste a database Cut to OpenCPN` (user_error); nothing enqueued. | fsh.G2/e80.G2 |
| ocpn.G2 | Menu-shape: PASTE at an OpenCPN mark (`waypoint`) object node blocked -> `paste at OpenCPN destination type 'waypoint' not supported` (impl_error, API bypass). | fsh.G5 |
| ocpn.G3 | Menu-shape: PASTE_NEW at an OpenCPN mark object node blocked (same `ocpn_invalid_paste_dest` gate). | fsh.G6 |
| ocpn.G4 | D6 content-vs-destination: a WP clipboard item at the OpenCPN Routes header blocked -> `Cannot paste waypoint clipboard item at ocpn 'header:routes' destination`. | fsh.G7 |
| ocpn.G5 | D6 content-vs-destination: a Route clipboard item at OpenCPN My Waypoints blocked -> `Cannot paste route clipboard item at ocpn 'my_waypoints' destination`. | fsh.G8 |
| ocpn.G6 | D6 content-vs-destination: a Track clipboard item at the OpenCPN Routes header blocked -> `Cannot paste track clipboard item at ocpn 'header:routes' destination`. | fsh.G9 |
| ocpn.G7 | A route_point clipboard item at OpenCPN My Waypoints blocked -> `route_point items can only be pasted at a route, route_point, or database collection destination` (D2/D6). | -- |
| ocpn.G8 | Same-uuid PASTE collision, OpenCPN->DB: COPY the navMate-origin ocpn mark `[OCPN_NM_MARK]` (`9e4e10cc5e03093e`, already in the DB) and PASTE into a DB collection -> refused, no dup, no new uuid; the error directs to PUSH (sync into the existing record) or PASTE_NEW. | db collision gate |

> **Guard concept (do not regress):** the `<module>.G<N>` guards test the navOps **preflights the context menu would hit**, via `/api/test`, because real right-click/menu interaction is hard to orchestrate over the API. They are NOT tests of the `/api/ocpn` ingest endpoint. Feeding malformed/`dt`-less/non-array bodies to `/api/ocpn` tests what a *non-conformant plugin* might send -- but the protocol defines that interface, so such tests prove nothing about navMate and were removed (see git history for the earlier misdirected G1-G7).

## Intra-module sequencing

- ocpn.1-4 establish the ingested `ocdb` from the plugin's POST. 5-10 PASTE ingested items into the DB and probe fidelity.
- 11-15 exercise outbound from the reverted DB; they run AFTER inbound so the guid-map is populated for the round-trip identity checks.
- 16-18 are cross-spoke (consume E80/FSH destinations). 19-20 are the extended-data / identity round-trips (19 needs a navMate-origin object living in OpenCPN; 20 consumes the ocpn.7 track).
- Guards run at the end and are all driven via `/api/test` like the positives: set the clipboard (COPY/CUT the appropriate source), fire the paste/paste_new at the wrong ocpn destination node, and assert the rejection message + no enqueue / no DB row change. They need the ocpn pane populated (a mark, a route with points, a track) and the DB baseline; no live E80/FSH required.

## Notes

- **Real test, not a fake.** Functional coverage is the real plugin end to end; navOps operations (positives and guards alike) are driven via `/api/test`. There is no mock driver, no inventory JSON fixture, and no hand-crafted POST to `/api/ocpn`.
- **OpenCPN REST pincode.** `/api/rx_object` needs `source` + `apikey`; `apikey = substr(sha256_hex(sprintf("%04d", pin)), 0, 12)`, paired once from the PIN OpenCPN shows on first contact (a setup precondition). `force=1` bypasses the receive confirm; self-signed TLS -> `curl -k`. Contract per `_experiments/opencpn_rest.pm` (source-verified vs oe).
- **Async poll.** Outbound and idempotency steps wait-and-poll for the plugin's next cycle; that is a timing consideration, never a reason to emulate the plugin.
- **Shared point (bench first-run verify).** Confirm `seed.gpx`'s `<wpt>` + `<rtept>` sharing one GUID actually imports as a SHARED point in OpenCPN (vs two objects). If not, seed it by pushing from navMate through the plugin.
- **Wire encoding (R3).** navMate `/api/ocpn` encodes ASCII `\uXXXX` via `JSON::PP`; R3 is codepoint-equality. `[OCPN_CAFE]` (incl. the astral U+1F6A2) is the probe.
- **Deferred:** a navMate-origin ROUTE fixture (route + member GUIDs all synthesized) to test reconcile-into-existing-route; not required for v1 (ocpn.G8 + ocpn.19 cover the navMate-origin mark path -- collision gate + B round-trip).
