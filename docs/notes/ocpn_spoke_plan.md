# OCPN Spoke - Design & Implementation Plan

Status: DRAFT (2026-07-04) -- for Patrick to gate/revise
Grounded in a 5-pass code audit (navOps spoke template, DB schema, winOCPN/wire, test plan,
protocol [hub-review] confirmation). File:line anchors throughout.

## What this is

navMate's OpenCPN spoke connects the canonical `navMate.db` to the OpenCPN "oESeries"
plugin. The `ocdb` (navOCPN's in-memory inventory) <-> `navMate.db` boundary is the SAME
hub-spoke boundary as winE80/navFSH: a live, lossy projection where **only a user PASTE
crosses into the canonical DB**. What differs from the device/file spokes is the transport --
navOCPN is a remote, poll-driven HTTP peer, navMate the server and the plugin the client.
This plan owns the hub half only; the wire format and the plugin are owned in the oESeries
repo (`C:\src\OpenCPN\oESeries\docs\protocol.md`).

One asymmetry organizes everything below:

- **Inbound (OpenCPN -> hub)** reuses machinery that already exists -- parse the POSTed
  inventory into a structured model, mirror it in a `winOCPN` tree, PASTE into `navMate.db`
  through the identical `_pasteDB` path every spoke uses. No new persistence code.
- **Outbound (hub -> OpenCPN)** is the one genuinely new subsystem -- navMate is the server
  and cannot push synchronously, so a paste *into* the OCPN spoke must enqueue a `commands[]`
  batch the polling plugin fetches later, gated on a `db_version` generation counter.

So **inbound is Phase 1, outbound is Phase 2**, and the hardest conceptual problem -- the
mark-vs-route-vertex manifestation decision -- is an *outbound* problem that does not block
Phase 1. The audit also found the schema changes are all additive (one minor bump, no
reimport), the identity/provenance scheme is 2/3 already built, and `winOCPN` is cheap
(`winTreeBase` carries it). Steps 1-2 (schema, identity) are foundation and precede Phase 1.

**Surrounding decisions (2026-07-04):** v1 = inbound-first -- APPROVED. Protocol verified and
revised (the `[hub-review]` tags are resolved in `protocol.md`; that work is complete and is
not part of this plan). This doc placed in `docs/notes/`. The manifestation policy is deferred
to Step 6; the minor choices (identity codec home, sym<->icon table form) are left to the
implementer.

The steps below are in build order; dependencies are noted where they bind.

---

## Step 1 -- Schema changes (one additive migration `13.0 -> 13.1`)

All four changes bundle into a single minor bump. Additive only (new tables, new key_values
rows, one `ALTER ADD COLUMN ... DEFAULT ''`), so the major-version reimport gate
(`navDB.pm:463`) is NOT tripped; existing DBs migrate in place.

Files: `navDB.pm` (`$db_def` 105-199, `openDB`/migrations 222-481, triggers 605-664,
`_initKeyValues` 786-800, `_createTables` 590-602); version `n_defs.pm:78`; uuid mint
`n_utils.pm:88-111`.

### 1a. Finish the provenance scheme (`0x4f` + OCPN counter)
- Add `makeOCPNUUID` in `n_utils.pm` (byte 1 = `0x4f`), and `newOCPNUUID` +
  `ocpn_uuid_counter` key_values row, mirroring `makeFSHUUID`/`newFSHUUID`.

### 1b. `ocpn_guid_map` (foreign-GUID persistence, protocol sec 4)
```
ocpn_guid_map => [
    "ocpn_guid  TEXT PRIMARY KEY",           # 128-bit OpenCPN GUID verbatim
    "nav_uuid   TEXT NOT NULL",              # the 0x4f-tagged uuid we minted
    "first_seen INTEGER NOT NULL DEFAULT 0", # 0-sentinel; bind real value on raw insert
]
# + INDEX on nav_uuid for reverse lookup
```
Only FOREIGN (OpenCPN-born) GUIDs need this row; navMate-origin GUIDs reverse table-free via
the synthesized-GUID codec. Write `first_seen` with a **raw insert** (`INSERT OR IGNORE`),
never `insert_record` (which force-0s it). Idempotent by PK.

### 1c. `db_version` generation counter (protocol sec 3/13)
- New key_values row `key='db_version'` seeded `'0'`.
- Six triggers: `AFTER INSERT/UPDATE/DELETE` on each WGRT table (waypoints, routes, tracks;
  collections optional), each doing
  `UPDATE key_values SET value = value + 1 WHERE key='db_version';`.
- **Load-bearing invariant:** safe only under `PRAGMA recursive_triggers = OFF` (already
  assumed by the existing ts-triggers, navDB.pm:456). The counter writes only to key_values ->
  no recursion; the existing `_insert_ts` inner `UPDATE <wgrt>` does not re-fire the counter
  under OFF. Do not enable recursive_triggers or both fire twice.
- Distinct from the existing per-row `db_version` COLUMNS (a per-object stamp, not a global
  counter) -- do not conflate.
- `navOCPN::navmate_dt` reads this row instead of hardcoded 0. A reimport that recreates the
  DB restarts it -> the "hub lost state" signal (protocol sec 13 generation token).
- DEPENDENCY: only needed for OUTBOUND (Phase 2, Step 7), but created now in the one 13.1
  migration to avoid a second schema touch.

### 1d. Raw `icon_name` shadow (protocol sec 6/7)
- `ALTER TABLE waypoints ADD COLUMN icon_name TEXT NOT NULL DEFAULT ''` (also add to
  `$db_def`). `'' = use sym-derived icon`; non-'' preserves a foreign OpenCPN IconName that
  has no `sym`. Keyed by uuid (which maps to GUID), so no separate shadow table. All other
  ExtendedData already columns.

### 1e. `sym <-> icon` 36-entry table (protocol sec 7)
- SUPERSEDED (2026-07-08): NOT stored in the DB. The map lives in code
  (`@SYM_DEFAULT_ICONS`, n_defs); a user edit persists the WHOLE map to a `$data_dir`
  JSON file (`sym_icons.json`), reset deletes it, an absent file = code defaults. Same
  for its sibling `wp_mapped_syms.json`. The earlier key_values-row form self-seeded on
  every openDB and shipped a stale row in `example.db` -- see the `ocpn_sym_icon_map`
  memory. `navDB` has save/reset/load-file helpers; `winOCPNSymMap`/`winSymMapping` write
  the file instead of `UPDATE key_values`.
- Reverse `icon->sym` with a catch-all default sym for unrecognized names.

### Migration mechanics
- Add a `13.0 -> 13.1` block in `openDB`: `CREATE TABLE IF NOT EXISTS ocpn_guid_map` (+
  index), `ALTER TABLE waypoints ADD COLUMN icon_name`, create the six `*_bump_ver` triggers
  (idempotent via `_createTriggers`), seed `db_version`/`ocpn_uuid_counter`/`sym_icons` in
  `_initKeyValues`. Bump `$SCHEMA_VERSION='13.1'` (n_defs.pm:78).

---

## Step 2 -- Identity layer

- **Promote** `navUuidToOcpnGuid`/`ocpnGuidToNavUuid` out of `navGPX.pm:40-85` into a shared
  home (either `n_utils.pm` beside the mint fns, or a small `navIdentity.pm`). The MAGIC
  (`'6e61764d617465'` = "navMate"), version/variant nibbles, and byte layout are reusable
  as-is.
- Dispatch on provenance: a GUID whose reversed uuid carries the navMate MAGIC -> table-free
  reverse; otherwise it is foreign -> `ocpn_guid_map` (mint a `0x4f` uuid on first sight,
  `INSERT OR IGNORE`). This is exactly protocol sec 4.

---

## Step 3 -- navOCPN buildout (v0 stash -> structured spoke)

Today (`navOCPN.pm`) `receiveInventory` keeps only `$last_payload` text. It must become a real
spoke model:

- **Parse** the POST body into `{waypoints|marks}/{routes}/{tracks}` hashes keyed by nav-form
  uuid (via the identity codec, Step 2), reusing the FSH/E80 record shapes so the winTreeBase
  accessors and navOps snapshot work unchanged.
- Apply the mark-vs-route-vertex split the plugin already sends (protocol sec 5: `GetFSStatus`
  true=mark, false=pure vertex). Shared points reconcile to ONE nav uuid by GUID -- no
  duplication (this is what removed the ~84 double-counts on the plugin side).
- Foreign marks -> mint `0x4f` uuid + `ocpn_guid_map` row; shadow raw `icon_name`/ExtendedData
  by uuid.
- **Refresh signal:** add a `:shared` version counter bumped in `receiveInventory`; nothing
  else changes on the server thread.
- Accessors for the pane: `getWaypoints()/getRoutes()/getTracks()` + the identity converters.

---

## Step 4 -- winOCPN pane (cheap -- winTreeBase carries it)

- `package winOCPN; use base 'winTreeBase';` -- mirror `winFSH.pm`. Build the tree + right
  editor panel exactly as winE80.pm:74-268; call `installVisibilityObserver()`.
- Implement the ~16 abstracts (winE80.pm:1166-1297): `_wpDataSource`->'ocpn',
  `_allWaypoints/_allRoutes/_allTracks` -> navOCPN accessors, `_wpLatLon`, `_wpColor`,
  `_routeWpts`, `_trackColorABGR`, `_myWaypoints`, `_groupMemberWpts`, `_groupHasComment`, and
  the 5 visibility hooks.
- `refresh()` copies winE80's capture-expand/select/scroll + `_buildAndRestore`.
- **navVisibility.pm**: add an `'ocpn'` visibility store (only E80/FSH/DB exist).
- Resource wiring (nmResources.pm): `$WIN_OCPN=10016`, `$pane_data` + `$command_data`
  entries, add to `$view_menu`; `nmFrame.pm:296` createPane branch + findPane refresh hooks.
- **Refresh clock:** in `nmFrame::onIdle` (parallel to the b_sock::getVersion block,
  nmFrame.pm:206-283), poll navOCPN's `:shared` counter and call `$ocpn->refresh()` on change.

---

## Step 5 -- navOps / navClipboard integration (`'ocpn'` as a spoke)

The seam contract a spoke must satisfy (from the template audit). New file **`navOpsOCPN.pm`**
mirrors `navOpsFSH.pm`:

- Snapshot: add `navOps::_snapshotOCPNNode` + `_ocpnWpClipData` (canonicalize scale + uuid),
  and an `'ocpn'` branch in `_snapshotNodes` (navOps.pm:385).
- Predicates (navClipboard.pm): `_ocpnNodesAllInDB`, `_ocpnNodesAllInE80/FSH`, reverse
  `_dbNodesAllInOCPN`, `_e80/_fshNodesAllInOCPN`; wire into `getPushMenuItems` behind a
  `$peers->{ocpn}` gate (navOps.pm:117); any ocpn-specific rejects in `_pasteRuleAllows`.
- Executors: `_pasteOCPN` + `_pasteAllToOCPN`/`_pasteNewAllToOCPN`/`_pasteBeforeAfterOCPN`,
  per-type `_paste{Waypoint,Group,Route,Track}ToOCPN` (+ `_pasteNew*`), `_pushToOCPN`,
  `_cutOCPN*`, `_deleteOCPN*`, `_newOCPN*`.
- DEPENDENCY / phase split: the INBOUND direction (snapshot OCPN node -> clipboard -> PASTE
  into DB) reuses `_pasteDB` unchanged and works in Phase 1; the OUTBOUND executors
  (`_paste*ToOCPN`, `_pushToOCPN`) enqueue commands (Step 7) and are Phase 2.
- `n_defs.pm`: `$CTX_CMD_PUSH_OCPN` if OCPN is a push target (Phase 2).
- Ref-vs-record and paste/push/paste_new legality are handled generically by the existing
  `_classifyAgainstDB` + `_pasteRuleAllows`; the `'ocpn'` source string just needs the
  predicates above.

---

## Step 6 -- The manifestation seam (mostly Phase 2)

- **Inbound needs no policy.** The plugin already classifies mark vs pure vertex (protocol
  sec 5). A mark -> waypoint record; a route -> route record + `route_waypoints` refs whose
  members are materialized waypoints (navMate, like the E80, has no anonymous vertices).
  Shared points reconcile by identity to one uuid. Placement of foreign-origin marks = a
  default collection; the user re-files in the hub (protocol sec 6). This is the established
  navOps route-paste behavior -- nothing new.
- **Outbound needs the XOR policy (Phase 2).** Because OpenCPN cannot reference-share
  (`AddPlugInRoute` copies per vertex, protocol sec 8), a navMate waypoint that is a route
  member must manifest ONCE: standalone mark XOR route vertex. **Candidate navMate-native
  policy** (to decide at Phase 2, not now): derive it from `wp_type` -- a point typed
  `ROUTE_PT` manifests as a route-owned vertex; any other route member also manifests as a
  standalone mark. (Caveat: memory `navops_ref_vs_record` notes `wp_type==ROUTE_PT` is a
  display/symbol type, not a structural one -- so this is a heuristic, not a guarantee;
  revisit against real data.) The `ocpn_guid_map` + generation counter make the round-trip
  idempotent so a materialized vertex does not echo back as a phantom mark.

---

## Step 7 -- Sync engine

- **Inbound:** POST -> parse -> mirror -> (user) PASTE -> `_pasteDB`. Steady state is the
  two-DT gate: `ocpn_dt` echoes the client's last-inventory dt; a heartbeat GET with matching
  dts = no work.
- **Outbound (Phase 2):** on a paste INTO the ocpn spoke, bump `db_version` (trigger-driven)
  -> `navmate_dt` advances -> next GET returns a non-empty `commands[]` batch
  `{op,type,guid,fields}`; plugin applies (merge-on-apply, main thread) and POSTs `results[]`;
  hub resolves the pending batch, re-drives on `ok:false` (idempotent: add-existing=update,
  delete-absent=ok). Generation token `{generation,dt}` guards a hub restart.

---

## Step 8 -- Test module (`ocpn`)

Harness is documentation-as-harness (curl + explicit pass/fail), today 100% GET-driven.
`ocpn` is the first module whose driver must POST.

- **Test peer -- decided:** a **mock HTTP driver** (a `Post-Ocpn` PowerShell helper POSTing
  crafted JSON to `/api/ocpn`, reading back `?dump=1`) is the recurring-cycle backbone --
  deterministic (test owns `dt` + inventory), headless, repeatable. The **real oESeries
  plugin** is an out-of-cycle appendix (the `reflash` precedent): faithful end-to-end but
  polls on its own `wxTimer` clock, which breaks the mark/since-mark timing model.
- **Files:** `test/ocpn/plan.md` + `test/ocpn/runbook.md` (mirror the synchronous `fsh`
  module), `test/_fixtures/ocpn_inventory_v1.json`, uuid_index additions (`[OCPN_MARK1]`
  navMate-origin, `[OCPN_FOREIGN_MARK1]` 0x4f, `[OCPN_ROUTE1]`, `[OCPN_TRACK1]`), and a Step-6
  slot in `full_cycle_runbook.md` (`db->e80->tracks->fsh->ocpn->hub`).
- **Runnable v0 now:** ocpn.1-5 (cold poll, POST echo, dt advance, heartbeat steady-state,
  dump fidelity) + guards G1-G3 (bad JSON, missing dt, non-array).
- **Written NOT_RUN until buildout:** ocpn.10-16 (structured marks/routes/tracks parse,
  foreign-GUID map mint + idempotent re-POST, navMate-origin table-free reverse,
  paste->commands, results ack, shared-point-once) + G4-G5.
- **Safety assertions (the additive/never-destructive rail):** (1) POST never mutates
  `navMate.db` (in-memory until PASTE); (2) re-POST idempotent, no duplicate map rows/records;
  (3) delete-absent = ok, no cascade; (4) foreign GUIDs reverse ONLY via the persisted map --
  never guessed by name+lat+lon (unlike OpenCPN's GPX-file dedup); (5) a gate-rejected paste
  queues ZERO commands; (6) DT gate monotonic, single-minter, never rolls back.
- **Gap to build:** an `op=clear_ocpn` (or `/api/ocpn?reset=1`) reset primitive -- the ocpn
  analog of `clear_e80`/`load_fsh` -- so the baseline can zero spoke state between runs (today
  only a restart resets it).

---

## Appendix -- file inventory

**New files:** `navOpsOCPN.pm`, `winOCPN.pm`, `test/ocpn/plan.md`, `test/ocpn/runbook.md`,
`test/_fixtures/ocpn_inventory_v1.json`; optional `navIdentity.pm`.

**Extend:** `navOCPN.pm` (structured model + accessors + `:shared` counter), `navDB.pm` (13.1
migration + DDL + triggers), `n_utils.pm` (`makeOCPNUUID`/`0x4f`), `n_defs.pm`
(`$SCHEMA_VERSION`, `$CTX_CMD_PUSH_OCPN`), `navGPX.pm` (export the codec if promoted from
here), `navVisibility.pm` (`'ocpn'` store), `navOps.pm` (snapshot + panel branches + peers),
`navClipboard.pm` (predicates + getPushMenuItems), `nmResources.pm` (`$WIN_OCPN` + pane/command
data + view menu), `nmFrame.pm` (createPane + onIdle refresh clock), `navServer.pm` (feed the
model + `commands[]` on GET + reset), `test/uuid_index.md`, `test/full_cycle_runbook.md`,
`test/master_plan.md`.

---

## Alpha results (2026-07-05) -- wire proven end-to-end, Mode-2 on real OpenCPN

The hub half was BUILT and the initial full alpha run PASS against oe-claude's live oESeries plugin
under real OpenCPN (co-driven turn-by-turn in `C:\src\OpenCPN\oESeries\docs\notes\build_and_test_oe.md`).
What actually got built + proven on the hub side (all in the working tree, UNCOMMITTED):

**Built (hub half):**
- `navIdentity.pm` (NEW) -- promoted the uuid<->GUID codec out of `navGPX.pm` + `makeOCPNUUID` (`0x4f`)
  + `reconcileGuidToUuid` (idempotent foreign mint) + `projectUuidToGuid`. `navGPX.pm` now imports it.
- `nmOCPNDirectOps.pm` (NEW) -- the pure ingest/project/command-build layer: `ingestInventory`
  (marks/routes/tracks, mark-vs-vertex split, vertex materialization), `projectDBMarksToWire`,
  `buildMarkCommand`/`buildRouteCommand` (route = full-embed).
- `navOCPN.pm` (REWRITTEN) -- structured ocdb held as ONE shared JSON scalar under one lock
  (HTTP thread pool); `pollView`/`receiveInventory`/`dumpState`/`resetState`/`enqueueCommands`/
  `_consumeResults` + accessors; `jsonResponse` (see below).
- `navServer.pm` -- `/api/ocpn` now the full sec-2A body + structured dump.
- `_testOEServer.pm` (NEW, repo root) -- headless harness: real `/api/ocpn` over the real ocdb, plus
  `/debug/reset|project|enqueue|health` (autonomous-peer surface). Opens the dev DB READ-ONLY.
- `test/_fixtures/ocpn_nasty_strings.json` + throwaway fixtures (in `C:\_temp`).

**Load-bearing hub design decisions that emerged during the alpha:**
- **Wire encoding**: `/api/ocpn` MUST bypass `Pub::my_encode_json` (renders bools as `"1"`,
  HTML-entity-encodes non-ASCII) and encode with `JSON::PP` ascii mode. See memory
  `ocpn_wire_json_encoding`. R3 nasty-strings = codepoint-equality, not byte-for-byte.
- **Full-state REPLACE (not upsert)**: each POST is the plugin's COMPLETE inventory (sec 12), so
  `ingestInventory` REBUILDS marks/routes/tracks each POST (keeping the persistent guid map) -- else
  a plugin-side delete leaks forever. Reports `*_removed`.
- **Echo-no-remint** holds structurally: ingest never advances `navmate_dt` (only `enqueueCommands`
  does), so an echoed object never mints a command. Proven every run.
- **Diag retire is guid-agnostic** (a `{op:diag}` ack retires the pending diag regardless of guid,
  since 2A allows `guid:"*"`); `dumpState.last_results` preserves the last NON-empty results[] (the
  plugin re-POSTs with empty results[], which must not clobber diag data).

**Bench-proven (Mode-2, real OpenCPN):** identity round-trips for marks/routes/tracks; the ~84
double-count deduped at source (oe fix) + hub-side by identity; merge-on-apply; idempotent-on-retry;
**write-side GUID preservation for all three types incl. R2 PASS** (`AddPlugInRouteExV2` keeps caller
per-vertex `m_GUID`); **R1 = LEAK, measured + transient** (`OBJECTS_NO_LAYERS` is the 5.12.4 stub;
mitigation is plugin-side; hub tolerates + reads `results[].ok`).

**STILL DEFERRED (unbuilt; the plan's Steps 1,4,5 + parts of 7 remain):** the schema-13.1 migration
(`0x4f`/`ocpn_guid_map` PERSISTENCE, `db_version` counter, `icon_name` shadow, `sym<->icon` table) --
the alpha ran the guid map + command DT IN-MEMORY only; `winOCPN` pane; `navOpsOCPN` + the
paste/push navOps wiring; the `test/ocpn` runbook module. The alpha proved the WIRE + direct-ops;
these wire it into the app.

## UX build (2026-07-05, co-built in `opencpn_implementation.md`) -- BUILT, awaiting alpha

The full two-way user feature is now built and compiling (working tree, uncommitted); co-built with
oe-claude in `docs/notes/opencpn_implementation.md` (Turns 1-5). Landed: schema **13.1** (all four
pieces persistent now, migration `13.0->13.1` additive), `winOCPN.pm` (read-only live browser +
`navVisibility` `'ocpn'` store + `nmResources`/`nmFrame` wiring + onIdle refresh clock),
`navOpsOCPN.pm` + the `'ocpn'` arms across `navOps`/`navClipboard`/`navOpsFSH`/`navOpsDB` (inbound
PASTE reuses `_pasteDB`; outbound = **both** Push-to-OpenCPN from the DB pane AND paste-into-pane,
Patrick's call), the outbound projector `nmOCPNDirectOps::buildCommandsForItems` (manifestation XOR
= route-membership-structural, full-embed routes -- unit-verified), the 36-entry `sym<->icon` table
(`@SYM_DEFAULT_ICONS` + `navDB::symForIcon`/`iconForSym`), and foreign-GUID persistence
(`persistOCPNIdentity`/`loadOCPNGuidMap`, write on inbound paste + read-merge on outbound push).
Design decisions this round: (1) the pane is **read-only** in v1 (mutation via navOps, not in-pane
editing) -- lowest wx risk + matches the live-projection nature; (2) **No "New..."** for the OCPN
pane (objects arrive by paste/push); (3) `generation` token surfaced but its consumer deferred
(oe self-heals via `ocpn_dt`->0 + idempotent apply). **Remaining:** the `test/ocpn` runbook (needs a
new folder + real results -> held for the alpha), Patrick's hands-on UX alpha of the pane, then ONE
Mode-2 bench pass with oe driven from the real UI.
