# reflash Module -- Runbook

Execution-layer steps for the reflash module (mod003 timed-track **phase b**).  For shared toolbox see [`../master_runbook.md`](../master_runbook.md); for module scope and rationale see [`plan.md`](plan.md); for UUID lookup see [`../uuid_index.md`](../uuid_index.md).

**STANDALONE.**  Run by hand; NOT part of the recurring full cycle.  Runs against ANY connected E80 because the writes it exercises are firmware-INDEPENDENT (the E80 stores a track point's depth/temp as a dumb store regardless of firmware).  The result is annotated by the firmware it ran against:
- **modified (mod003, v5.73+):** validates the module mechanics + write-safety on a modded unit.  Largely overlaps `tracks.15` (which already writes Cat32 to the live unit and round-trips it), so it adds confidence but no unique coverage.
- **bare-stock (non-mod003):** the genuinely-novel scenario -- a firmware that does NOT understand the overloaded bytes.  This is the do-once worth running after a deliberate reflash; it is the module's unique value.

---

## Baseline Setup + Firmware Pre-Check

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+reflash+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 6
# clear_e80 ProgressDialog can hang intermittently (known bug) -- check + rescue
curl.exe -s "http://localhost:9883/api/command?cmd=dialog_state" | Out-Null; Start-Sleep 1
$dlg = (curl.exe -s "http://localhost:9883/api/log?tail=10" | ConvertFrom-Json).lines | Where-Object { $_.text -match 'dialog_state' } | Select-Object -Last 1
if ($dlg.text -match 'active') { "clear_e80 dialog HUNG -- rescuing"; curl.exe -s "http://localhost:9883/api/command?cmd=close_dialog" | Out-Null; Start-Sleep 2 }
curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null   # force-timed write

# firmware pre-check: run against any connected unit; annotate the firmware variant
$info = curl.exe -s "http://localhost:9883/api/timed_tracks?cmd=get" | ConvertFrom-Json
if (-not $info.connected) {
    "reflash: NOT_RUN (no E80 connected)"
    return
}
$variant = if ([double]$info.version -ge 5.73) { "MODIFIED (mod003, v$($info.version)) -- mechanics + write-safety; overlaps tracks.15" }
           else { "BARE-STOCK (non-mod003, v$($info.version)) -- the unique do-once scenario" }
"reflash: proceeding against $variant"
```

If no E80 is connected the module records `NOT_RUN (no E80 connected)`.  Otherwise it runs; record which firmware variant it ran against in the cycle results.

---

## Tests

### Test 1 -- Write-safety: timed write to a bare-stock E80 does not boot-loop

```powershell
$CAT = "65b3888535b54913"   # [TIMED_CAT32] -- real 500-pt timed track, varied ts
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+reflash.1" | Out-Null

# PASTE the timed track to the bare-stock E80 tracks header (force_timed already pinned)
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$CAT&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 20

# The SAVED ack + the track landing (name truncates to 15 on the E80 -> '2005-10-09-Cat3')
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match 'SAVED ok|got track|TRACK_CHANGED' } | ForEach-Object { $_.text }
$onE80 = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties |
    Where-Object { $_.Value.name -like '2005-10-09-Cat*' }).Count
"Cat32 on E80: $onE80 (expect 1)"

# CRITICAL liveness check: the unit must still answer after the value-extreme timed write.
Start-Sleep 3
$alive = curl.exe -s "http://localhost:9883/api/timed_tracks?cmd=get" | ConvertFrom-Json
"unit still responsive: connected=$($alive.connected) version=$($alive.version)"
```

**Pass:** the writer-session logs `d_TRACK_writer SAVED ok` + a `TRACK_CHANGED` event + a `got track(...)` line; the Cat32 track is present in `/api/db`; PASTE STARTED/FINISHED + ProgressDialog auto-FINISHED; and the post-write liveness probe shows the unit STILL connected and answering (`connected=1`, a version returned).  A unit that stopped responding, a ProgressDialog that hung, or a missing SAVED ack is a FAIL -- the timed write may have corrupted a record.  **If the unit boot-loops, beep and stop the module (catastrophic).**

---

### Test 2 -- Round-trip fidelity off bare stock

```powershell
$CAT = "65b3888535b54913"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+reflash.2" | Out-Null
# COPY the timed track from the bare-stock E80, PASTE_NEW to DB (fresh uuid)
$e80uuid = @((curl.exe -s "http://localhost:9883/api/db" | ConvertFrom-Json).tracks.PSObject.Properties |
    Where-Object { $_.Value.name -like '2005-10-09-Cat*' })[0].Name
curl.exe -s "http://localhost:9883/api/test?panel=e80&select=$e80uuid&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=6f4e72ceae0264de&right_click=6f4e72ceae0264de&cmd=10211" | Out-Null
Start-Sleep 15

# The round-tripped row is the PASTE_NEW result, homed under [DST] (6f4e72ceae0264de).
$rt  = @((curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).tracks |
    Where-Object { $_.name -like '2005-10-09-Cat*' -and $_.collection_uuid -eq '6f4e72ceae0264de' })[0]
$pts = curl.exe -s "http://localhost:9883/api/track_points?uuid=$($rt.uuid)" | ConvertFrom-Json
$n      = @($pts.points).Count
$withts = @($pts.points | Where-Object { [double]$_.ts -ge 315532800 }).Count
"round-trip: points=$n with-ts=$withts first.ts=$($pts.points[0].ts) last.ts=$($pts.points[-1].ts)"
```

**Pass:** the round-tripped DB row has 500 points, all with `ts >= 315532800`, `first.ts = 1128888553` and `last.ts = 1128912810` (preserved EXACTLY and in order off the bare-stock unit).  This proves the bare-stock E80 stored and returned the overloaded bytes faithfully -- the dumb-store property the whole hub<->spoke contract depends on.  (Depth is not asserted -- Cat32 carries none; the depth path is covered by tracks.14a.)

---

End of reflash module tests.
