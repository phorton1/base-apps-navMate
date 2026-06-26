# reflash Module -- Plan

The mod003 timed-track **phase (b)** module: confirm that a navMate timed track round-trips through a deliberately-reflashed **bare-stock (non-mod003) E80**, and that writing a timed track to such a unit is safe (no boot-loop).  This is the ONLY coverage of "a bare-stock flash specifically"; everything else about the timed-track data path is firmware-independent and is covered headlessly in the `tracks` and `fsh` modules.

**This module is STANDALONE and NOT part of the recurring full cycle.**  It is run ONCE, by hand, after a deliberate reflash of a bench E80 to stock firmware -- a do-once confirmation, not a per-cycle test.  The full-cycle orchestrator does NOT step into it; it would only ever record `NOT_RUN` on a normal mod003 bench.  See `../full_cycle_plan.md` (Out-of-cycle modules).

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md).  For shared toolbox, see [`../master_runbook.md`](../master_runbook.md).  For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).  For the data-path design, see [`../../docs/timed_tracks.md`](../../docs/timed_tracks.md).  For execution, see [`runbook.md`](runbook.md).

---

## Why this module exists (and why it is small)

The mod003 hub<->spoke contract writes a TIMED track point whenever the DB row carries a timestamp, **regardless of target firmware** -- the E80 never surfaces a track point's depth/temp (it neither displays nor acts on them), so a stock / pre-5.73 unit is a faithful dumb store: timed bytes are byte-identical-length to stock, round-trip losslessly, and are recoverable by any mod003-aware reader.

Two consequences:

1. **Almost nothing here is unique.**  The encode, the decode, the write-preference, every lossy-warn branch, and the full round-trip are firmware-agnostic and already proven on the 5.73 bench (phase a: `tracks.14/15/G4`, `fsh.40/G12`).  The firmware-free `fsh.40` round-trip (in-memory) already stands in for most of phase (b).
2. **One thing IS unique and worth a do-once check:** that a *real bare-stock E80* -- not the in-memory FSH store, not a mod003 unit -- faithfully stores and returns the overloaded bytes, and that the value-extreme timed-depth write (a unix timestamp ~1.78e9 in the wire depth field) does NOT corrupt a record and boot-loop the unit.  Patrick has lived a protocol-mismatched write persisting a corrupted record to flash; this module is the deliberate, low-risk confirmation that timed writes are NOT such a case.

## Module Scope

- DB->E80 timed write to a bare-stock unit (write-safety).
- E80->DB decode of that same track back off the bare-stock unit (round-trip fidelity).
- NO teensyBoat (records nothing -- it writes the real `[TIMED_CAT32]` DB track to the E80 and reads it back).
- NO recording, NO FSH, NO guards.

## Baseline + firmware pre-check

The reflash module's baseline:

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` (with ProgressDialog wait + hang-rescue -- `clear_e80` can hang intermittently; check `dialog_state` and `close_dialog` if active).
5. `force_timed_tracks?cmd=set&val=1` -- force-timed write (the point of the module).
6. `cmd=mark+reflash+module+reset`
7. **firmware pre-check** -- read `timed_tracks?cmd=get` for the connected unit's `version`.  The module runs against ANY connected unit (the writes are firmware-INDEPENDENT) and ANNOTATES the result by firmware:
   - not connected -> whole module `NOT_RUN (no E80 connected)`.
   - `version >= 5.73` (mod003) -> run, annotated **MODIFIED firmware** -- validates the module mechanics + write-safety on a modded unit; overlaps `tracks.15` (no unique coverage, but confirms the module works).
   - `version < 5.73` (stock) -> run, annotated **BARE-STOCK** -- the genuinely-novel scenario (firmware that doesn't understand the overloaded bytes); the do-once worth running after a deliberate reflash, and the module's unique value.

The earlier design GATED OUT mod003 (`NOT_RUN if >= 5.73`), which blocked even smoke-testing the module before a reflash; relaxed 2026-06-26 to run-and-annotate so the module can be validated on the current bench, with the bare-stock variant remaining the deferred do-once.

## Test Inventory

| Test | What it verifies |
|------|------------------|
| reflash.1 | **Write-safety.**  PASTE `[TIMED_CAT32]` to the bare-stock E80 tracks header under `force_timed=1`.  The writer-session SAVED ack lands, the track appears in `/api/db`, and -- critically -- the unit is STILL RESPONSIVE afterward (`/api/db` and a fresh `timed_tracks?cmd=get` still answer; no boot-loop).  The value-extreme ~1.13e9 timed-depth write (a 2005 unix timestamp in the wire depth field) did not corrupt flash. |
| reflash.2 | **Round-trip fidelity off bare stock.**  COPY the timed track from the bare-stock E80 and PASTE_NEW to DB; `/api/track_points` shows all 500 per-point `ts` preserved exactly (endpoints `1128888553`/`1128912810`, in order).  Proves the bare-stock unit was a faithful dumb store.  (Depth not asserted -- Cat32 carries none; the depth path is covered by tracks.14a.) |

## Notes

- **`[TIMED_CAT32]` is a real baseline track** (uuid `65b3888535b54913`, 500 pts, varied per-point ts, zero depth).  Per-point `ts` round-trips exactly (timestamps are not quantized).  Depth is not exercised here -- no saved track carries depth; the cm<->0.1ft depth path is covered in tracks.14a (real recorded depth via teensyBoat).
- **Run-after-deliberate-reflash only.**  This module assumes the operator has just reflashed a bench unit to stock and KNOWS it.  The firmware pre-check is a safety net, not the authority -- the operator's intent is.  Do NOT run it speculatively against an unknown unit.
- **No teensyBoat.**  Unlike `tracks`, this module records nothing; it only writes a pre-pinned DB track and reads it back.  teensyBoat availability is irrelevant.
- **Single-module run only.**  Like all single-module runs, this produces no `cycle_NN.md`; the operator reads results live.  It never increments the cycle number.
