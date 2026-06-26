# tracks Module -- Runbook

Execution-layer steps for the tracks module.  For shared toolbox see [`../master_runbook.md`](../master_runbook.md); for module scope and test inventory see [`plan.md`](plan.md); for UUID lookup see [`../uuid_index.md`](../uuid_index.md).

---

## Baseline Setup + Pre-Check

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+tracks+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5
curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 2

# Pin both mod003 knobs (the timed-track hazard guard).
# (a) WRITE preference -> default force-timed, so the encode tests start from a known mode.
curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null
# (b) DEVICE recorder -> STOCK, so an unpinned timed recorder cannot silently make tracks.1
#     record timed and shift the data under tracks.2-13.  Best-effort: on a non-mod003 unit
#     this returns {error:...} and is a harmless no-op (stock always records stock) -- do NOT
#     fail the module on it.
$pin = curl.exe -s "http://localhost:9883/api/timed_tracks?cmd=set&enabled=0" | ConvertFrom-Json
if ($pin.error) { "device-toggle pin skipped (non-mod003 unit): $($pin.error)" } else { "device recorder pinned to stock (v$($pin.version))" }

# teensyBoat pre-check
$tb = try { curl.exe -s "http://localhost:9881/api/command?cmd=SIM" | ConvertFrom-Json } catch { $null }
if (-not ($tb -and $tb.ok)) {
    "teensyBoat NOT available -- module records as NOT_RUN (teensyBoat unavailable)"
    return
}
"teensyBoat is running -- proceed"
```

If teensyBoat is unavailable, mark all tracks tests `NOT_RUN (teensyBoat unavailable)` and stop the module.

---

## Positive Tests

### Test 1 -- Create two test tracks on E80 (E80Track1, E80Track2)

Two separate recordings.  Each gets its own fresh E80 uuid -- the second exists to give tracks.4 a fresh uuid for the CUT+PASTE record-creating positive, since tracks.2/3 contaminate the first track's uuid in DB.

#### tracks.1a -- record E80Track1

```powershell
curl.exe -s "http://localhost:9881/api/command?cmd=AP%3D0" | Out-Null   # autopilot off
Start-Sleep 1
curl.exe -s "http://localhost:9881/api/command?cmd=H%3D90" | Out-Null   # heading East
Start-Sleep 1
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D50" | Out-Null   # 50 knots
Start-Sleep 2

# Verify motion
$seq = (curl.exe -s "http://localhost:9881/api/log?tail=1" | ConvertFrom-Json).seq
curl.exe -s "http://localhost:9881/api/command?cmd=SIM" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9881/api/log?since=$seq" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "^SIM" } | ForEach-Object { $_.text }

# Mark log and start recording the first track
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.1+E80Track1+record" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=t+start"
```

Drive a 3-leg triangle (~30s) as a background task, wait for `ALL_LEGS_DONE`:

```bash
echo "L1-start" && sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D210" > /dev/null && \
echo "L2-start" && sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D330" > /dev/null && \
echo "L3-start" && sleep 10 && echo "ALL_LEGS_DONE"
```

Then stop, name as E80Track1, save:

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=t+stop"
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/command?cmd=t+name+E80Track1"
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/command?cmd=t+save"
Start-Sleep 4
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match "got track" } | ForEach-Object { $_.text }
```

#### tracks.1b -- record E80Track2

Second recording, different geometry so the two tracks are distinguishable.  Each `t+save` produces a new E80 uuid; record both before any DB interaction so neither uuid is contaminated by paste.

```powershell
curl.exe -s "http://localhost:9881/api/command?cmd=H%3D45" | Out-Null     # heading NE
Start-Sleep 1
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D50" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.1+E80Track2+record" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=t+start"
```

Two-leg short triangle (~20s):

```bash
echo "L1-start" && sleep 10 && curl.exe -s "http://localhost:9881/api/command?cmd=H%3D225" > /dev/null && \
echo "L2-start" && sleep 10 && echo "ALL_LEGS_DONE"
```

Stop, name, save:

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=t+stop"
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/command?cmd=t+name+E80Track2"
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/command?cmd=t+save"
Start-Sleep 4

# Park simulator
curl.exe -s "http://localhost:9881/api/command?cmd=S%3D0"

# Capture both uuids
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$db.tracks.PSObject.Properties | ForEach-Object { "$($_.Name) -> $($_.Value.name)" }
```

**NEVER use `STOP`** -- that halts the simulator entirely; `S=0` (URL-encoded `S%3D0`) zeroes speed only.

Note `[E80_TK1]` and `[E80_TK2]` from `/api/db` tracks (the two tracks present after both saves).

**Pass:** `/api/db` tracks contains exactly 2 tracks named "E80Track1" and "E80Track2"; both UUIDs have byte 1 = `B2` (E80-assigned).  Track-record protocol warnings are documented known-quiet (see `../master_runbook.md`).

---

### Test 2 -- Copy E80Track1, Paste to DB

```powershell
$E80_TK1 = "<from-tracks.1a>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK1&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 5
```

**Pass:** E80Track1 appears in `/api/nmdb` tracks with UUID = `$E80_TK1` (preserved); E80Track1 still on E80; PASTE STARTED/FINISHED.

---

### Test 3 -- Copy E80Track1, Paste New to DB (fresh UUID)

```powershell
$E80_TK1 = "<from-tracks.1a>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK1&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 5
```

**Pass:** new E80Track1 record in `/api/nmdb` tracks with a fresh navMate UUID (byte 1 = `0x4e`, NOT `$E80_TK1`); E80Track1 still on E80 (COPY not CUT); DB now has 2 records for the recorded track.

---

### Test 4 -- Cut E80Track2, Paste to DB

Uses `[E80_TK2]` from tracks.1b -- a fresh E80 uuid that is NOT yet in the DB.  This isolates the CUT+PASTE record-creating positive from the uuid-collision case (where the source uuid is already in DB; see tracks.G3).

```powershell
$E80_TK2 = "<from-tracks.1b>"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$E80_TK2&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 6
```

**Pass:** E80Track2 absent from `/api/db` (E80-side erased by CUT); `/api/nmdb` tracks contains a new row at UUID = `$E80_TK2` named "E80Track2" (preserved E80 uuid; record creation); log shows `queueTRACKCommand(...) extra(erase)` for `$E80_TK2`.  PASTE STARTED/FINISHED.  End state: E80 still has E80Track1 (unchanged), DB has 3 rows total (E80Track1@`$E80_TK1`, E80Track1@fresh-navMate, E80Track2@`$E80_TK2`).

---

### Test 5 -- PASTE single DB track -> E80 tracks header

Uses `[DB_TRACK_SHORT] = 8a4e3c4a2201fac2` ("BOCAS1-001", 77 pts, palette-snap color).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 8

$tk = (curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks
@($tk.PSObject.Properties).Count
$tk."8a4e3c4a2201fac2".name
```

**Pass:** the pasted BOCAS1-001 lands on E80 as a new track at mta_uuid `8a4e3c4a2201fac2`, name = "BOCAS1-001".  (E80 total tracks = 2 here: BOCAS1-001 plus the E80Track1 still on E80 from tracks.1 -- tracks.4 only CUT E80Track2, so E80Track1 lingers; the old "count = 1" assertion predates that lingering track and is wrong.)  Log shows `d_TRACK_writer SAVED ok` (the SAVED ack), a `TRACK_CHANGED` event, and `got track(8a4e3c4a2201fac2) = 'BOCAS1-001'`.  PASTE (e80) STARTED/FINISHED + ProgressDialog 'Paste Tracks' STARTED/FINISHED.

---

### Test 6 -- PASTE multi DB tracks -> E80 tracks header

Uses `[DB_TRACK_MULTI_B/C] = 664e93a624018e26`, `694e27fe26016702` ("BOCAS1-002/003", 74+55 pts).  Two-track batch; `[DB_TRACK_MULTI_A]` (BOCAS1-001) is excluded because tracks.5 already pasted it to E80, and `_pasteAllToE80` rejects a batch that contains any uuid already present on E80 (with `use PASTE_NEW instead` sentinel).  Multi-select is a single call with comma-separated uuids (`navTest.pm` line 11 documents this form; chaining N single-select calls each REPLACES the prior selection, so only the last reaches PASTE -- that's a runbook bug, not a code bug).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=664e93a624018e26,694e27fe26016702&cmd=10200" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 20

@((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties).Count
```

**Pass:** `/api/db` tracks now contains BOCAS1-002@`664e93a624018e26` and BOCAS1-003@`694e27fe26016702` alongside the BOCAS1-001@`8a4e3c4a2201fac2` from tracks.5 (E80 count goes 1 -> 3 plus E80Track1 from Section 1 = 4 total).  Both new tracks have mta_uuid preserved from DB.  PASTE STARTED/FINISHED + ProgressDialog STARTED/FINISHED.

---

### Test 7 -- PASTE_NEW single DB track -> E80 (fresh navMate UUID)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10211" | Out-Null
Start-Sleep 8
```

**Pass:** new E80 track present with FRESH navMate UUID (byte 1 = `0x4e`, NOT `8a4e3c4a2201fac2`); name = "BOCAS1-001"; DB unchanged.  PASTE_NEW STARTED/FINISHED.  Note: under suppressed UX, the PASTE_NEW confirmation dialog is auto-accepted.

---

### Test 8 -- PASTE_NEW multi DB tracks -> E80

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2,664e93a624018e26,694e27fe26016702&cmd=10200" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10211" | Out-Null
Start-Sleep 25
```

**Pass:** three new tracks on E80 with FRESH navMate UUIDs (all byte 1 = `0x4e`); names = "BOCAS1-001", "BOCAS1-002", "BOCAS1-003"; DB unchanged.

---

### Test 9 -- PASTE single FSH track -> E80 (cross-spoke)

Uses `[FSH_TRACK_BOCAS1_003] = 0E4E-0BEA-B407-584A` ("BOCAS1-003", 74 pts, color=0).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=0E4E-0BEA-B407-584A&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 8
```

**Pass:** new E80 track with mta_uuid converted from FSH form `0E4E-0BEA-B407-584A` to navMate form `0e4e0beab407584a` (preserved through fshToNavUUID); name = "BOCAS1-003"; FSH state unchanged; log shows TRACK_CHANGED event and SAVED ack.

---

### Test 10 -- PUSH E80 track -> DB (exercises natural color drift)

PUSH from E80 syncs name/color from the live E80 state to the existing DB row.  No out-of-band modify step is needed: tracks.5's PASTE of `[DB_TRACK_SHORT]` (`BOCAS1-001`) introduced a real diff because the DB color (`ffff6666`, non-palette) was snapped to the nearest E80 palette index at the wire seam.  PUSH back to DB therefore lands a different color than the DB row originally held -- this is the diff the test exercises.

Setup uses the track from tracks.5 (same UUID `8a4e3c4a2201fac2` on both sides).

```powershell
# Capture DB color BEFORE push -- should be ffff6666 (the original, non-palette)
$db_before = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$row_before = $db_before.tracks | Where-Object { $_.uuid -eq '8a4e3c4a2201fac2' }
$color_before = $row_before.color

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=8a4e3c4a2201fac2&right_click=8a4e3c4a2201fac2&cmd=10250" | Out-Null
Start-Sleep 5

# Capture DB color AFTER push -- should be a palette ABGR (one of the 6 exact values), not ffff6666
$db_after = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$row_after = $db_after.tracks | Where-Object { $_.uuid -eq '8a4e3c4a2201fac2' }
Write-Host "DB color: before=$color_before after=$($row_after.color)"
```

**Pass:** PUSH STARTED/FINISHED; DB row's `color` field changed from `ffff6666` to a palette-exact ABGR (one of `ff0000ff`, `ff00ff00`, `ffff0000`, `ff00ffff`, `ffff00ff`, `ff000000`); name unchanged ("BOCAS1-001" was already <= 15 chars); `modified_ts` updated.  Points NOT touched (immutable on E80).  Confirms the wire path runs AND that the diff actually syncs.

---

### Test 11 -- Multi-COPY from E80 -> PASTE to DB

Source uuids: any three E80 uuids that are NOT yet in DB.  The uuid-collision preflight added 2026-05-29 rejects record-creating spoke->DB paste at an already-existing uuid (use PUSH for that), so this positive test must pick uncontaminated source uuids.  The fresh-navMate-uuid tracks from tracks.7/.8 fit (byte 1 = `4e` and DB has no row at those uuids).

```powershell
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$nmdb_uuids = @{}
foreach ($u in @($nmdb.tracks | ForEach-Object { $_.uuid })) { $nmdb_uuids[$u] = 1 }
$db    = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$fresh = @($db.tracks.PSObject.Properties | Where-Object { -not $nmdb_uuids[$_.Name] } | ForEach-Object { $_.Name })
"E80 uuids NOT in DB: $($fresh -join ', ')"
$picked = @($fresh | Select-Object -First 3)
"Picked: $($picked -join ', ')"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.11" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$($picked -join ',')&cmd=10200" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 15
```

**Pass:** `/api/nmdb` tracks now contains rows at all three picked uuids (preserved through PASTE); E80 unchanged (COPY not CUT); PASTE STARTED/FINISHED.  If `$fresh` has fewer than 3 elements at runtime, the test records NOT_RUN (state setup precondition unmet).

---

### Test 12 -- Multi-CUT from E80 -> PASTE to DB

Same uuid-collision constraint as tracks.11 -- pick E80 uuids that are NOT yet in DB.  After tracks.11 those fresh uuids ARE now in DB (tracks.11 pasted them), so this test re-derives the set fresh.

```powershell
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$nmdb_uuids = @{}
foreach ($u in @($nmdb.tracks | ForEach-Object { $_.uuid })) { $nmdb_uuids[$u] = 1 }
$db    = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
$fresh = @($db.tracks.PSObject.Properties | Where-Object { -not $nmdb_uuids[$_.Name] } | ForEach-Object { $_.Name })
"E80 uuids NOT in DB: $($fresh -join ', ')"
$picked = @($fresh | Select-Object -First 2)
"Picked: $($picked -join ', ')"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.12" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$($picked -join ',')&cmd=10201" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 15
```

**Pass:** E80 tracks count decreased by 2 (the CUT items removed); `/api/nmdb` tracks contains new rows at the 2 picked uuids (record creation, preserved E80 uuid); CUT STARTED/FINISHED + PASTE STARTED/FINISHED; log shows `extra(erase)` for both picked uuids.  If `$fresh` has fewer than 2 elements at runtime, the test records NOT_RUN.

---

### Test 13 -- DELETE via E80 Tracks header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.13" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10225" | Out-Null
Start-Sleep 8
```

**Pass:** `/api/db` tracks empty; DELETE TRACK STARTED/FINISHED; ProgressDialog auto-FINISHED.  See `clear_e80_progress_hang` open-bug memo if dialog hangs at 0/N.

---

---

## Section 4 -- Timed tracks (mod003)

E80-spoke coverage of the mod003 timed-track data path.  Starts from the empty E80 left by tracks.13.  See `plan.md` Section 4 and `../../docs/timed_tracks.md`.

The timed DB fixture is the REAL baseline track `[TIMED_CAT32]` (`2005-10-09-Cat32MissionBayToSanDiegoBay`, uuid `65b3888535b54913`, 500 pts, `ts_source=gdb`, per-point timestamps that VARY 1128888553..1128912810 -- so a point-reorder bug is catchable).  **Depth coverage lives HERE only:** no saved track in the DB carries depth, so depth is exercised by RECORDING with a teensyBoat-injected depth (`d=<feet>`) in tracks.14a -- the one place real per-point depth is achievable.

### Test 14 -- Device-toggle recording decode (timed+depth / stock)

**Firmware sub-gate:** timed recording needs a mod003 v5.73+ unit.  Also needs teensyBoat (already required by the module).

```powershell
$info = curl.exe -s "http://localhost:9883/api/timed_tracks?cmd=get" | ConvertFrom-Json
if (-not $info.connected -or [double]$info.version -lt 5.73) {
    "tracks.14: NOT_RUN (firmware precondition) -- connected=$($info.connected) version=$($info.version)"
    return
}
```

#### tracks.14a -- timed recording decodes per-point ts AND injected depth

Inject a known depth via teensyBoat so the mod003 recorder stamps real depth into each timed point.  `d=25` = 25 ft; the firmware stores depth as 0.1 ft, which decodes back to ~`762` cm (25 ft * 30.48).

```powershell
curl.exe -s "http://localhost:9881/api/command?cmd=d%3D25" | Out-Null              # teensyBoat depth = 25 ft
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/timed_tracks?cmd=set&enabled=1" | Out-Null   # recorder -> timed
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.14a+timed" | Out-Null
```

Record a short track named **TimedRec** using the tracks.1 idiom (`t start` -> drive one ~10s leg via teensyBoat -> `t stop` -> `t name TimedRec` -> `t save`; park the sim with `S%3D0`).  Keep `d=25` set for the whole recording.  Then download it and read the decoded points:

```powershell
$rec = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties |
    Where-Object { $_.Value.name -eq 'TimedRec' })[0].Name
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$rec&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 5
$row = @((curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).tracks |
    Where-Object { $_.name -eq 'TimedRec' })[0]
$pts = curl.exe -s "http://localhost:9883/api/track_points?uuid=$($row.uuid)" | ConvertFrom-Json
$n     = @($pts.points).Count
$timed = @($pts.points | Where-Object { [double]$_.ts -ge 315532800 }).Count
$dmin  = (@($pts.points | ForEach-Object { [int]$_.depth_cm }) | Measure-Object -Minimum).Minimum
$dmax  = (@($pts.points | ForEach-Object { [int]$_.depth_cm }) | Measure-Object -Maximum).Maximum
"TimedRec: $timed/$n points carry a decoded ts; depth_cm range $dmin..$dmax (expect ~762 for 25 ft); temp_k=$($pts.points[0].temp_k)"
```

**Pass:** every (or all-but-trailing-sentinel) point has `ts >= 315532800` (the unix time decoded out of the raw depth field, NOT lost into `depth_cm`); `temp_k = 0`; AND `depth_cm` is non-zero and ~762 (the injected 25 ft, proving real recorded depth decodes correctly).  **If `depth_cm` comes back 0**, the teensyBoat `d=` depth did not reach the recorder -- record the ts result as PASS-on-ts and STOP for a decision on the depth path (per the run's stop-at-non-PASS rule); this is the one sub-step whose hardware path is unverified.

#### tracks.14b -- stock recording stays stock

```powershell
curl.exe -s "http://localhost:9883/api/timed_tracks?cmd=set&enabled=0" | Out-Null   # recorder -> stock
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.14b+stock" | Out-Null
```

Record a short track named **StockRec** (same idiom), download it (COPY + PASTE_NEW), read its points:

```powershell
$rec = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties |
    Where-Object { $_.Value.name -eq 'StockRec' })[0].Name
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$rec&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 5
$row = @((curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).tracks |
    Where-Object { $_.name -eq 'StockRec' })[0]
$pts = curl.exe -s "http://localhost:9883/api/track_points?uuid=$($row.uuid)" | ConvertFrom-Json
"StockRec: points with ts>0 = $(@($pts.points | Where-Object { [double]$_.ts -ge 315532800 }).Count) (expect 0)"
```

**Pass:** NO point has `ts >= 315532800`; the points decode as stock (`ts = 0`, `depth_cm` the real cm depth, `temp_k` the real Kelvin*100).  Restore the recorder to stock is already done; the baseline pin holds for any later run.

---

### Test 15 -- DB->E80->DB round-trip on real Cat32 (per-point ts survival)

Writes the real `[TIMED_CAT32]` track to the (dumb-store) E80 as timed bytes, reads it back, and asserts per-point ts survival -- INCLUDING ORDER (the 499 distinct, increasing timestamps catch a point-reorder bug the single-timestamp imports cannot).  Runs on ANY connected E80 (the E80 never interprets a track point's depth/temp).  No depth assertion -- Cat32 carries none; depth is covered by tracks.14a.

The 39-char name truncates to 15 on the E80 (so the round-tripped row reads back as `2005-10-09-Cat3`), and the force-timed write of a 500-pt track emits expected lossy-warns (name truncation + depth_degraded); under `suppress=1` these auto-accept.

```powershell
$CAT = "65b3888535b54913"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.15" | Out-Null
$src = curl.exe -s "http://localhost:9883/api/track_points?uuid=$CAT" | ConvertFrom-Json
$src_n = @($src.points).Count
$src_distinct = (@($src.points | ForEach-Object { $_.ts }) | Sort-Object -Unique).Count
"source Cat32: points=$src_n distinct-ts=$src_distinct first.ts=$($src.points[0].ts) last.ts=$($src.points[-1].ts)"

curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null   # force-timed write
# PASTE Cat32 -> E80 tracks header (500 pts -- allow generous settle)
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$CAT&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 20
# COPY back from E80, PASTE_NEW to DB (fresh uuid; lands under [DST])
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$CAT&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 15

# round-tripped row = a Cat-named track under [DST] (6f4e72ceae0264de), uuid != original
$rt = @((curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).tracks |
    Where-Object { $_.name -like '2005-10-09-Cat*' -and $_.collection_uuid -eq '6f4e72ceae0264de' })[0]
$dst = curl.exe -s "http://localhost:9883/api/track_points?uuid=$($rt.uuid)" | ConvertFrom-Json
$n        = @($dst.points).Count
$withts   = @($dst.points | Where-Object { [double]$_.ts -ge 315532800 }).Count
$distinct = (@($dst.points | ForEach-Object { $_.ts }) | Sort-Object -Unique).Count
"round-trip '$($rt.name)': points=$n  with-ts=$withts  distinct-ts=$distinct  first.ts=$($dst.points[0].ts)  last.ts=$($dst.points[-1].ts)"
```

**Pass:** the round-tripped row has `points = $src_n` (500), `with-ts = 500` (every point still timed), `first.ts = 1128888553` and `last.ts = 1128912810` (endpoints preserved EXACTLY and IN ORDER), and `distinct-ts` matching the source (~499) -- proving per-point timestamps survived the E80 round-trip without loss or reordering.

If `with-ts` < points, or first/last ts are 0 / swapped / shifted, the encode or decode seam regressed.

---

## Guard Tests

### Test G1 -- PASTE track at non-tracks-header E80 destination

```powershell
# Setup: ensure at least one DB track is selected; ensure E80 has at least one
# non-tracks header to target (groups-header is universal).
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** the paste is rejected at preflight with a sentinel naming the D6 spoke content-vs-destination rule (track items only accepted at the E80 tracks header).  `/api/db` tracks count unchanged.  NO ProgressDialog (predicate fires pre-write).

---

### Test G2 -- Lossy-warn (name truncation + color drift) on track paste

Uses `[DB_TRACK_LONG_NONPALETTE] = 824e8a104b04c37c` ("2006-01-11-SanDiego2DanaPoint", 31 chars, 231 pts, color=`ffffff00` non-palette).

Under `suppress=1`, the lossy-warn dialog is auto-accepted.  This test verifies:
- The dialog fires with both `N item(s) will have names truncated to 15 characters` and `M item(s) have colors that cannot round-trip to the destination and will be approximated` lines.
- On accept (auto), `_truncForE80` truncates the name to "2006-01-11-Sand" at the wire seam.
- `abgrToE80Index(ffffff00)` snaps to the nearest palette index (likely 1=yellow).
- The track lands on E80 with the truncated name and the snapped color.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=824e8a104b04c37c&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 15

# Log should show both lossy-warn lines (emitted by lossyTransformWarning
# before the suppress short-circuit; the test-visible prefix is "lossyTransformWarning:").
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines |
    Where-Object { $_.text -match "lossyTransformWarning:" } |
    ForEach-Object { $_.text }
```

**Pass:** the `lossyTransformWarning:` lines INCLUDE one with `1 item(s) will have names truncated to 15 characters` and one with `1 item(s) have colors that cannot round-trip to the destination and will be approximated`; lossy-warn dialog auto-accepts under suppress=1; track lands on E80 with name "2006-01-11-Sand" (15 chars); E80 track color is a palette index 0..5; PASTE STARTED/FINISHED.  If either the name or the color line is missing, that's a regression in `_preflightLossyTransform`.

**Expected third line (mod003):** `[DB_TRACK_LONG_NONPALETTE]` (`2006-01-11-SanDiego2DanaPoint`) is itself a TIMED track (`ts_start=1136955600`, `ts_source=kml_timespan`), so with the baseline `force_timed=1` pin it ALSO co-fires `1 track(s) have centimetre depths that will be quantized to 0.1 ft (written as timed tracks).`  This is expected -- the fixture is timed, so a timed-lossy line is unavoidable (depth_degraded under force_timed=1, or ts_dropped under force_timed=0).  Assert the name + color lines are present; ignore the co-firing timed line.

---

### Test G3 -- uuid-collision preflight on spoke -> DB record-creating paste

Verifies the 2026-05-29 preflight rule: PASTE of a clipboard item whose uuid already exists in the corresponding DB table is rejected with a sentinel naming the rule.  PASTE_NEW is the alternative (fresh-uuid record creation); PUSH is the alternative for "sync into existing-uuid DB row".  Tracks here; the same rule fires for waypoints/groups/routes.

Setup: ensure E80 has a track at a uuid that also exists in DB.  After tracks.5's PASTE, `8a4e3c4a2201fac2` is present on BOTH E80 and DB (preserved-uuid PASTE).  After tracks.13's DELETE TRACK at the tracks-header, E80 is empty; re-establish the shared uuid first.

```powershell
# Setup: PASTE BOCAS1-001 to E80 so the uuid lives on both sides.
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G3+setup" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 8

# Verify setup
$db = curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json
"E80 has BOCAS1-001@8a4e3c4a2201fac2: $($db.tracks.'8a4e3c4a2201fac2'.name)"

# Now the actual guard: COPY from E80, PASTE to DB at the same uuid.
$nmdb_before = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$count_before = @($nmdb_before.tracks).Count

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=8a4e3c4a2201fac2&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10210" | Out-Null
Start-Sleep 5

$nmdb_after = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$count_after = @($nmdb_after.tracks).Count
"nmdb tracks: before=$count_before after=$count_after"

# Log should show the preflight rejection sentinel
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines |
    Where-Object { $_.text -match "Paste rejected|already exist in the database" } |
    ForEach-Object { $_.text }
```

**Pass:** log contains the preflight sentinel `Paste rejected: 1 item(s) already exist in the database at the same uuid.` (with the PUSH/PASTE_NEW guidance line); nmdb tracks count unchanged (no SQL INSERT attempted, so no `UNIQUE constraint failed: tracks.uuid` either); PASTE STARTED line present but FINISHED also present (the predicate returns early; no progress dialog opens for the data side).

---

### Test G4 -- Timed-track lossy-warn matrix on db_to_e80 (preference-conditional)

Verifies the RIGHT timed lossy line fires for each write preference and the other does NOT.  Uses `[TIMED_CAT32]` (`ts_start > 0`, `ts_source='gdb'` != `'e80'`).  Because Cat32's name is 39 chars, the `truncated_names` line co-fires on every paste -- so this asserts the TIMED line is PRESENT/ABSENT, not "exactly one line" (cf. tracks.G2, which also asserts two co-firing categories).  The two timed lines are mutually exclusive (they fork on `force_timed_tracks`), so this is two phases.

```powershell
$CAT = "65b3888535b54913"   # [TIMED_CAT32]
"using TIMED_CAT32 uuid=$CAT"
```

#### tracks.G4a -- force_timed=1 fires depth_degraded, NOT ts_dropped

```powershell
curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G4a+force_timed" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$CAT&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 20
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match 'lossyTransformWarning:' } | ForEach-Object { $_.text }
```

**Pass:** the `lossyTransformWarning:` lines INCLUDE the depth_degraded one -- `1 track(s) have centimetre depths that will be quantized to 0.1 ft (written as timed tracks).` -- and do NOT include any `... DROPPED (stock-track write mode).` line.  (A `... names truncated ...` line co-fires from the 39-char name; that is expected and ignored here.)  Under `suppress=1` the paste proceeds.

#### tracks.G4b -- force_timed=0 fires ts_dropped, NOT depth_degraded

```powershell
curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=0" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+tracks.G4b+stock_write" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$CAT&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 20
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match 'lossyTransformWarning:' } | ForEach-Object { $_.text }

curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null   # restore default
```

**Pass:** the `lossyTransformWarning:` lines INCLUDE the ts_dropped one -- `1 track(s) carry timestamps that will be DROPPED (stock-track write mode).` -- and do NOT include any `... quantized to 0.1 ft ...` line.  (The truncation line still co-fires; ignored.)  The write preference is restored to `1` afterward.

---

End of tracks module tests.
