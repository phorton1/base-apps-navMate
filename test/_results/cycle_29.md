# navOperations Test Run -- Cycle 29

**Date:** 2026-06-26
**Start:** 13:44
**End:** 15:35
**Cycle:** 29

Context: first full regression run that includes the new **mod003 timed-track** feature tests.
E80 (live, **mod003 v5.73** -- modified firmware), navMate (dev, port 9883), and teensyBoat
(9881) all live. Per operator direction, this run **self-corrected runbooks/pass-criteria in
place** as it went; every non-PASS encountered was test-plan staleness or a harness artifact,
not an application defect. No application regression occurred.

New coverage this cycle (all PASS): the mod003 timed-track data path -- `tracks.14/15/G4`,
`fsh.40/G12`, and the `reflash` module. The timed fixture is the real baseline track
`[TIMED_CAT32]` (`65b3888535b54913`, 500 pts, 499 distinct per-point timestamps), chosen by a
UUID pass; depth coverage is recorded live via teensyBoat `d=` injection (no saved DB track
carries depth). Highlights:
- **tracks.14a:** teensyBoat `d=25` (ft) recorded on the mod003 unit decoded back to **depth_cm
  = 762 exact** (= 25 ft) with per-point timestamps present -- the real cm<->0.1ft depth path.
- **tracks.15 / fsh.40:** Cat32's 500 timestamps survived DB->E80->DB and DB->FSH->DB round-trips
  exact and in order (499 distinct preserved -- no reordering).
- **reflash (run against MODIFIED firmware):** a value-extreme timed-depth write to the live unit
  did not boot-loop it, and the track round-tripped faithfully. The bare-stock variant remains a
  deferred do-once (requires a deliberate reflash).

---

## Summary

| Module | Result |
|--------|--------|
| db      | PASS -- all 44 steps |
| e80     | PASS -- 51 steps; e80.27 NOT_RUN (by design) |
| tracks  | PASS -- teensyBoat available; 19 steps incl. 5 new mod003 timed-track tests |
| fsh     | PASS -- 46 steps incl. 2 new mod003 timed-track tests |
| hub     | PASS -- 27 steps; hub.G2 NOT_RUN (by design) |
| reflash | PASS -- 2 steps, run against MODIFIED (mod003 v5.73) firmware; bare-stock variant deferred |

No application regression was observed. One known intermittent infrastructure bug recurred
(Clear-E80 ProgressDialog hang at the fsh-module reset; rescued by `close_dialog`) -- it did not
cause any test to fail. Two self-inflicted harness artifacts (a 2-minute tool-timeout on the
long db.1 loop; the same fsh-reset dialog hang) were recovered in place; neither is an
application issue.

### Runbook / pass-criteria corrections applied this cycle

- **tracks/runbook.md + tracks/plan.md** -- tracks.G2: its fixture track
  (`2006-01-11-SanDiego2DanaPoint`) is itself a TIMED track (`kml_timespan`), so with the
  baseline `force_timed=1` pin it co-fires a third (`depth_degraded`) lossy line on top of the
  name-truncation + color-drift lines. Updated the criterion to assert the name+color lines are
  PRESENT and ignore the expected co-firing timed line (was: "exactly two lines").
- **reflash/runbook.md + reflash/plan.md** -- relaxed the firmware pre-check from "NOT_RUN unless
  bare-stock (< v5.73)" to "run against ANY connected unit and annotate the firmware variant
  (modified vs bare-stock)". The old gate blocked even smoke-testing the module before a reflash;
  the writes are firmware-independent, so the module is meaningful on both. Added a `clear_e80`
  dialog-hang check to the baseline.

---

## Results Table

| Test | Status |
|------|--------|
| **db** | |
| db.1 | PASS (re-run after 2-min tool-timeout on the 32-iter loop; harness, not app) |
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
| e80.3 | PASS |
| e80.4 | PASS |
| e80.5 | PASS |
| e80.6 | PASS |
| e80.7 | PASS |
| e80.8 | PASS |
| e80.9a | PASS |
| e80.9b | PASS |
| e80.10a | PASS |
| e80.10b | PASS |
| e80.11a | PASS |
| e80.11b | PASS |
| e80.12a | PASS |
| e80.12b | PASS |
| e80.13 | PASS |
| e80.14 | PASS |
| e80.14b | PASS |
| e80.14c | PASS |
| e80.15 | PASS |
| e80.16a | PASS |
| e80.16b | PASS |
| e80.17 | PASS |
| e80.18 | PASS |
| e80.20a | PASS |
| e80.20b | PASS |
| e80.21a | PASS |
| e80.21b | PASS |
| e80.21c | PASS |
| e80.22 | PASS (ancestor-wins verified: 6 group members = 6 total WPs, no orphan t01) |
| e80.25a | PASS |
| e80.26 | PASS |
| e80.27 | NOT_RUN (db_versioning) |
| e80.28a | PASS |
| e80.G1 | PASS |
| e80.G2 | PASS |
| e80.G3 | PASS |
| e80.G4 | PASS |
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
| tracks.1 | PASS (1a + 1b recorded via teensyBoat) |
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
| tracks.14 | PASS (NEW mod003: 14a timed+depth d=25->762cm exact; 14b stock ts=0) |
| tracks.15 | PASS (NEW mod003: Cat32 500-ts DB->E80->DB round-trip exact + in order) |
| tracks.G1 | PASS |
| tracks.G2 | PASS (runbook updated -- co-firing timed lossy line is expected) |
| tracks.G3 | PASS |
| tracks.G4 | PASS (NEW mod003: db_to_e80 timed lossy matrix -- depth_degraded / ts_dropped fork) |
| **fsh** | |
| fsh.1 | PASS (re-run after clear_e80 dialog-hang rescue at module reset) |
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
| fsh.40 | PASS (NEW mod003: Cat32 500-ts DB->FSH->DB round-trip exact + in order, headless) |
| fsh.G1 | PASS |
| fsh.G2 | PASS |
| fsh.G3 | PASS |
| fsh.G4 | PASS |
| fsh.G5 | PASS |
| fsh.G6 | PASS |
| fsh.G7 | PASS |
| fsh.G8 | PASS |
| fsh.G9 | PASS |
| fsh.G10 | PASS |
| fsh.G11 | PASS |
| fsh.G12 | PASS (NEW mod003: db_to_fsh timed lossy matrix -- depth_degraded / ts_dropped fork) |
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
| hub.15 | PASS (79-member group cut FSH->E80) |
| hub.16 | PASS |
| hub.17 | PASS |
| hub.18 | PASS |
| hub.19 | PASS |
| hub.20 | PASS |
| hub.21 | PASS |
| hub.22 | PASS |
| hub.25 | PASS |
| hub.28 | PASS (route with missing members hard-rejected; path a) |
| hub.G1 | PASS |
| hub.G2 | NOT_RUN (no-silent-rename policy) |
| hub.G3 | PASS |
| hub.G4 | PASS |
| **reflash** (run against MODIFIED firmware) | |
| reflash.1 | PASS (write-safety -- value-extreme timed write, unit stayed responsive, no boot-loop) |
| reflash.2 | PASS (round-trip -- 500 timestamps survived off the unit, endpoints exact) |

---

## Issues

No test recorded FAIL, PARTIAL, or PASSED_BUT this cycle. tracks.G2 surfaced as PASSED_BUT
mid-run (an expected extra lossy line) and was converted to PASS by a runbook wording fix per
operator direction. The items below are non-test observations worth recording.

### Clear-E80 ProgressDialog hang during the fsh-module inter-module reset (close_dialog rescued)

- Module: fsh (fsh-module baseline reset, before fsh.1) -- the **same spot** as cycles 25/27/28.
- The reset's `op=clear_e80` opened a 'Clear E80 DB' ProgressDialog that did not auto-FINISH; the
  hung modal held the wx idle loop, so every queued `/api/test` command silently failed to
  dispatch (no navTest firing) and fsh.1 appeared to do nothing. The operator confirmed the hung
  dialog at the console. `close_dialog` cleared it (`dialog_state: idle`), the idle loop resumed,
  and the fsh baseline was intact (E80 empty, FSH 50/4/3/123, DB reverted) -- every fsh test then
  ran normally.
- This is the documented intermittent `clear_e80_progress_hang` open bug. It recurred ONLY at the
  fsh reset; the tracks, hub, and reflash resets' `clear_e80` did not hang (the reflash baseline
  added a proactive dialog-state check + rescue). Consistent with the bug being intermittent.
- Lesson applied: a `dialog_state` check + `close_dialog` rescue after `clear_e80` should be part
  of every inter-module reset that follows a heavy spoke (it was added to the reflash baseline).
- Catastrophic: no (rescued; module completed all steps).

### db.1 -- 2-minute tool-timeout on first attempt (harness, not application)

- db.1 drives 32 sequential PASTE_NEW_BEFORE bisections, each waiting on a FINISHED marker; with
  the live E80 attached each iteration ran slower, and the loop crossed the harness's default
  2-minute command timeout at iteration ~30 of 32 (AutoCompact had already fired correctly). The
  orphaned `PrecisionTestBranch` was deleted and db.1 re-ran clean under a longer timeout
  (loop_inserts=32, AutoCompact YES, all 34 positions distinct). Not an application issue.

### reflash module run against MODIFIED firmware (not bare-stock)

- The reflash module was run against the currently-installed mod003 v5.73 firmware (the firmware
  gate was relaxed this cycle to run-and-annotate rather than NOT_RUN-on-mod003). Both steps
  passed, validating the module's mechanics and confirming write-safety + round-trip fidelity on
  a modded unit. This overlaps tracks.15 and does NOT exercise the module's unique value: the
  **bare-stock** scenario (a firmware that does not understand the overloaded bytes). That variant
  remains a deferred do-once, to be run after a deliberate reflash to stock firmware -- at which
  point reflash (or the whole cycle) should be re-run against the stock unit.

### e80.27 / hub.G2 -- NOT_RUN (by design)

- e80.27 (UUID conflict dialog path): requires DB-versioning infrastructure that does not yet
  exist. Structural NOT_RUN, unchanged from prior cycles.
- hub.G2 (name collision destination-side): the precondition (two records sharing a name on one
  spoke) cannot be constructed via any in-app paste under the no-silent-rename policy. The
  collision-on-paste path it would cover is already exercised by hub.8 / hub.10 / hub.11 /
  hub.20 / hub.21. Not a defect.
