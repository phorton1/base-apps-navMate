# navOperations Test Run -- Cycle 28

**Date:** 2026-06-14
**Start:** 20:13
**End:** 21:51
**Cycle:** 28

Context: full regression run after the schema 12->13 change ("NO MORE NULLS IN DATABASE",
commit 0b3cde5) and the example-DB installer work. E80, navMate (dev, port 9883), and
teensyBoat (9881) all live. Per operator direction, this run **self-corrected the runbooks
and pass-criteria in place** as it went -- every cycle-27 non-PASS was a test-plan/runbook
staleness, not an application defect, and each was fixed at the source. The only stop-worthy
event would have been a genuine code regression; none occurred.

UUID index note: the index was last verified at schema 10; all 14 spot-checked db-side baseline
UUIDs still resolve under schema 13 (migration preserved content UUIDs). `node_type` is now `''`
(empty string) rather than NULL, confirming the no-nulls change landed without breaking tree
rendering or any operation.

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all 44 steps |
| e80    | PASS -- 50 steps; e80.27 NOT_RUN (by design) |
| tracks | PASS -- teensyBoat available; all 16 steps |
| fsh    | PASS -- all 44 steps |
| hub    | PASS -- 26 steps; hub.G2 NOT_RUN (by design) |

No application regression attributable to the schema change or any other recent commit was
observed. One known intermittent infrastructure bug recurred (Clear-E80 ProgressDialog hang at
the fsh-module reset; rescued by `close_dialog`) -- it did not cause any test to fail.

### Runbook / pass-criteria corrections applied this cycle

- **master_runbook.md** -- added `WARNING: not enquiing duplicate api_command(2)` (d_WPMGR.pm[141])
  to the Known-Quiet Warnings table. It is reproducible background noise on every E80 route op
  (~10 lines); fixes e80.3/e80.7/e80.12a/e80.16b which were PASSED_BUT in cycle 27.
- **db/runbook.md** -- db.G9: replaced the stale absolute "(12 -> 15)" route_waypoints assertion
  with the real invariant (delta == COPY item count; absolute baseline is dynamic because db.35
  and db.37 append route_waypoints earlier in the cycle).
- **e80/runbook.md** -- G1: added setup (re-upload Popa group + route) + teardown to repair the
  orphaned precondition (e80.21a/21b tear the group+route down before the guards). G3/G4:
  corrected the post-truncation collision pass-criteria to the actual sentinels (they name the
  distinct source WPs, which is itself proof the post-truncation comparison fired). G5: corrected
  the over-strong "E80 empty" prerequisite to the real requirement (Popa route members absent).
  G12/G16: replaced the hardcoded-and-absent Popa group with a dynamic lookup of the named group
  actually on E80 (Timiteo from e80.22), and corrected the stale "Popa present since ..." prose.
- **tracks/runbook.md** -- tracks.5: corrected the stale "tracks count = 1" (E80Track1 from
  tracks.1 lingers, so count = 2) and the SAVED-ack log wording (`d_TRACK_writer SAVED ok`).
  tracks.11/tracks.12: fixed an invalid-PowerShell line in the fresh-uuid selection block
  (`$nmdb_uuids[$_] = 1 foreach (...)` -> a proper `foreach` loop).
- **fsh/runbook.md** -- G1: repaired the orphaned precondition (fixture Timiteo `C482-CBA0...`
  is deleted by fsh.14) by targeting the present in-route Popa group (244E-8E10-0800-400A), whose
  members are in the fresh Popa route from fsh.20. G10: same orphaned-fixture-Timiteo destination
  -> dynamic present-group lookup. G11: corrected the post-truncation collision criterion (same
  family as e80.G3). fsh.14: corrected the stale "5 groups" prose (fsh.11b dissolves one -> 4).

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
| db.G9 | PASS (runbook corrected) |
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
| e80.3 | PASS (warning now known-quiet) |
| e80.4 | PASS |
| e80.5 | PASS |
| e80.6 | PASS |
| e80.7 | PASS (warning now known-quiet) |
| e80.8 | PASS |
| e80.9a | PASS |
| e80.9b | PASS |
| e80.10a | PASS |
| e80.10b | PASS |
| e80.11a | PASS |
| e80.11b | PASS |
| e80.12a | PASS (warning now known-quiet) |
| e80.12b | PASS |
| e80.13 | PASS |
| e80.14 | PASS |
| e80.14b | PASS |
| e80.14c | PASS |
| e80.15 | PASS |
| e80.16a | PASS |
| e80.16b | PASS (warning now known-quiet) |
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
| e80.G1 | PASS (runbook corrected -- setup/teardown) |
| e80.G2 | PASS |
| e80.G3 | PASS (criterion corrected) |
| e80.G4 | PASS (criterion corrected) |
| e80.G5 | PASS (prerequisite corrected) |
| e80.G6 | PASS |
| e80.G7 | PASS |
| e80.G8 | PASS |
| e80.G9 | PASS |
| e80.G10 | PASS |
| e80.G11 | PASS |
| e80.G12 | PASS (runbook corrected -- dynamic group) |
| e80.G13 | PASS |
| e80.G14 | PASS |
| e80.G15 | PASS |
| e80.G16 | PASS (runbook corrected -- dynamic group) |
| **tracks** | |
| tracks.1 | PASS |
| tracks.2 | PASS |
| tracks.3 | PASS |
| tracks.4 | PASS |
| tracks.5 | PASS (runbook corrected) |
| tracks.6 | PASS |
| tracks.7 | PASS |
| tracks.8 | PASS |
| tracks.9 | PASS |
| tracks.10 | PASS |
| tracks.11 | PASS (runbook PowerShell fixed) |
| tracks.12 | PASS (runbook PowerShell fixed) |
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
| fsh.14 | PASS (prose corrected) |
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
| fsh.G1 | PASS (runbook corrected -- present in-route group) |
| fsh.G2 | PASS |
| fsh.G3 | PASS |
| fsh.G4 | PASS |
| fsh.G5 | PASS |
| fsh.G6 | PASS |
| fsh.G7 | PASS |
| fsh.G8 | PASS |
| fsh.G9 | PASS |
| fsh.G10 | PASS (runbook corrected -- dynamic group) |
| fsh.G11 | PASS (criterion corrected) |
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

No test recorded FAIL, PARTIAL, or PASSED_BUT this cycle. Every cycle-27 non-PASS item was a
runbook/pass-criteria staleness and was corrected in place (see Summary). The items below are
non-test observations worth recording.

### Clear-E80 ProgressDialog hang during the fsh-module inter-module reset (close_dialog rescued)

- Module: fsh (occurred in the fsh-module baseline reset, before fsh.1) -- the **same spot** as
  the cycle-27 recurrence of this bug.
- The reset's `op=clear_e80` opened a 'Clear E80 DB' ProgressDialog that did not auto-FINISH;
  `dialog_state` reported `active`. The operator confirmed the hung dialog at the console.
  `close_dialog` cleared it (`dialog_state: idle`) and the wx idle loop resumed; the DB had been
  reverted to baseline before the hang and the FSH fixture loaded cleanly afterward (50/4/3/123),
  so the fsh baseline was intact and every fsh test ran normally.
- This is the documented intermittent `clear_e80_progress_hang` open bug (also seen cycles 25/27).
  The hub-module reset's `clear_e80` immediately afterward did NOT hang, consistent with the bug
  being intermittent.
- Catastrophic: no (rescued; module completed all 44 steps).

### e80.27 / hub.G2 -- NOT_RUN (by design)

- e80.27 (UUID conflict dialog path): requires DB-versioning infrastructure that does not yet
  exist. Structural NOT_RUN, unchanged from prior cycles.
- hub.G2 (name collision destination-side): the precondition (two records sharing a name on one
  spoke) cannot be constructed via any in-app paste under the 2026-05-20 no-silent-rename policy,
  since the setup paste is itself blocked at preflight. The collision-on-paste path it would have
  covered is already exercised by hub.8 / hub.10 / hub.11 / hub.20 / hub.21. Not a defect.
