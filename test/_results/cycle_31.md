# navOperations Test Run -- Cycle 31

**Date:** 2026-07-01
**Start:** 12:19
**End:** 13:44
**Cycle:** 31

First full cycle run with a **slave E80-4 also live on the LAN** alongside the E80-2 master, and
with the "E80"->"ESeries" guard-message rename in place. All four hardware-bearing modules ran
live against E80-2 (master, mod003 v5.73) + teensyBoat. No numbered test failed. Two operational
events during inter-module resets (both resolved, neither a numbered-test failure) are recorded
in Issues.

---

## Summary

| Module | Result |
|--------|--------|
| db     | PASS -- all 25 positives + 19 guards |
| e80    | PASS -- all positives + 16 guards (e80.27 NOT_RUN: db_versioning) |
| tracks | PASS -- teensyBoat available, mod003 v5.73; all positives + guards |
| fsh    | PASS -- all positives + 12 guards |
| hub    | PASS -- all positives + guards (hub.G2 NOT_RUN: no-silent-rename policy) |

---

## Results Table

| Test | Status |
|------|--------|
| **db** | |
| db.1 -- Position precision (32 PASTE_NEW_BEFORE bisections force AutoCompact) | PASS |
| db.2 -- Copy WP -> Paste New | PASS |
| db.3 -- Cut WP -> Paste (move) | PASS |
| db.4 -- Delete WP (success) | PASS |
| db.5 -- Delete Group (dissolve) | PASS |
| db.6 -- Delete Group+WPS (success) | PASS |
| db.8 -- Delete Branch (recursive, safe) | PASS |
| db.9 -- Copy Branch -> Paste New | PASS |
| db.10 -- Cut Branch -> Paste (move) | PASS |
| db.11 -- Copy Route -> Paste New | PASS |
| db.12 -- Cut Route -> Paste (move) | PASS |
| db.13 -- Cut Track -> Paste (move) | PASS |
| db.14a -- Paste New Before (collection-member anchor) | PASS |
| db.14b -- Paste New After (collection-member anchor) | PASS |
| db.15a -- PASTE_NEW_BEFORE route point (copy-splice) | PASS |
| db.15b -- PASTE_BEFORE route point (cut-splice) | PASS |
| db.16a -- Paste New Before (route-object anchor) | PASS |
| db.16b -- Paste New After (route-object anchor) | PASS |
| db.17 -- Paste New Before (group-object anchor) | PASS |
| db.18 -- Paste New Before (branch-object anchor) | PASS |
| db.19a -- Paste New Before (route clipboard, WP anchor) | PASS |
| db.19b -- Paste New Before (group clipboard, WP anchor) | PASS |
| db.35 -- PASTE waypoint at DB route object (D3: REF append) | PASS |
| db.37 -- Pure route_point COPY+PASTE_BEFORE at route_point anchor (D1 carve-out) | PASS |
| db.38 -- COPY DB timed track -> PASTE_NEW_AFTER preserves per-point timestamps | PASS |
| db.G1 -- Delete Group+WPS blocked (members in route) | PASS |
| db.G2 -- DEL_WAYPOINT blocked (WP in route) | PASS |
| db.G3 -- DB-copy track to DB destination blocked | PASS |
| db.G4 -- Recursive paste guard (branch into own descendant) | PASS |
| db.G5 -- Menu shape: PASTE at DB WP object node blocked | PASS |
| db.G6 -- Menu shape: PASTE_NEW at DB WP object node blocked | PASS |
| db.G7 -- Menu shape: PASTE at DB track object node blocked | PASS |
| db.G8 -- Mixed clipboard PASTE_BEFORE at route_point | PASS |
| db.G9 -- Mixed clipboard PASTE_NEW_BEFORE at route_point | PASS |
| db.G10 -- COPY WP -> PASTE blocked (DB-to-DB waypoint copy) | PASS |
| db.G11 -- COPY group -> PASTE blocked (DB-to-DB group copy) | PASS |
| db.G12 -- COPY route -> PASTE blocked (DB-to-DB route copy) | PASS |
| db.G13 -- COPY branch -> PASTE blocked (DB-to-DB branch copy) | PASS |
| db.G14 -- COPY track -> PASTE_BEFORE blocked | PASS |
| db.G15 -- COPY track -> PASTE_AFTER blocked | PASS |
| db.G16 -- NEW_WAYPOINT at non-collection target blocked | PASS |
| db.G17 -- NEW_ROUTE at non-collection target blocked | PASS |
| db.G18 -- PASTE_BEFORE at route_point with non-WP clipboard blocked | PASS |
| db.G19 -- COPY route_point, PASTE at collection blocked (D2) | PASS |
| **e80** | |
| e80.1 -- Paste WP to E80 (UUID-preserving) | PASS |
| e80.2 -- Paste Group to E80 (UUID-preserving) | PASS |
| e80.3 -- Paste Route to E80 (UUID-preserving) | PASS |
| e80.4 -- Copy E80 WP, Push to DB | PASS |
| e80.5 -- Copy E80 WP, Paste New to DB (fresh UUID) | PASS |
| e80.6 -- Delete E80 WP (specific node) | PASS |
| e80.7 -- Delete via E80 Routes header | PASS |
| e80.8 -- Delete via E80 Groups header | PASS |
| e80.9a -- Re-upload Popa group | PASS |
| e80.9b -- Delete E80 Group + members via specific group node | PASS |
| e80.10a -- Ensure at least one ungrouped WP on E80 | PASS |
| e80.10b -- Delete via E80 My Waypoints (all ungrouped) | PASS |
| e80.11a -- Re-upload Popa group | PASS |
| e80.11b -- Copy E80 Group, Push to DB | PASS |
| e80.12a -- Re-upload TestRoute | PASS |
| e80.12b -- Copy E80 Route, Push to DB | PASS |
| e80.13 -- Multi-select Group + Route, Push to DB | PASS |
| e80.14 -- Paste New WP to E80 (fresh UUID) | PASS |
| e80.14b -- Copy E80 fresh-UUID WP, Paste to DB | PASS |
| e80.14c -- Mixed-classified E80 clipboard, PASTE_NEW | PASS |
| e80.15 -- Paste New Group to E80 (all-fresh UUIDs) | PASS |
| e80.16a -- Ensure E80 routes empty | PASS |
| e80.16b -- Paste New Route to E80 | PASS |
| e80.17 -- Multi-select WPs, Paste to E80 | PASS |
| e80.18 -- Route point Paste Before/After on E80 | PASS |
| e80.20a -- Delete BarillasMarina from E80 if present | PASS |
| e80.20b -- Delete Mexico~99 from E80 if present | PASS |
| e80.21a -- Delete all E80 routes | PASS |
| e80.21b -- Delete all E80 groups+WPS | PASS |
| e80.21c -- Delete all E80 ungrouped WPs (no-op path) | PASS |
| e80.22 -- Ancestor-wins accept path | PASS |
| e80.25a -- Upload IsolatedWP1 to E80 | PASS |
| e80.26 -- UUID conflict clean-create path | PASS |
| e80.27 -- UUID conflict dialog path | NOT_RUN (db_versioning) |
| e80.28a -- Ensure IsolatedWP1 on E80 | PASS |
| e80.G1 -- Delete E80 Group+WPS blocked (member in route) | PASS |
| e80.G2 -- DB-cut to E80 destination blocked | PASS |
| e80.G3 -- Intra-batch post-truncation WP collision | PASS |
| e80.G4 -- Vs-spoke post-truncation WP collision | PASS |
| e80.G5 -- Route-dependency pre-flight | PASS |
| e80.G6 -- Ancestor-wins reject path | PASS |
| e80.G7 -- Intra-clipboard name collision | PASS |
| e80.G8 -- E80-wide name collision | PASS |
| e80.G9 -- PASTE at E80 WP object node blocked | PASS |
| e80.G10 -- PASTE_NEW at E80 WP object node blocked | PASS |
| e80.G11 -- DELETE_GROUP at E80 my_waypoints node blocked | PASS |
| e80.G12 -- DELETE_GROUP_WPS mixed my_waypoints + named group blocked | PASS |
| e80.G13 -- D6: WP paste at E80 routes header blocked | PASS |
| e80.G14 -- D6: Group paste at E80 my_waypoints blocked | PASS |
| e80.G15 -- D6: Route paste at E80 groups header blocked | PASS |
| e80.G16 -- D6: Group paste at E80 named-group node blocked | PASS |
| **tracks** | |
| tracks.1a -- record E80Track1 | PASS |
| tracks.1b -- record E80Track2 | PASS |
| tracks.2 -- Copy E80Track1, Paste to DB | PASS |
| tracks.3 -- Copy E80Track1, Paste New to DB (fresh UUID) | PASS |
| tracks.4 -- Cut E80Track2, Paste to DB | PASS |
| tracks.5 -- PASTE single DB track -> E80 tracks header | PASS |
| tracks.6 -- PASTE multi DB tracks -> E80 tracks header | PASS |
| tracks.7 -- PASTE_NEW single DB track -> E80 (fresh navMate UUID) | PASS |
| tracks.8 -- PASTE_NEW multi DB tracks -> E80 | PASS |
| tracks.9 -- PASTE single FSH track -> E80 (cross-spoke) | PASS |
| tracks.10 -- PUSH E80 track -> DB (natural color drift) | PASS |
| tracks.11 -- Multi-COPY from E80 -> PASTE to DB | PASS |
| tracks.12 -- Multi-CUT from E80 -> PASTE to DB | PASS |
| tracks.13 -- DELETE via E80 Tracks header | PASS |
| tracks.14a -- timed recording decodes per-point ts AND injected depth | PASS |
| tracks.14b -- stock recording stays stock | PASS |
| tracks.15 -- DB->E80->DB round-trip on real Cat32 (per-point ts survival) | PASS |
| tracks.G1 -- PASTE track at non-tracks-header E80 destination | PASS |
| tracks.G2 -- Lossy-warn (name truncation + color drift) on track paste | PASS |
| tracks.G3 -- uuid-collision preflight on spoke -> DB record-creating paste | PASS |
| tracks.G4a -- force_timed=1 fires depth_degraded, NOT ts_dropped | PASS |
| tracks.G4b -- force_timed=0 fires ts_dropped, NOT depth_degraded | PASS |
| **fsh** | |
| fsh.1 -- Paste WP to FSH (UUID-preserving) | PASS |
| fsh.2 -- Paste Group to FSH (UUID-preserving) | PASS |
| fsh.3 -- Paste Route to FSH (UUID-preserving) | PASS |
| fsh.4 -- Paste Track to FSH (UUID-preserving) -- FSH-unique | PASS |
| fsh.5 -- Copy FSH WP, Push to DB | PASS |
| fsh.6 -- Copy FSH Group, Push to DB | PASS |
| fsh.7 -- Copy FSH Route, Push to DB | PASS |
| fsh.8 -- Multi-select Group + Route, Push to DB | PASS |
| fsh.9 -- Copy FSH WP, Paste New to DB (fresh UUID) | PASS |
| fsh.10 -- Cut FSH WP, Paste to DB (UUID preserved) | PASS |
| fsh.11a -- Delete FSH WP (success) | PASS |
| fsh.11b -- Delete FSH Group (dissolve) | PASS |
| fsh.13 -- Delete via FSH Routes header | PASS |
| fsh.14 -- Delete via FSH Groups header | PASS |
| fsh.15a -- Re-upload Popa group to FSH | PASS |
| fsh.15b -- Delete FSH Group + members via specific group node | PASS |
| fsh.16a -- Re-upload IsolatedWP1 to FSH | PASS |
| fsh.16b -- Delete via FSH My Waypoints (all ungrouped) | PASS |
| fsh.17a -- Re-upload Popa group | PASS |
| fsh.17b -- Re-upload TestRoute | PASS |
| fsh.18 -- Paste New WP to FSH (fresh UUID) | PASS |
| fsh.19 -- Paste New Group to FSH (all-fresh UUIDs) | PASS |
| fsh.20 -- Paste New Route to FSH (fresh route UUID, members reused) | PASS |
| fsh.21 -- Multi-select WPs, Paste to FSH | PASS |
| fsh.22 -- Route point Paste Before/After on FSH | PASS |
| fsh.23 -- Cut FSH Track, Paste to DB (UUID preserved) | PASS |
| fsh.24 -- Copy FSH Track, Paste New to DB (fresh navMate UUID) | PASS |
| fsh.25 -- Delete FSH Track (specific node) | PASS |
| fsh.26 -- Delete via FSH Tracks header | PASS |
| fsh.28 -- Lossy-transform pre-flight (db_to_fsh long-name warning) | PASS |
| fsh.30a -- Upload IsolatedWP1 to FSH | PASS |
| fsh.31 -- UUID conflict clean-create path | PASS |
| fsh.32a -- Ensure IsolatedWP1 on FSH | PASS |
| fsh.40 -- Timed-track DB->FSH->DB round-trip on real Cat32 (headless) | PASS |
| fsh.G1 -- Delete FSH Group+WPS blocked (members in route) | PASS |
| fsh.G2 -- DB-cut to FSH destination blocked | PASS |
| fsh.G3 -- Intra-clipboard name collision | PASS |
| fsh.G4 -- FSH-wide name collision | PASS |
| fsh.G5 -- PASTE at FSH WP object node blocked | PASS |
| fsh.G6 -- PASTE_NEW at FSH WP object node blocked | PASS |
| fsh.G7 -- D6: WP paste at FSH routes header blocked | PASS |
| fsh.G8 -- D6: Group paste at FSH my_waypoints blocked | PASS |
| fsh.G9 -- D6: Route paste at FSH groups header blocked | PASS |
| fsh.G10 -- D6: Group paste at FSH named-group node blocked | PASS |
| fsh.G11 -- Intra-batch post-truncation WP collision on FSH destination | PASS |
| fsh.G12a -- force_timed=1 fires depth_degraded, NOT ts_dropped | PASS |
| fsh.G12b -- force_timed=0 fires ts_dropped, NOT depth_degraded | PASS |
| **hub** | |
| hub.1 -- Paste FSH WP -> E80 (UUID-preserving) | PASS |
| hub.2 -- Paste FSH Group -> E80 (UUID-preserving) | PASS |
| hub.3 -- Paste FSH Route -> E80 (UUID-preserving) | PASS |
| hub.5 -- Paste E80 WP -> FSH (same UUID) | PASS |
| hub.6 -- Paste E80 Group -> FSH (same UUID) | PASS |
| hub.7 -- Paste E80 Route -> FSH (same UUID) | PASS |
| hub.8 -- Paste-New E80 WP -> FSH (name-collision block) | PASS |
| hub.9 -- Paste-New FSH WP -> E80 (fresh navMate UUID) | PASS |
| hub.10 -- Paste-New E80 Group -> FSH (name-collision block) | PASS |
| hub.11 -- Paste-New FSH Route -> E80 (name-collision block) | PASS |
| hub.12 -- Cut E80 WP, Paste to FSH | PASS |
| hub.13 -- Cut FSH WP, Paste to E80 | PASS |
| hub.14 -- Cut E80 Group, Paste to FSH | PASS |
| hub.15 -- Cut FSH Group (79 members), Paste to E80 | PASS |
| hub.16 -- Push E80 WP -> FSH (cmd 10251) | PASS |
| hub.17 -- Push FSH WP -> E80 (cmd 10252) | PASS |
| hub.18 -- Push E80 Group -> FSH (multi-WP update) | PASS |
| hub.19 -- Push FSH Route -> E80 | PASS |
| hub.20 -- E80->FSH->E80 WP round-trip (hop 2 name-collision block) | PASS |
| hub.21 -- FSH->E80->FSH Group round-trip (hop 2 name-collision block) | PASS |
| hub.22 -- Multi-select 2 E80 WPs, Paste to FSH | PASS |
| hub.25 -- UUID-conflict in-place-update probe | PASS |
| hub.28 -- Route paste cross-spoke with missing member WPs | PASS |
| hub.G1 -- Heterogeneous clipboard (Group + Route) blocked (D6) | PASS |
| hub.G2 -- Name collision destination-side | NOT_RUN (no-silent-rename policy) |
| hub.G3 -- Intra-clipboard name collision | PASS |
| hub.G4 -- Descendant-of-clipboard / paste-at-WP-node | PASS |

---

## Issues

No numbered test FAIL / PARTIAL / PASSED_BUT this cycle. Four operational observations
(none failed a numbered test):

### E80 baseline blocker at the e80-module reset (teensyBoat route-mode temp waypoint)

At the e80-module inter-module reset, `clear_e80` could not reach an empty E80: one waypoint
"Waypoint PA04" (`80b237ad0f000038`) survived both `clear_e80` and a direct `DELETE_WAYPOINT`,
reappearing within milliseconds each time (continuous `get_item` + `WARNING: enquing mod(0)` loop
on that one UUID). Diagnosis: teensyBoat was in route mode and its routine generates a temporary
active waypoint, which the navigating plotter continuously re-broadcasts onto the E80 -- so navMate
deleted it and the boat re-created it faster than the clear could finish. The db-module reset
earlier reached a fully clean E80, so this began mid-run when the boat entered route mode.
Resolved by the operator re-initializing teensyBoat (`I` command) to stop routing; the temp
waypoint then cleared and the e80 reset completed clean. This is an environment condition (new
this cycle: first run with a live boat in route mode during the cycle), not a navMate defect. New
with the slave E80-4 on the LAN: no cross-display sync anomaly was observed -- the master E80-2's
data was authoritative throughout, and `clear_e80` / all e80 + hub operations behaved exactly as
in prior single-plotter cycles.

### Inter-module reset modal hang (fsh module reset)

At the fsh-module inter-module reset (following the heavy tracks-module E80 + track activity), the
wx idle loop was blocked by a hung modal (`dialog_state: active` in log): the `[DST]`
`create_branch` dispatch never processed and navTestDST was absent after two attempts.
`cmd=close_dialog` rescued it cleanly (`dialog_state: idle` after). The queued create attempts then
all processed at once, leaving TWO `navTestDST` branches; the extra (empty) one was deleted so
exactly one `[DST]` remained, and the fsh module ran fully clean. This is the same symptom as the
`clear_e80_progress_hang` open memo (recurs at inter-module resets after heavy E80/track activity),
recorded also in cycle 30. It occurred in the reset phase, not a numbered test, and was
non-destructive after the rescue.

### tracks.12 -- TRACK OUT OF BAND lines during multi-CUT

tracks.12 logged two `ERROR - TRACK OUT OF BAND seq(33) expected(34)` lines (from `b_sock.pm`) for
the two cut track UUIDs. These are on the master_runbook Known-Quiet Warnings list (normal protocol
noise during track transfer). The data outcome was exactly correct (E80 -2, both UUIDs landed in DB,
`extra(erase)` for both, PASTE FINISHED), so per the known-quiet policy this is not a failure.
Recorded for transparency.

### tracks.G2 -- runbook expected-name literal casing typo (not a defect)

The pasted track "2006-01-11-SanDiego2DanaPoint" truncates to "2006-01-11-SanD" (15 chars, capital
D preserved from "SanDiego"). The runbook's stated expected literal "2006-01-11-Sand" has a
lowercase-d typo; the actual (correct) 15-char truncation is "2006-01-11-SanD". Both required
lossy-warn lines (name truncation + color approximation) fired and the track landed at 15 chars, so
the test PASSES on its substantive criteria. Runbook prose could be corrected to "2006-01-11-SanD".
