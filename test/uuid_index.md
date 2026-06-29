# navOps Test Suite -- UUID Index

Lookup registry. Modules reference `[Name]` tokens; UUIDs live only here. This is a dictionary -- look up entries by name, don't read sequentially.

For static-baseline vs setup-derived UUID concepts, see [`master_plan.md`](master_plan.md). For test execution context, see [`master_runbook.md`](master_runbook.md).

---

## Source Conventions

- `source=db` -- entry exists in the git-baseline `C:/dat/Rhapsody/navMate.db`. UUID derived from live `/api/nmdb` after `op=refresh`. Re-derive when baseline DB changes.
- `source=fsh:_fixtures/test.fsh` -- entry exists in the frozen FSH fixture. UUID is stable indefinitely (fixture is frozen by policy).
- `source=setup:<op>` -- entry is produced by a module setup operation; UUID assigned at runtime. Noted as `dynamic` in the UUID column; the operation that produces it is named in the source column.

UUIDs re-derived 2026-06-29 from the git-baseline `navMate.db` (schema 13) after a major restructure: the entire `oldE80` top-level branch was removed, routes consolidated under Navigation/Routes, "Michelle" group/route renamed "DeLaLuna", and the Timiteo route recreated. FSH-side entries unchanged (frozen fixture).

---

## Static -- DB-side (`source=db`)

### Isolated waypoints

| [Name] | UUID | Notes |
|--------|------|-------|
| [IsolatedWP1] | 9e4e10cc5e03093e | BarillasMarina -- in Part 4 - Pacific Central/Places (bc4e6a005d03cbce); not in any route. (Groupedness is irrelevant to its roles -- it is only ever a COPY source, move/delete subject, or anchor. The old "isolated/ungrouped" framing no longer applies: the DB has zero ungrouped WPs.) |
| [IsolatedWP2] | 864e53b65f033436 | Mexico~99 -- same parent group (Part 4/Places, bc4e6a005d03cbce); not in any route |
| [IsolatedWP3] | f54e595460034e6e | PuestaDelSol -- same parent group (Part 4/Places, bc4e6a005d03cbce); not in any route; consumed by db module's delete-WP test |

### WP referenced in a route

| [Name] | UUID | Notes |
|--------|------|-------|
| [WPinRoute] | 314e56cc09005332 | Popa0 -- in Popa group; pos=0 in Popa route |

### Group without route refs

| [Name] | UUID | Notes |
|--------|------|-------|
| [GroupNoRoute] | a74e90d60300a434 | Bocas group -- 2 members (StarfishBeach + Fishfarm), none in route. Used by delete-group-with-WPs test. |
| [GroupNoRoute_Dissolve] | 4e4e405a08033af4 | Places group (Part 1 - Before Trip) -- 5 members, none in route; safe to dissolve. |

### Group with route refs

| [Name] | UUID | Notes |
|--------|------|-------|
| [GroupInRoute] | 244e8e100800400a | Popa group -- 11 members all in Popa route |
| [GroupWithRouteMembers] | 244e8e100800400a | Alias for [GroupInRoute] (same node, different role in different tests) |

### Test group / member (for ancestor-wins, paste-to-E80)

| [Name] | UUID | Notes |
|--------|------|-------|
| [TestGroup] | 1a4eaf5a8c00e922 | Timiteo -- under Navigation/Routes (ac4e2c500600b9aa); 6 members (t01-t06). NB its members are now ALSO referenced by the Timiteo route (864e0f0a49071680), but no TestGroup test requires route-free members (it is only ever a COPY source / anchor / predicate target). |
| [TestGroupMember] | d44e40468d000d96 | t01 -- first member of [TestGroup]. Used in ancestor-wins multi-select. |

### Route + route points

| [Name] | UUID | Notes |
|--------|------|-------|
| [TestRoute] | f34efdd6070022e8 | Popa route -- 11 WPs (Popa0-Popa10) |
| [RP1] | 314e56cc09005332 | Popa0 -- pos=0 in Popa route (= [WPinRoute]) |
| [RP2] | 8d4e68fa0a0073ee | Popa1 -- pos=1 |
| [RP3] | 454e11a80b002884 | Popa2 -- pos=2 |

### Branches (safe / unsafe / nested)

| [Name] | UUID | Notes |
|--------|------|-------|
| [SafeBranch] | 4c4e1e283f075040 | "Before Sumwood Channel" (under Michelle 2010-2011) -- Places group (7 WPs none in route) + 13 direct tracks; isBranchDeleteSafe=1. Shape note: no empty Tracks sub-branch and it carries tracks -- delete-safe regardless (db.8 only checks the subtree is gone). |
| [RouteBranch] | ac4e2c500600b9aa | Navigation/Routes -- 6 groups (Agua/Boatyard/DeLaLuna/Popa/RonAzul/Timiteo) + 5 routes (Agua/DeLaLuna/Popa/RonAzul/Timiteo) |
| [SomeBranch] | f64e54841003ea50 | "Part 2 - Baja California" -- Places group (16 WPs none in route) + Tracks sub-branch (8 tracks). Used by db.10 as a CUT+PASTE MOVE subject (delete-safety irrelevant); chosen to NOT collide with the Part 1 dissolve in db.5. |
| [NestedBranch] | 234e412e3104296e | MandalaLogs -- root level; Places + Tracks sub-branch |
| [ChildBranch] | 984e7898480427f6 | MandalaLogs/Tracks -- direct child of [NestedBranch]; used as recursive-paste target |
| [UnsafeBranch] | *none in DB* | NO delete-unsafe branch exists in the current DB -- every route is colocated with the groups holding its member WPs, so no branch deletion can orphan an external route. The db guard that used this (was db.G3) has been REMOVED. To restore it, construct the unsafe shape at setup (paste an isolated WP onto a route in a different branch, the way db.35 creates a cross-collection route_waypoint ref). |

### Track

| [Name] | UUID | Notes |
|--------|------|-------|
| [TestTrack] | 1a4eed924904ebbe | "2005-11-25-SanDiego2Oceanside" -- in MandalaLogs/Tracks; 500 pts, palette color (ff00ff00 green) |
| [TIMED_CAT32] | 65b3888535b54913 | "2005-10-09-Cat32MissionBayToSanDiegoBay" -- the mod003 timed-track fixture. 500 pts, `ts_source=gdb`, per-point timestamps that VARY (1128888553..1128912810, 499 distinct). Chosen by a UUID pass as the ONLY DB track with varied per-point ts (catches point-reorder bugs); far-past 2005 date makes it durable. Carries NO depth (like every saved track) and its 39-char name truncates on write. Used by tracks.14/15/G4, fsh.40/G12, reflash. |
| [DB_TRACK_SHORT] | bf4e346442079f0c | "DeLaLuna2Popa" -- 13 chars, 61 pts, color=ff0055ff (NON-palette -> color-snaps at the wire seam). The ONLY short non-palette DB track; the non-palette color is REQUIRED by tracks.9's PUSH-color-diff. |
| [DB_TRACK_LONG_NONPALETTE] | 824e8a104b04c37c | "2006-01-11-SanDiego2DanaPoint" -- 31 chars, 231 pts, color=ffffff00; exercises BOTH lossy-warn lines (name truncation + color snap) in a single paste |
| [DB_TRACK_MULTI_A] | bf4e346442079f0c | = [DB_TRACK_SHORT]. The single-PASTE track in tracks.5; NOT used in multi-PASTE because by then it lives on E80 (uuid-preserving multi-PASTE collides). |
| [DB_TRACK_MULTI_B] | 764e661676054678 | "Track2-004" -- 10 chars, 36 pts, palette color. First slot in the tracks.6 multi-PASTE batch. |
| [DB_TRACK_MULTI_C] | 544eb8d278059e18 | "Track2-005" -- 10 chars, 36 pts, palette color. Second slot in the tracks.6 multi-PASTE batch. |
| [DB_TRACKS_BRANCH] | *retired* | RETIRED -- 0 module references. (Was oldE80/Tracks, now removed from the DB.) |

### Paste destination

| [Name] | UUID | Notes |
|--------|------|-------|
| [DST] | *setup-created (`$DST`)* | No empty collection exists in the baseline DB. Each module's baseline setup CREATEs an empty branch (`op=create_branch&name=navTestDST`) and captures its runtime uuid into `$DST`; tests reference `$DST`. Empty at module-baseline; accumulates module output within a cycle. |

### Name-collision setup

| [Name] | UUID | Notes |
|--------|------|-------|
| [WP_A] | dynamic | First of two same-named DB WPs (locate two WPs sharing a name via `/api/nmdb` group-by-name). |
| [WP_B] | dynamic | Second same-named WP (same name as [WP_A], different UUID). |
| [SameNameWP] | dynamic | DB WP whose name equals [IsolatedWP1]'s name ("BarillasMarina"). The baseline DB has only one; the precondition is established by PASTE_NEW of [IsolatedWP1] into [DST] (mints a second same-named WP at a fresh uuid). The e80/fsh runbooks pick the first non-[IsolatedWP1] match. |

---

## Static -- FSH-side (`source=fsh:_fixtures/test.fsh`)

The fixture was copied 2026-05-17 from `FSH/test/working_oldE80.fsh`. Inventory: 50 isolated waypoints (under `my_waypoints`), 4 groups, 3 routes, 123 tracks. UUIDs below are FSH-native dashed-uppercase form -- the format returned by `/api/fsh` and stored in winFSH tree nodes. The navMate canonical form (16-hex lowercase, no dashes) is derived via `fshToNavUUID($fsh_uuid)` at the snapshot seam.

### Isolated waypoints (under FSH `my_waypoints`)

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_IsolatedWP1] | 80B2-C48A-5400-D3AE | "Waypoint 25" -- top-level; no group, no route ref |
| [FSH_IsolatedWP2] | 83B2-167D-3F00-ED99 | "Waypoint 10" -- top-level; no group, no route ref |
| [FSH_IsolatedWP3] | 83B2-167D-3F00-37D9 | "Waypoint 14" -- top-level; consumed by delete-WP test |

### Group without members in route (safe delete with WPS)

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_GroupNoRoute] | C482-CB97-D14E-67B2 | "test" group -- 79 embedded members, none referenced by any route. Safe for DELETE GROUP+WPS. |

### Groups with members in routes (delete-WPS blocked)

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_GroupInRoute] | C482-CBA0-D14E-67B2 | "Timiteo" group -- 6 embedded members, all referenced by Timiteo route. Smallest of the three in-route groups. |
| [FSH_GroupAguaRoute] | C782-7BB6-7A46-4722 | "Michel_Agua" group -- 10 embedded members, all in Michel_Agua route. |
| [FSH_GroupSumwoodRoute] | C782-7BB7-7A46-4722 | "Michel_Sumwood" group -- 46 embedded members, all in Michel_Sumwood route. |

### Route + route points (Timiteo)

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_TestRoute] | C482-CB9E-D14E-67B2 | "Timiteo" route -- 6 embedded points (t01..t06). |
| [FSH_RP1] | C482-CB98-D14E-67B2 | t01 -- first point of [FSH_TestRoute]. Also embedded in [FSH_GroupInRoute]. |
| [FSH_RP2] | C482-CB99-D14E-67B2 | t02 -- second point. |
| [FSH_RP3] | C482-CB9A-D14E-67B2 | t03 -- third point. |

### Track

| [Name] | UUID | Notes |
|--------|------|-------|
| [FSH_TestTrack] | A24E-672E-FE06-0A80 | "Track2-006" -- first track in fixture (123 tracks total). |
| [FSH_TRACK_BOCAS1_003] | 0E4E-0BEA-B407-584A | "BOCAS1-003" -- 74 pts, color=0 (palette). FSH-source positive PASTE-to-E80 candidate (clean path: short name + palette color, no lossy-warn fires). |

### FSH UUID format and selection-key construction

- FSH tree nodes use the dashed-uppercase UUID as the `uuid` field; `_getNodeKey` returns this verbatim. `select=<uuid>` in `/api/test?panel=fsh&select=...` uses the FSH-native form.
- Route point keys follow the same `rp:<route_uuid>:<wp_uuid>` shape as the database panel: `rp:C482-CB9E-D14E-67B2:C482-CB98-D14E-67B2`.
- Header keys: `header:groups`, `header:routes`, `header:tracks`. `my_waypoints` for the ungrouped WP node.
- When verifying state via `/api/nmdb` (DB side) after an FSH-to-DB op, expect lowercase-no-dash form -- run `$fsh_uuid -replace '-','' | ToLower` for cross-check.

---

## Setup-derived (`source=setup:...`)

These entries have no static UUID. The module's baseline setup creates them; the UUID is assigned at runtime and recorded in the module's working log for use by subsequent tests within the same module.

| [Name] | source | Notes |
|--------|--------|-------|
| [E80_WP] | setup:upload_wp([IsolatedWP1]) -- e80 module | Paste [IsolatedWP1] to E80 (UUID preserved). Used as the canonical upload-WP across e80 module tests. |
| [E80_GR] | setup:upload_group([GroupWithRouteMembers]) -- e80 module | Paste Popa group to E80 (UUID preserved). |
| [E80_RT] | setup:upload_route([TestRoute]) -- e80 module | Paste Popa route to E80 (UUID preserved). |
| [E80_TK1] | setup:teensyBoat_track(E80Track1) -- tracks module | First teensyBoat-recorded track; UUID assigned by E80 (byte 1 = B2). Lives on E80 across tracks.2/3 (COPY-only) and into Section 2. |
| [E80_TK2] | setup:teensyBoat_track(E80Track2) -- tracks module | Second teensyBoat-recorded track; fresh E80 uuid (byte 1 = B2). Used by tracks.4 as the CUT+PASTE record-creating positive (its uuid must be uncontaminated in DB because the 2026-05-29 uuid-collision preflight rejects spoke->DB paste at an existing DB uuid). |
| [E80_FRESH_WP] | setup:paste_new_wp -- e80 module | Fresh-UUID WP created by PASTE_NEW (navMate-assigned UUID, byte 1 = 0x4e). |
| [E80_FRESH_WP2] | setup:paste_new_wp -- e80 module | Second fresh-UUID WP. |
| [E80_RT_FRESH] | setup:paste_new_route -- e80 module | Fresh-UUID route from PASTE_NEW (preserves member WP UUIDs by reference). |
| [E80_RP1] / [E80_RP2] / [E80_RP3] | setup:paste_new_route -- e80 module | Route points in the fresh-UUID route; specific WP UUIDs documented in the e80 runbook's relevant test. |
Setup-derived UUIDs are derived from `/api/db` after the setup step completes and noted in the module's working log; they are NOT pre-resolved in this index.

(The mod003 timed-track fixture is a REAL baseline track, `[TIMED_CAT32]` -- see the DB-side Track table above -- not a setup-derived insert.  An earlier design used a synthetic `op=seed_timed_track` insert; that was dropped in favour of baseline-first per Patrick 2026-06-26.)

### Deferred fixtures (not yet produced)

| [Name] | source | Notes |
|--------|--------|-------|
| [FSH_TIMED_TRACK] | DEFERRED: bench card-pull | A real timed FSH file -- a `.fsh` pulled off a mod003 E80's CF card, carrying timed points written by the FIRMWARE (not by navMate's encoder). Would test FSH->DB decode in isolation. Not required by the current suite: `fsh.40` produces an equivalent timed FSH track in-memory by PASTEing `[TIMED_CAT32]` to the FSH tracks header, and the mod003 wire format is byte-identical-length to stock, so the same decode code is exercised. Drop the file into `_fixtures/` and register its FSH-native uuid here when a card-pull is available. |

---

## Lookups (not registered, for cross-reference)

These UUIDs are referenced in module specs for parent-collection navigation but do not get a `[Name]` token of their own:

| Description | UUID |
|-------------|------|
| Navigation top-level | 424e51840100072e |
| Navigation/Routes sub-branch | ac4e2c500600b9aa (= [RouteBranch]) |
| Navigation/Waypoints sub-branch | e54ede600200feee |
| oldE80 top-level | *removed from DB* |
| oldE80/Tracks branch | *removed from DB* |
| oldE80/Groups branch | *removed from DB* (was [UnsafeBranch]) |
| StarfishBeach | 9d4e232a0500dd90 (member of [GroupNoRoute]) |
| Fishfarm (member of Bocas group) | 124e0eb404000564 |
| IsolatedWP parent (Part 4/Places) | bc4e6a005d03cbce |
| Popa0 / Popa1 / Popa2 | 314e56cc09005332 / 8d4e68fa0a0073ee / 454e11a80b002884 |
| Michelle context | 964e0db8350781ca ("Michelle 2010-2011"; old "Michelle" 034e6b8ccb01fffe removed) |
| Part 1 - Before Trip | 214e7db00703a184 |
| Agua group | 204ecbd24500a678 |
| Agua route | d64e8c7e4400a186 |
| DeLaLuna group (was "Michelle") | 104e199a1500e646 |
| DeLaLuna route (was "Michelle") | 3b4e87f21400d81c |
| Timiteo route | 864e0f0a49071680 |

---

## Maintenance

When the baseline `navMate.db` changes, every `source=db` entry needs re-derivation:

1. Revert and refresh `navMate.db`.
2. For each `[Name]` entry: locate by role description; derive the new UUID from `/api/nmdb`.
3. Update the table here.
4. Module references survive automatically -- they cite `[Name]`, not UUID.

When `_fixtures/test.fsh` is regenerated, `source=fsh:...` entries need similar re-derivation. The fixture is frozen by policy, so this should be rare; only required if a test deliberately needs a new FSH shape.
