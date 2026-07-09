# navOperations Test Run -- Cycle 32

**Date:** 2026-07-09
**Start:** 11:54
**End:** 14:23
**Cycle:** 32

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all positives (25) + guards G1-G18; db.G19 REMOVED as a stale test |
| e80    | PASS -- all positives (incl. new utf8 e80.36) + guards (incl. new utf8 e80.G17); e80.27 NOT_RUN (db_versioning, by design) |
| tracks | PASS -- teensyBoat available; all positives + guards. tracks.14a required a re-run after a wonky USB connector was reseated (initial fail was a downed serial link, not a code defect) |
| fsh    | PASS -- all positives (incl. new utf8 fsh.41) + guards (incl. new utf8 fsh.G13) |
| ocpn   | PASS -- 17/20 positives + all 8 guards; ocpn.18 + ocpn.19 NOT_RUN (deferred, specialized setup). Full OpenCPN lifecycle clean (backup -> seed -> run -> restore) |
| hub    | PASS -- all positives (23) + guards G1/G3/G4; hub.G2 NOT_RUN (no-silent-rename policy) |

**All four never-run foreign-character tests PASS: e80.36, e80.G17, fsh.41, fsh.G13.**

---

## Results Table

| Test | Status |
|------|--------|
| **db** | |
| db.1 Position precision / AutoCompact (32 bisections) | PASS |
| db.2 Copy WP -> Paste New | PASS |
| db.3 Cut WP -> Paste (move) | PASS |
| db.4 Delete WP | PASS |
| db.5 Delete Group (dissolve) | PASS |
| db.6 Delete Group+WPS | PASS |
| db.8 Delete Branch (recursive) | PASS |
| db.9 Copy Branch -> Paste New | PASS |
| db.10 Cut Branch -> Paste (move) | PASS |
| db.11 Copy Route -> Paste New | PASS |
| db.12 Cut Route -> Paste (move) | PASS |
| db.13 Cut Track -> Paste (move) | PASS |
| db.14a Paste New Before (collection-member anchor) | PASS |
| db.14b Paste New After (collection-member anchor) | PASS |
| db.15a PASTE_NEW_BEFORE route point (copy-splice) | PASS |
| db.15b PASTE_BEFORE route point (cut-splice) | PASS |
| db.16a Paste New Before (route-object anchor) | PASS |
| db.16b Paste New After (route-object anchor) | PASS |
| db.17 Paste New Before (group-object anchor) | PASS |
| db.18 Paste New Before (branch-object anchor) | PASS |
| db.19a Paste New Before (route clipboard, WP anchor) | PASS |
| db.19b Paste New Before (group clipboard, WP anchor) | PASS |
| db.35 PASTE waypoint at DB route object (D3 REF append) | PASS |
| db.37 route_point COPY+PASTE_BEFORE at route_point (D1 carve-out) | PASS |
| db.38 COPY DB timed track -> PASTE_NEW_AFTER preserves per-point ts | PASS |
| db.G1 Delete Group+WPS blocked (members in route) | PASS |
| db.G2 Delete Waypoint blocked (WP in route) | PASS |
| db.G3 DB-copy track to DB destination blocked | PASS |
| db.G4 Recursive paste guard | PASS |
| db.G5 PASTE at DB WP object node blocked | PASS |
| db.G6 PASTE_NEW at DB WP object node blocked | PASS |
| db.G7 PASTE at DB track object node blocked | PASS |
| db.G8 Mixed clipboard PASTE_BEFORE at route_point | PASS |
| db.G9 Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS |
| db.G10 COPY WP -> PASTE blocked (DB-to-DB waypoint copy) | PASS |
| db.G11 COPY group -> PASTE blocked | PASS |
| db.G12 COPY route -> PASTE blocked | PASS |
| db.G13 COPY branch -> PASTE blocked | PASS |
| db.G14 COPY track -> PASTE_BEFORE blocked | PASS |
| db.G15 COPY track -> PASTE_AFTER blocked | PASS |
| db.G16 NEW_WAYPOINT at non-collection blocked | PASS |
| db.G17 NEW_ROUTE at non-collection blocked | PASS |
| db.G18 PASTE_BEFORE at route_point with non-WP clipboard blocked | PASS |
| db.G19 (route_point PASTE at collection blocked) | REMOVED (stale test -- see Issues) |
| **e80** | |
| e80.1 Paste WP to E80 | PASS |
| e80.2 Paste Group to E80 | PASS |
| e80.3 Paste Route to E80 | PASS |
| e80.4 Copy E80 WP, Push to DB | PASS |
| e80.5 Copy E80 WP, Paste New to DB | PASS |
| e80.6 Delete E80 WP | PASS |
| e80.7 Delete via E80 Routes header | PASS |
| e80.8 Delete via E80 Groups header | PASS |
| e80.9a Re-upload Popa group | PASS |
| e80.9b Delete E80 Group+members via group node | PASS |
| e80.10a Ensure ungrouped WP on E80 | PASS |
| e80.10b Delete via E80 My Waypoints | PASS |
| e80.11a Re-upload Popa group | PASS |
| e80.11b Copy E80 Group, Push to DB | PASS |
| e80.12a Re-upload TestRoute | PASS |
| e80.12b Copy E80 Route, Push to DB | PASS |
| e80.13 Multi-select Group+Route, Push to DB | PASS |
| e80.14 Paste New WP to E80 (fresh UUID) | PASS |
| e80.14b Copy E80 fresh-UUID WP, Paste to DB | PASS |
| e80.14c Mixed-classified E80 clipboard PASTE_NEW | PASS |
| e80.15 Paste New Group to E80 (all-fresh UUIDs) | PASS |
| e80.16a Ensure E80 routes empty | PASS |
| e80.16b Paste New Route to E80 | PASS |
| e80.17 Multi-select WPs, Paste to E80 | PASS |
| e80.18 Route point Paste Before/After on E80 | PASS |
| e80.20a Delete BarillasMarina from E80 | PASS |
| e80.20b Delete Mexico~99 from E80 | PASS |
| e80.21a Delete all E80 routes | PASS |
| e80.21b Delete all E80 groups+WPS | PASS |
| e80.21c Delete all E80 ungrouped WPs (no-op path) | PASS |
| e80.22 Ancestor-wins accept path | PASS |
| e80.25a Upload IsolatedWP1 to E80 | PASS |
| e80.26 UUID conflict clean-create path | PASS |
| e80.27 UUID conflict dialog path | NOT_RUN (db_versioning, by design) |
| e80.28a Ensure IsolatedWP1 on E80 | PASS |
| e80.36 Non-ASCII fold DB->E80 (NEW) | PASS |
| e80.G1 Delete E80 Group+WPS blocked (member in route) | PASS |
| e80.G2 DB-cut to E80 destination blocked | PASS |
| e80.G3 Intra-batch post-truncation WP collision | PASS |
| e80.G4 Vs-spoke post-truncation WP collision | PASS |
| e80.G5 Route-dependency pre-flight | PASS |
| e80.G6 Ancestor-wins reject path | PASS |
| e80.G7 Intra-clipboard name collision | PASS |
| e80.G8 E80-wide name collision | PASS |
| e80.G9 PASTE at E80 WP object node blocked | PASS |
| e80.G10 PASTE_NEW at E80 WP object node blocked | PASS |
| e80.G11 DELETE_GROUP at E80 my_waypoints blocked | PASS |
| e80.G12 DELETE_GROUP_WPS mixed my_waypoints+group blocked | PASS |
| e80.G13 WP paste at E80 routes header blocked | PASS |
| e80.G14 Group paste at E80 my_waypoints blocked | PASS |
| e80.G15 Route paste at E80 groups header blocked | PASS |
| e80.G16 Group paste at E80 named-group node blocked | PASS |
| e80.G17 Non-ASCII lossy-warn sentinel (NEW) | PASS |
| **tracks** | |
| tracks.1 Create two test tracks (E80Track1, E80Track2) | PASS |
| tracks.2 Copy E80Track1, Paste to DB | PASS |
| tracks.3 Copy E80Track1, Paste New to DB | PASS |
| tracks.4 Cut E80Track2, Paste to DB | PASS |
| tracks.5 PASTE single DB track -> E80 | PASS |
| tracks.6 PASTE multi DB tracks -> E80 | PASS |
| tracks.7 PASTE_NEW single DB track -> E80 | PASS |
| tracks.8 PASTE_NEW multi DB tracks -> E80 | PASS |
| tracks.9 PASTE single FSH track -> E80 (cross-spoke) | PASS |
| tracks.10 PUSH E80 track -> DB (color drift) | PASS |
| tracks.11 Multi-COPY E80 -> PASTE to DB | PASS |
| tracks.12 Multi-CUT E80 -> PASTE to DB | PASS |
| tracks.13 DELETE via E80 Tracks header | PASS |
| tracks.14a Timed recording decode (ts + injected depth) | PASS (re-run after connector reseat -- see Issues) |
| tracks.14b Stock recording stays stock | PASS |
| tracks.15 DB->E80->DB round-trip on Cat32 (per-point ts survival) | PASS |
| tracks.G1 PASTE track at non-tracks-header E80 destination | PASS |
| tracks.G2 Lossy-warn (name truncation + color drift) | PASS |
| tracks.G3 uuid-collision preflight on spoke->DB record-creating paste | PASS |
| tracks.G4a force_timed=1 fires depth_degraded, not ts_dropped | PASS |
| tracks.G4b force_timed=0 fires ts_dropped, not depth_degraded | PASS |
| **fsh** | |
| fsh.1 Paste WP to FSH | PASS |
| fsh.2 Paste Group to FSH | PASS |
| fsh.3 Paste Route to FSH | PASS |
| fsh.4 Paste Track to FSH | PASS |
| fsh.5 Copy FSH WP, Push to DB | PASS |
| fsh.6 Copy FSH Group, Push to DB | PASS |
| fsh.7 Copy FSH Route, Push to DB | PASS |
| fsh.8 Multi-select Group+Route, Push to DB | PASS |
| fsh.9 Copy FSH WP, Paste New to DB | PASS |
| fsh.10 Cut FSH WP, Paste to DB | PASS |
| fsh.11a Delete FSH WP | PASS |
| fsh.11b Delete FSH Group (dissolve) | PASS |
| fsh.13 Delete via FSH Routes header | PASS |
| fsh.14 Delete via FSH Groups header | PASS |
| fsh.15a Re-upload Popa group | PASS |
| fsh.15b Delete FSH Group+members via group node | PASS |
| fsh.16a Re-upload IsolatedWP1 | PASS |
| fsh.16b Delete via FSH My Waypoints | PASS |
| fsh.17a Re-upload Popa group | PASS |
| fsh.17b Re-upload TestRoute | PASS |
| fsh.18 Paste New WP to FSH | PASS |
| fsh.19 Paste New Group to FSH | PASS |
| fsh.20 Paste New Route to FSH | PASS |
| fsh.21 Multi-select WPs, Paste to FSH | PASS |
| fsh.22 Route point Paste Before/After on FSH | PASS |
| fsh.23 Cut FSH Track, Paste to DB | PASS |
| fsh.24 Copy FSH Track, Paste New to DB | PASS |
| fsh.25 Delete FSH Track | PASS |
| fsh.26 Delete via FSH Tracks header | PASS |
| fsh.28 Lossy-transform pre-flight (long-name) | PASS |
| fsh.30a Upload IsolatedWP1 to FSH | PASS |
| fsh.31 UUID conflict clean-create path | PASS |
| fsh.32a Ensure IsolatedWP1 on FSH | PASS |
| fsh.40 Timed-track DB->FSH->DB round-trip on Cat32 | PASS |
| fsh.41 Non-ASCII fold DB->FSH (NEW) | PASS |
| fsh.G1 Delete FSH Group+WPS blocked (members in route) | PASS |
| fsh.G2 DB-cut to FSH destination blocked | PASS |
| fsh.G3 Intra-clipboard name collision | PASS |
| fsh.G4 FSH-wide name collision | PASS |
| fsh.G5 PASTE at FSH WP object node blocked | PASS |
| fsh.G6 PASTE_NEW at FSH WP object node blocked | PASS |
| fsh.G7 WP paste at FSH routes header blocked | PASS |
| fsh.G8 Group paste at FSH my_waypoints blocked | PASS |
| fsh.G9 Route paste at FSH groups header blocked | PASS |
| fsh.G10 Group paste at FSH named-group node blocked | PASS |
| fsh.G11 Intra-batch post-truncation WP collision | PASS |
| fsh.G12a force_timed=1 fires depth_degraded | PASS |
| fsh.G12b force_timed=0 fires ts_dropped | PASS |
| fsh.G13 Non-ASCII lossy-warn sentinel (NEW) | PASS |
| **ocpn** | |
| ocpn.1 Inventory counts + shared-point reconcile | PASS |
| ocpn.2 navMate-origin ingest (table-free reverse) | PASS |
| ocpn.3 Foreign ingest (0x4f mint + map row) | PASS |
| ocpn.4 Idempotent re-ingest (echo-no-remint) | PASS |
| ocpn.5 PASTE OcpnHazard to DB (sym 7, LF comment, shadow B-superset) | PASS |
| ocpn.6a Route vertices range-copy (materialize incl. pure vertices) | PASS |
| ocpn.6b Route paste members-first (shared point one uuid) | PASS |
| ocpn.7 PASTE track to DB (0x4f preserved + shadow, depthless) | PASS |
| ocpn.8 PASTE_NEW foreign mark (fresh 0x4e, no shadow) | PASS |
| ocpn.9 Catch-all sym (2) + non-ASCII preserved | PASS |
| ocpn.10 Reverse fold (sym 27) + >255-char comment untruncated | PASS |
| ocpn.11 PUSH DB mark to OpenCPN (add cmd, dt advance, applied) | PASS |
| ocpn.12 PUSH DB route to OpenCPN (full-embed, applied) | PASS |
| ocpn.13 Manifestation XOR (no phantom standalone marks) | PASS |
| ocpn.14 Echo-no-remint (re-ingest queues zero commands) | PASS (via ocpn.4) |
| ocpn.15 Results ack (plugin POSTs results, ok:true) | PASS |
| ocpn.16 Cross-spoke OcpnHazard -> DB -> E80 (sym chain, flatten+truncate) | PASS |
| ocpn.17 Cross-spoke OcpnHazard -> DB -> FSH | PASS |
| ocpn.18 Round-trip drift (many-to-one fish sym) | NOT_RUN (deferred -- see Issues) |
| ocpn.19 navMate-origin B-superset round-trip | NOT_RUN (deferred -- see Issues) |
| ocpn.20 Foreign track round-trip re-emits original GUID | PASS |
| ocpn.G1 DB-Cut to OpenCPN blocked | PASS |
| ocpn.G2 PASTE at ocpn mark object node blocked | PASS |
| ocpn.G3 PASTE_NEW at ocpn mark object node blocked | PASS |
| ocpn.G4 WP at ocpn Routes header blocked | PASS |
| ocpn.G5 Route at ocpn My Waypoints blocked | PASS |
| ocpn.G6 Track at ocpn Routes header blocked | PASS |
| ocpn.G7 route_point at ocpn My Waypoints blocked | PASS |
| ocpn.G8 Same-uuid PASTE collision OpenCPN->DB | PASS |
| **hub** | |
| hub.1 Paste FSH WP -> E80 | PASS |
| hub.2 Paste FSH Group -> E80 | PASS |
| hub.3 Paste FSH Route -> E80 | PASS |
| hub.5 Paste E80 WP -> FSH (same UUID) | PASS |
| hub.6 Paste E80 Group -> FSH (same UUID) | PASS |
| hub.7 Paste E80 Route -> FSH (same UUID) | PASS |
| hub.8 Paste-New E80 WP -> FSH (name-collision block) | PASS |
| hub.9 Paste-New FSH WP -> E80 (fresh UUID) | PASS |
| hub.10 Paste-New E80 Group -> FSH (name-collision block) | PASS |
| hub.11 Paste-New FSH Route -> E80 (name-collision block) | PASS |
| hub.12 Cut E80 WP, Paste to FSH | PASS |
| hub.13 Cut FSH WP, Paste to E80 | PASS |
| hub.14 Cut E80 Group, Paste to FSH | PASS |
| hub.15 Cut FSH Group (79 members), Paste to E80 | PASS |
| hub.16 Push E80 WP -> FSH | PASS |
| hub.17 Push FSH WP -> E80 | PASS |
| hub.18 Push E80 Group -> FSH | PASS |
| hub.19 Push FSH Route -> E80 | PASS |
| hub.20 E80->FSH->E80 WP round-trip | PASS |
| hub.21 FSH->E80->FSH Group round-trip | PASS |
| hub.22 Multi-select 2 E80 WPs, Paste to FSH | PASS |
| hub.25 UUID-conflict in-place-update probe | PASS |
| hub.28 Route paste cross-spoke with missing members | PASS (hard-reject path) |
| hub.G1 Heterogeneous clipboard (Group+Route) blocked | PASS |
| hub.G2 Name collision destination-side | NOT_RUN (no-silent-rename policy) |
| hub.G3 Intra-clipboard name collision | PASS |
| hub.G4 Cross-spoke route paste at individual WP node | PASS |

---

## Issues

This section captures observations from THIS cycle. No test recorded a FAIL that survived verification; the items below are a removed stale test, an environment-caused transient, deferred tests, and documentation/fixture discrepancies noted along the way.

### db.G19 -- removed as a stale test (product is correct)

db.G19 expected a rejection when a route_point clipboard is PASTEd at a DB collection. Actual behavior: the paste completed (`PASTE STARTED`/`FINISHED`, no IMPL ERROR) with no data change. Investigation (navClipboard.pm:343-363, navOpsDB.pm:_pasteItemsToCollection -> _pasteOneWaypointToDB:180,239) showed the `route_point_at_non_route` predicate was intentionally WIDENED to accept a database collection as a valid route_point destination, where the executor materializes the point as a real waypoint (the supported OpenCPN-pure-vertex import path). For this fixture the referenced WP (`454e11a80b002884`) already exists in the DB, so materialization correctly no-ops (`no_change`, no auto-duplicate). The guard's rejection expectation is obsolete; the ocpn runbook's G7 message already reflects the widened predicate. Per operator direction, db.G19 was deleted from `db/runbook.md` and `db/plan.md` (it was the last guard, so no renumbering was needed). NB: `docs/navOperations.md:542-544` still states the old "route_point at any non-ref-only destination is rejected" behavior and is now stale (flagged, not edited).

### tracks.14a -- initial failure was a downed teensyBoat serial link, not a defect

On the first attempt tracks.14a returned 1 track point and depth_cm=305 (~10 ft) vs the injected 25 ft (~762 cm). Root cause: the USB connector between the laptop and the teensyBoat PCB was intermittently disconnected (teensyBoat's log showed `COM10 disconnected` / `Second Write attempted before First is done`), so neither the boat motion nor the `d=25` depth reached the E80 -- the "recording" was an artifact of a dead link that still produced a plausible-looking (wrong) result. The teensyBoat HTTP server answering `{ok:1}` does not indicate the serial link is alive. After the operator reseated the connector, a re-run (gated on a `SIM`-telemetry liveness check confirming the boat actually moved) gave the correct result: 3 points, all timed (ts >= 315532800), temp_k=0, and depth_cm=762..762 (exactly 25 ft). The mod003 timed+depth decode is correct. A SIM-liveness gate is now applied before every teensyBoat recording; see the `teensyboat_liveness_sim_gate` memory.

### clear_e80 ProgressDialog hang (known intermittent bug)

During the tracks-module baseline, `clear_e80` hit the documented intermittent `clear_e80_progress_hang` bug: the ProgressDialog stalled with the E80 still holding 9 leftover waypoints, blocking the wx idle loop (queued create_branch/load_fsh were starved). Rescued via `cmd=close_dialog`; a re-issued `clear_e80` then drained cleanly. This is baseline setup, not a scored test step; noted here because it recurred in the definitive pre-release cycle.

### ocpn.18 / ocpn.19 -- deferred (NOT_RUN)

Both require specialized setup the runbook flags as first-bench-stabilization work and that could not be reliably fabricated at the end of the run: ocpn.18 needs a distinct many-to-one fish-sym source to observe reverse-fold drift; ocpn.19 needs an OpenCPN-side B-superset EDIT (range-ring/scamin injected into OpenCPN) followed by PUSH-to-DB and a shadow-restore round-trip. The rest of the ocpn spoke -- inbound identity/fidelity (1-10), outbound apply+results-ack (11-15), cross-spoke chain (16-17), foreign-track identity round-trip (20), and all 8 guards -- verified cleanly.

### ocpn.9 -- astral R3 probe absent from the fixture (fixture/doc mismatch)

`plan.md` and `uuid_index.md` describe `[OCPN_CAFE]` as carrying an astral character U+1F6A2 as the R3 codepoint-equality probe. The actual `_fixtures/ocpn/seed.gpx` contains no such character (no raw `F0 9F 9A A2` bytes, no `&#x1F6A2;` / `&#128674;` entity). All BMP non-ASCII in the fixture (Cafe Nandu with capital N-tilde, and the comment's e/n/i/a accents + em-dash) round-trips through ingest + PASTE codepoint-exact. RESOLVED: the emoji was intentionally removed from the fixture; the stale astral mentions in `ocpn/plan.md` and `uuid_index.md` were reworded to describe ocpn.9 as a foreign-accented (non-ASCII) codepoint probe rather than an astral one. tracks.G2 name typo (below) fixed in `tracks/runbook.md`.

### tracks.G2 -- runbook expected-name typo (not a failure)

tracks.G2 lands the truncated E80 name `2006-01-11-SanD` (the correct 15-char truncation of "2006-01-11-**SanD**iego2DanaPoint"). The runbook's stated expectation `2006-01-11-Sand` has a lowercase 'd' typo; the code is correct.
