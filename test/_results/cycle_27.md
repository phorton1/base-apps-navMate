# navOperations Test Run -- Cycle 27

**Date:** 2026-06-11
**Start:** 13:05
**End:** 15:04
**Cycle:** 27

Context: first regression run of navMate after the Pub::Ray refactor (repo extracted
to C:\base\apps\navMate). E80, navMate (dev, port 9883), and teensyBoat (9881) all live.
Per operator direction this run did NOT self-modify the test plan or code on any
non-PASS; issues are recorded here for correction before a subsequent run.

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all 44 steps |
| e80    | PASS with caveats -- 4 PASSED_BUT, 1 FAIL, 1 NOT_RUN(by design); remaining 45 PASS |
| tracks | PASS -- teensyBoat available; all 16 steps |
| fsh    | PASS with caveats -- 1 FAIL, 1 PASSED_BUT; remaining 42 PASS |
| hub    | PASS -- 1 NOT_RUN(by design); remaining 26 PASS |

No application regression attributable to the refactor was observed. All non-PASS
items trace to (a) test-plan state-sequencing gaps that orphan guard preconditions,
(b) a documented intermittent Clear-E80 dialog hang, or (c) recent track-write /
pre-flight behavior changes (undocumented warning chatter and a collision-message
wording mismatch) that are non-breaking.

---

## Results Table

| Test | Status |
|------|--------|
| **db** | |
| db.1 | PASS |
| db.2 | PASS |
| db.3 | PASS |
| db.4 | PASS |
| db.5 | PASS |
| db.6 | PASS |
| db.8 | PASS |
| db.9 | PASS |
| db.10 | PASS |
| db.11 | PASS |
| db.12 | PASS |
| db.13 | PASS |
| db.14a | PASS |
| db.14b | PASS |
| db.15a | PASS |
| db.15b | PASS |
| db.16a | PASS |
| db.16b | PASS |
| db.17 | PASS |
| db.18 | PASS |
| db.19a | PASS |
| db.19b | PASS |
| db.35 | PASS |
| db.37 | PASS |
| db.G1 | PASS |
| db.G2 | PASS |
| db.G3 | PASS |
| db.G4 | PASS |
| db.G5 | PASS |
| db.G6 | PASS |
| db.G7 | PASS |
| db.G8 | PASS |
| db.G9 | PASS |
| db.G10 | PASS |
| db.G11 | PASS |
| db.G12 | PASS |
| db.G13 | PASS |
| db.G14 | PASS |
| db.G15 | PASS |
| db.G16 | PASS |
| db.G17 | PASS |
| db.G18 | PASS |
| db.G19 | PASS |
| db.G20 | PASS |
| **e80** | |
| e80.1 | PASS |
| e80.2 | PASS |
| e80.3 | PASSED_BUT |
| e80.4 | PASS |
| e80.5 | PASS |
| e80.6 | PASS |
| e80.7 | PASSED_BUT |
| e80.8 | PASS |
| e80.9a | PASS |
| e80.9b | PASS |
| e80.10a | PASS |
| e80.10b | PASS |
| e80.11a | PASS |
| e80.11b | PASS |
| e80.12a | PASSED_BUT |
| e80.12b | PASS |
| e80.13 | PASS |
| e80.14 | PASS |
| e80.14b | PASS |
| e80.14c | PASS |
| e80.15 | PASS |
| e80.16a | PASS |
| e80.16b | PASSED_BUT |
| e80.17 | PASS |
| e80.18 | PASS |
| e80.20a | PASS |
| e80.20b | PASS |
| e80.21a | PASS |
| e80.21b | PASS |
| e80.21c | PASS |
| e80.22 | PASS |
| e80.25a | PASS |
| e80.26 | PASS |
| e80.27 | NOT_RUN (db_versioning) |
| e80.28a | PASS |
| e80.G1 | FAIL |
| e80.G2 | PASS |
| e80.G3 | PASSED_BUT |
| e80.G4 | PASSED_BUT |
| e80.G5 | PASS |
| e80.G6 | PASS |
| e80.G7 | PASS |
| e80.G8 | PASS |
| e80.G9 | PASS |
| e80.G10 | PASS |
| e80.G11 | PASS |
| e80.G12 | PASS |
| e80.G13 | PASS |
| e80.G14 | PASS |
| e80.G15 | PASS |
| e80.G16 | PASS |
| **tracks** | |
| tracks.1 | PASS |
| tracks.2 | PASS |
| tracks.3 | PASS |
| tracks.4 | PASS |
| tracks.5 | PASS |
| tracks.6 | PASS |
| tracks.7 | PASS |
| tracks.8 | PASS |
| tracks.9 | PASS |
| tracks.10 | PASS |
| tracks.11 | PASS |
| tracks.12 | PASS |
| tracks.13 | PASS |
| tracks.G1 | PASS |
| tracks.G2 | PASS |
| tracks.G3 | PASS |
| **fsh** | |
| fsh.1 | PASS |
| fsh.2 | PASS |
| fsh.3 | PASS |
| fsh.4 | PASS |
| fsh.5 | PASS |
| fsh.6 | PASS |
| fsh.7 | PASS |
| fsh.8 | PASS |
| fsh.9 | PASS |
| fsh.10 | PASS |
| fsh.11a | PASS |
| fsh.11b | PASS |
| fsh.13 | PASS |
| fsh.14 | PASS |
| fsh.15a | PASS |
| fsh.15b | PASS |
| fsh.16a | PASS |
| fsh.16b | PASS |
| fsh.17a | PASS |
| fsh.17b | PASS |
| fsh.18 | PASS |
| fsh.19 | PASS |
| fsh.20 | PASS |
| fsh.21 | PASS |
| fsh.22 | PASS |
| fsh.23 | PASS |
| fsh.24 | PASS |
| fsh.25 | PASS |
| fsh.26 | PASS |
| fsh.28 | PASS |
| fsh.30a | PASS |
| fsh.31 | PASS |
| fsh.32a | PASS |
| fsh.G1 | FAIL |
| fsh.G2 | PASS |
| fsh.G3 | PASS |
| fsh.G4 | PASS |
| fsh.G5 | PASS |
| fsh.G6 | PASS |
| fsh.G7 | PASS |
| fsh.G8 | PASS |
| fsh.G9 | PASS |
| fsh.G10 | PASS |
| fsh.G11 | PASSED_BUT |
| **hub** | |
| hub.1 | PASS |
| hub.2 | PASS |
| hub.3 | PASS |
| hub.5 | PASS |
| hub.6 | PASS |
| hub.7 | PASS |
| hub.8 | PASS |
| hub.9 | PASS |
| hub.10 | PASS |
| hub.11 | PASS |
| hub.12 | PASS |
| hub.13 | PASS |
| hub.14 | PASS |
| hub.15 | PASS |
| hub.16 | PASS |
| hub.17 | PASS |
| hub.18 | PASS |
| hub.19 | PASS |
| hub.20 | PASS |
| hub.21 | PASS |
| hub.22 | PASS |
| hub.25 | PASS |
| hub.28 | PASS |
| hub.G1 | PASS |
| hub.G2 | NOT_RUN (no-silent-rename policy) |
| hub.G3 | PASS |
| hub.G4 | PASS |

---

## Issues

### e80.3, e80.7, e80.12a, e80.16b -- PASSED_BUT (undocumented `not enquiing duplicate api_command(2)` warnings on E80 route-header operations)

- Module: e80. Tests: e80.3 (Paste Route -> E80), e80.7 (Delete via Routes header),
  e80.12a (re-upload TestRoute), e80.16b (Paste New Route -> E80).
- Nodes involved: [TestRoute]/Popa route `f34efdd6070022e8` and its 11 member WPs;
  e80.16b's fresh-UUID route `814ef146d706047e`.
- Expected vs. actual: each test's primary data and ProgressDialog criteria were fully
  met (route lands/deletes with correct `num_wpts`, UUIDs preserved, ProgressDialog
  STARTED+FINISHED, no ERROR, no IMPLEMENTATION ERROR). However each emitted exactly
  10 `WARNING: not enquiing duplicate api_command(2)` lines from `NET/d_WPMGR.pm[141]`.
  This warning pattern is NOT in the master_runbook Known-Quiet Warnings table.
- Data state: no corruption; data outcomes exactly as expected. The warnings correlate
  with the per-member GET_ITEM fetches during route operations (11 members, one
  apparently de-duplicated).
- e80.3 additionally logged one `lossyTransformWarning: ... colors that cannot
  round-trip` line; that is the by-design lossy-transform notification (TestRoute color
  is non-palette) and is NOT itself an anomaly.
- Catastrophic: no.

### e80.G1 -- FAIL (orphaned guard precondition: Popa group/route absent from E80 at guard time)

- Module: e80. Test: e80.G1 (Delete E80 Group+WPS blocked -- member in route).
- Nodes involved: Popa group `244e8e100800400a` (intended right-click target) and
  Popa route `f34efdd6070022e8` (the route the guard's rejection depends on).
- Expected vs. actual: expected sentinel `ERROR - Cannot delete group 'Popa' and its
  waypoints: one or more members are used in a route.` Actual: `navTest: selected 0
  node(s), right_click=none` then `WARNING: navTest: fire cmd=10222 - no
  right_click_node set`. The Popa group node does not exist on the E80, so the command
  never dispatched and the guard's rejection path was never exercised.
- Root of the gap (observation only): the e80 positive sequence uploads Popa group last
  at e80.11a, then e80.21a deletes all E80 routes and e80.21b deletes all E80 groups+WPS
  for the 22/G6 cleanup. Nothing re-establishes Popa group + a route before the guards
  begin, so G1's precondition is orphaned. (Related runbook staleness: G12 prose says
  "Popa present since e80.22" and G16 says "since e80.9a/e80.11a"; both groups were
  deleted by 21b. In this run G12 and G16 were exercised against the live group actually
  present -- Timiteo from e80.22 -- which satisfies their selection-shape/destination-node
  predicates; both PASSED.)
- Data state: E80 unchanged by the no-op dispatch. Not corrupted.
- Catastrophic: no.

### e80.G3, e80.G4, fsh.G11 -- PASSED_BUT (post-truncation collision sentinel reports original names, not the truncated form)

- Module: e80 (G3 intra-batch, G4 vs-spoke) and fsh (G11 intra-batch).
- Nodes involved: DB WPs `BajaCalifornia~1` (`7b4e6d421403dc72`) and `BajaCalifornia~2`
  (`044e7e7017030a9e`); both truncate to `BajaCalifornia~` (15 chars).
- Expected vs. actual: each test functionally PASSED -- the post-truncation collision
  was detected and the paste blocked before any spoke write (E80/FSH counts unchanged,
  no ProgressDialog). However each runbook entry's pass criterion requires the abort
  sentinel to "mention the post-truncation form `BajaCalifornia~` (not the original
  names)" as proof the post-truncation comparison fired. The actual sentinels name the
  original full names (`BajaCalifornia~1` vs `BajaCalifornia~2`; or "...already on
  E80/FSH at UUID...") and never display the bare truncated key. The block itself
  proves the post-truncation comparison ran (the two full names differ and can only
  collide after truncation), so the behavior is correct; only the message wording fails
  the criterion as written.
- Data state: no mutation on any spoke; correct.
- Catastrophic: no.

### Clear E80 ProgressDialog hung during the fsh-module inter-module reset (close_dialog rescued)

- Module: fsh (occurred in the fsh-module baseline reset, before fsh.1).
- The reset's `op=clear_e80` opened a ProgressDialog that did not auto-FINISH. With the
  wx idle loop blocked by the modal, all subsequent `/api/test` (navTest) commands
  queued but never dispatched -- fsh.1's COPY/PASTE silently did nothing. `dialog_state`
  reported `active`; `close_dialog` cleared it (`dialog_state: idle`) and navTest
  dispatch resumed immediately. Operator confirmed at the console: "the ClearE80 dialog
  is hung." This is the documented intermittent `clear_e80_progress_hang` bug.
- Data state: DB had been reverted to baseline before the hang and nothing ran after it,
  so the fsh baseline was intact (DB at baseline, FSH fixture 50/4/3/123). E80 left in
  an indeterminate post-clear state, which does not affect the DB<->FSH-only fsh tests.
  fsh.1 was re-run cleanly after the rescue and PASSED. The same clear_e80 in the hub
  reset did NOT hang (verified `dialog_state: idle`), consistent with the bug being
  intermittent.
- Catastrophic: no (rescued; module completed).

### fsh.G1 -- FAIL (orphaned guard precondition: Timiteo fixture group/route deleted earlier in the module)

- Module: fsh. Test: fsh.G1 (Delete FSH Group+WPS blocked -- members in route).
- Nodes involved: Timiteo fixture group `C482-CBA0-D14E-67B2` (intended target) and the
  Timiteo route that its 6 members reference.
- Expected vs. actual: expected sentinel `ERROR - Cannot delete FSH group 'Timiteo' and
  its waypoints: ... members are referenced by routes...`. Actual: `navTest: selected 0
  node(s), right_click=none` + `WARNING: navTest: fire cmd=10222 - no right_click_node
  set`. The fixture Timiteo group no longer exists: fsh.14 (Delete via FSH Groups header)
  removed all groups and fsh.13 removed all routes earlier in the module, so the guard's
  precondition is orphaned. (fsh.19's own note acknowledges "The FSH fixture's Timiteo
  ... was removed in test 14.")
- Data state: FSH unchanged by the no-op dispatch.
- Catastrophic: no.

### fsh.G11 -- PASSED_BUT

- Covered above with e80.G3/e80.G4 (same post-truncation message-wording family).

### hub.G2 -- NOT_RUN (by design)

- Module: hub. Test: hub.G2 (Name collision destination-side). The runbook documents
  this as NOT_RUN under the 2026-05-20 no-silent-rename policy: the precondition (two
  records sharing a name on one spoke) cannot be constructed via any in-app paste, since
  the setup paste is itself blocked at preflight. The collision-on-paste path it would
  have covered is already exercised by hub.8 / hub.10 / hub.11 / hub.20 / hub.21. Not a
  defect.
