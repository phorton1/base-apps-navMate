# tracks Module -- Plan

E80<->DB and FSH->E80 track operations.  Owns ALL E80 track test coverage: track recording (teensyBoat), download (E80->DB), upload (DB->E80, FSH->E80 via writer-session protocol), PUSH (E80->DB metadata sync), and track-specific guards.

The track-writer protocol (`NET/docs/notes/TRACK_writing.md`, confirmed live 2026-05-27) provides a wire path for DB->E80 track paste.  The previous "tracks read-only on E80" assumption has been retired; the corresponding obsolete guard tests in `e80/` and `hub/` are removed and their replacement coverage lives here.

For shared philosophy and status definitions, see [`../master_plan.md`](../master_plan.md).  For shared toolbox, see [`../master_runbook.md`](../master_runbook.md).  For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).  For execution, see [`runbook.md`](runbook.md).

---

## Module Scope

Tracks differ from WGR (waypoints/groups/routes) operationally:

1. **Recording happens only on E80** -- via teensyBoat (test path) or chartplotter UI (real-world).  No remote-start protocol.
2. **Upload uses the TRACK writer-session protocol** -- distinct from WPMGR; one TCP session per track upload on `E80:2053`.  Wired into `navOpsE80::_writeTrackToE80` / `_pasteTrackToE80` / `_pasteNewTrackToE80`.
3. **Track UUIDs on E80 are FID-keyed**, not name-keyed.  No name-uniqueness enforcement on the E80 spoke.  Per-chunk uuids on the wire are transient markers; only the MTA uuid is canonical.

## Baseline

The tracks module's baseline:

1. `git -C C:/dat/Rhapsody checkout -- navMate.db`
2. `op=refresh`
3. `op=suppress&val=1`
4. `op=clear_e80` (with ProgressDialog wait)
5. `op=load_fsh&path=C:/base/apps/navMate/test/_fixtures/test.fsh`
6. **pin both mod003 knobs** (the timed-track hazard guard, see Notes):
   - `force_timed_tracks?cmd=set&val=1` -- pin the navMate WRITE preference to its default (force-timed), so the encode tests start from a known write mode.
   - `timed_tracks?cmd=set&enabled=0` -- pin the E80 DEVICE recorder to STOCK, so an unpinned timed recorder cannot silently make tracks.1 record timed and shift the data under tracks.2-13.  Best-effort: meaningful only on a mod003 v5.73+ unit; on older/stock firmware the set returns an error and is a harmless no-op (stock firmware always records stock).  Do NOT fail the module on this error.
7. `cmd=mark+tracks+module+reset`
8. **teensyBoat pre-check** -- if teensyBoat is unavailable at `http://localhost:9881`, the entire module records as `NOT_RUN (teensyBoat unavailable)` and stops.

After setup: `/api/db` empty; `/api/nmdb` returns the full git-baseline DB; `/api/fsh` returns the test.fsh fixture (50 WPs / 4 groups / 3 routes / 123 tracks); teensyBoat reachable and responding to `?cmd=SIM`.

## Pre-flight rules invoked

- **SS8.2** -- delete-via-tracks-header.
- **SS10.3** -- DB-to-DB track copy blocked (covered in db module; referenced here for context).
- **Track preflight** (`navClipboard::_pasteTracksToE80Allows`) -- hard rules: `point_count > 0`, non-empty `mta_uuid`.  Name length and color drift are NOT hard rules; both are lossy transforms reported via the `lossyTransformWarning` dialog as advisory consent, then applied at the wire seam (silent truncation via `_truncForE80`, color snap via `abgrToE80Index`).
- **Lossy transform** -- DB-side long name (> `$E80_MAX_NAME` = 15) and non-palette color fire `_preflightLossyTransform`.  Tracks were added to the color-drift collector alongside routes 2026-05-28.
- **Timed-track lossy transform (mod003, preference-conditional)** -- a DB track with `ts_start > 0` fires one of TWO new lossy categories on `db_to_e80`, depending on the WRITE preference (`force_timed_tracks`): with the preference OFF (opt-out, "ride on stock") the timestamps are DROPPED (`ts_dropped`); with it ON (default) and the track's `ts_source` is not `'e80'` (i.e. its cm depths were not already quantized on a mod003 unit) the real depth is QUANTIZED to the 0.1 ft grid (`depth_degraded`).  The two are mutually exclusive (they fork on the preference).  Exact strings in `nmDialogs::lossyTransformWarning`; this is the first guard layer whose predicate READS A SETTING.  See [`../../docs/timed_tracks.md`](../../docs/timed_tracks.md).
- **D6 spoke content-vs-destination** -- track item pasted at a non-tracks-header E80 destination is rejected by the predicate layer in `_pasteRuleAllows`.

---

## Test Inventory

Two-section structure per master runbook's Test Organization Convention: positives first (`tracks.<N>`), guards last (`tracks.G<N>`).

### Section 1 -- teensyBoat + single-track E80->DB

| Test | What it verifies |
|------|------------------|
| tracks.1 | teensyBoat records TWO tracks on E80 (tracks.1a E80Track1, tracks.1b E80Track2 -- the second exists so tracks.4 has a fresh E80 uuid for the CUT+PASTE record-creating positive after tracks.2/3 contaminate the first uuid in DB) |
| tracks.2 | Copy E80Track1, Paste to DB (E80 UUID preserved; E80 track stays) |
| tracks.3 | Copy E80Track1, Paste New to DB (fresh navMate UUID; E80 unchanged) |
| tracks.4 | Cut E80Track2, Paste to DB (E80Track2 consumed by CUT; PASTE creates DB row at preserved E80Track2 uuid -- uuid is uncontaminated, so the 2026-05-29 uuid-collision preflight does not fire) |

End-of-Section-1 state: E80 has E80Track1 (tracks.2/3 are COPY, not CUT); DB has 3 records (E80Track1@preserved-E80, E80Track1@fresh-navMate, E80Track2@preserved-E80).  Section 2's tracks.5+ tolerates the leftover E80Track1.

### Section 2 -- DB/FSH -> E80 + multi-from-E80

| Test | What it verifies |
|------|------------------|
| tracks.5 | PASTE single DB track [DB_TRACK_SHORT] -> E80 tracks header (mta_uuid preserved; writer-session protocol) |
| tracks.6 | PASTE multi DB tracks [DB_TRACK_MULTI_B/C] -> E80 tracks header (two tracks land at preserved uuids).  001 is excluded because tracks.5 already pasted it to E80, and `_pasteAllToE80` rejects a batch that contains any uuid already present on the spoke. |
| tracks.7 | PASTE_NEW single DB track [DB_TRACK_SHORT] -> E80 (fresh navMate UUID minted at writer seam; DB unchanged) |
| tracks.8 | PASTE_NEW multi DB tracks -> E80 |
| tracks.9 | PASTE single FSH track [FSH_TRACK_BOCAS1_003] -> E80 (cross-spoke FSH-to-E80 via writer-session) |
| tracks.10 | PUSH E80 track -> DB (modify name/color on E80, push, observe DB row update) |
| tracks.11 | Multi-COPY from E80 -> PASTE to DB (E80 UUIDs preserved; PASTE hits in-place-update for any matching DB rows) |
| tracks.12 | Multi-CUT from E80 -> PASTE to DB (E80-side consumed; DB receives moved tracks) |
| tracks.13 | DELETE via E80 tracks header (mass cleanup of whatever remains) |

### Section 4 -- Timed tracks (mod003)

These exercise the mod003 timed-track cross-spoke data path on the E80 spoke.  They start from the empty E80 left by tracks.13.  The timed DB fixture is the REAL baseline track `[TIMED_CAT32]` (`2005-10-09-Cat32MissionBayToSanDiegoBay`, uuid `65b3888535b54913`, 500 pts, varied per-point ts) -- baseline-first, no synthetic insert.  The E80 stores a track point's depth/temp as a faithful dumb store, so the encode/decode round-trip is firmware-independent.  Depth coverage lives ONLY in tracks.14a (no saved DB track carries depth, so it is recorded live with a teensyBoat-injected depth).

| Test | What it verifies |
|------|------------------|
| tracks.14 | **Device-toggle recording decode** (firmware sub-gate: needs a mod003 v5.73+ unit AND teensyBoat).  14a: inject depth (`teensyBoat d=25` ft), flip recorder to timed (`timed_tracks?cmd=set&enabled=1`), record, download (E80->DB PASTE_NEW); `/api/track_points` shows per-point `ts` decoded (not lost into `depth_cm`) AND `depth_cm` ~762 (the injected 25 ft -- the one real depth check).  14b: flip back to stock, record, download; points decode with `ts=0`.  Covers BOTH spoke->hub decode branches from real on-device recordings.  If the unit is < v5.73, records `NOT_RUN (firmware precondition)`. |
| tracks.15 | **DB->E80->DB round-trip on real Cat32** (firmware-independent).  PASTE `[TIMED_CAT32]` to the E80 tracks header under `force_timed=1`; COPY it back from E80 and PASTE_NEW to DB; `/api/track_points` on the new DB row shows all 500 per-point `ts` preserved, endpoints (1128888553 / 1128912810) exact and IN ORDER, and the ~499 distinct-ts count intact -- the varied timestamps catch a point-reorder bug. No depth assertion (Cat32 carries none; depth is tracks.14a). |

### Section 3 -- Guards

| Test | What it verifies |
|------|------------------|
| tracks.G1 | PASTE track at non-tracks-header E80 destination rejected (D6 spoke content-vs-destination sub-rule).  E80 unchanged. |
| tracks.G2 | Lossy-warn fires both `truncated_names` and `color_mismatch` lines for [DB_TRACK_LONG_NONPALETTE]; under `suppress=1` (auto-accept), paste succeeds with name truncated at wire seam and color snapped to nearest palette index.  NOTE: this fixture track is itself TIMED (2006 `kml_timespan`), so with the baseline `force_timed=1` pin a THIRD `depth_degraded` lossy line co-fires (expected; assert name+color present, ignore the timed line). |
| tracks.G3 | uuid-collision preflight rejects spoke->DB record-creating PASTE when the source uuid already exists in DB.  Setup re-establishes shared uuid (PASTE DeLaLuna2Popa from DB to E80) then exercises the rejection (COPY from E80, PASTE to DB).  Sentinel names PUSH / PASTE_NEW as the alternatives. |
| tracks.G4 | **Timed-track lossy-warn matrix on `db_to_e80`** (preference-conditional).  Two phases over `[TIMED_CAT32]`: (a) `force_timed=1` -> the `depth_degraded` line is PRESENT (`"N track(s) have centimetre depths that will be quantized to 0.1 ft (written as timed tracks)."`) and `ts_dropped` is ABSENT; (b) `force_timed=0` -> `ts_dropped` PRESENT (`"N track(s) carry timestamps that will be DROPPED (stock-track write mode)."`), `depth_degraded` ABSENT.  Cat32's 39-char name co-fires a `truncated_names` line in both phases (expected, ignored -- like tracks.G2's two co-firing categories), so this asserts the timed line's presence/absence, not "exactly one line".  Restore `force_timed=1` after. |

## Intra-module sequencing

Tests build E80 state progressively from the empty baseline:

- Section 1 creates one E80 track (tracks.1), exercises COPY/PASTE_NEW (preserves E80), then CUT (consumes E80).  End of Section 1: E80 empty.
- Section 2 first repopulates E80 via DB->E80 paste tests (tracks.5-9), then exercises PUSH (tracks.10), then multi-from-E80 (tracks.11-12), then final cleanup (tracks.13).  End of Section 2: E80 empty.
- Section 3 guards run last; their setup uses [DB_TRACK_LONG_NONPALETTE] and any track item (Section 2 may leave one for cleanup; if not, the guard's setup pastes a fresh one).

## Notes

- **Two teensyBoat tracks needed**.  E80Track1 stays on E80 across tracks.2/3 (COPY, not CUT); its uuid is now in DB twice (preserved + fresh-navMate).  tracks.4 must CUT a record-creating positive at a fresh uuid -- the 2026-05-29 uuid-collision preflight rejects spoke->DB PASTE at an already-existing DB uuid -- so E80Track2 exists for tracks.4 to cut.  Mechanical multiplication via the writer-session protocol still serves Section 2's volume tests.
- Track-record protocol warnings (`TRACK EVENT(N)`, `enquing GET_CUR2`, `handleEvent() returning undef`, `bad points(0) != expected(N)`, `TRACK OUT OF BAND`) are documented protocol noise; see `../master_runbook.md` Known-Quiet Warnings.
- After tracks.1's recording, park the teensyBoat simulator with `S=0` (never `STOP` -- that halts the simulator entirely).
- tracks.G2 exercises both lossy-warn entries (name truncation + color snap) in a single test because `[DB_TRACK_LONG_NONPALETTE]` has BOTH a >15-char name AND a non-palette color.  Cheaper than two tests for the same dialog code path.
- `_pasteTracksToE80Allows`'s `point_count > 0` and non-empty `mta_uuid` hard rules are NOT exercised here.  No real-world UI flow can produce a DB row in those states (every DB track has positive points by construction; every DB row has a non-empty primary-key uuid).  The defensive code remains; integration-test coverage is omitted as unreachable.  See `survey_report.txt` 2026-05-29.
- `tracks.10` exercises the **natural color drift** from tracks.5's PASTE -- no out-of-band modify step.  The DB track had a non-palette color (`ffff6666`); the wire seam snapped it to a palette index; PUSH back to DB lands the palette-exact ABGR, which differs from the original.  This is a genuine diff sync without requiring chartplotter UI or external helpers.
- `[E80_TK1]` / `[E80_TK2]` UUIDs are derived at runtime from `/api/db` tracks after tracks.1a / tracks.1b save; vary per cycle.
- **`[TIMED_CAT32]` is a REAL baseline track** (`source=db`, uuid `65b3888535b54913`) -- chosen by a UUID pass over all 389 DB tracks as the only one with genuinely varied per-point timestamps (499 distinct of 500).  Its far-past 2005 date means it is unlikely to be disturbed by future DB edits.  It carries NO depth (like every saved track), and its 39-char name truncates on write -- both shape the tests above (depth -> tracks.14a via teensyBoat; G4 asserts timed-line presence, not "exactly one line").  No synthetic DB insert is used; this is baseline-first per `../master_runbook.md` (Baseline-first, construct-as-last-resort).
- **Depth via teensyBoat (tracks.14a).**  No saved DB track has depth, so the only real depth check records live: `teensyBoat d=25` feeds 25 ft, the mod003 recorder stamps it into each timed point (stored as 0.1 ft), and it decodes back to ~762 cm.  This is the single place the cm<->0.1ft depth path is exercised on real data; the unit-conversion chain (NMEA -> E80 -> mod003) is unverified until first run, so a 0 result there pauses for a decision rather than silently passing.
- **Firmware sub-gate (tracks.14 only).**  Recording a TIMED track requires the device recorder, which exists only on mod003 v5.73+.  tracks.14 reads `timed_tracks?cmd=get` for the connected unit's `version`; if `< 5.73` it records `NOT_RUN (firmware precondition)` and skips.  tracks.15 and tracks.G4 are firmware-INDEPENDENT (navMate encodes timed bytes the dumb-store E80 round-trips regardless), so they run on any connected unit.
