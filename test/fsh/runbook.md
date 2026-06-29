# fsh Module -- Runbook

Execution-layer steps for the fsh module. For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For module scope and test inventory, see [`plan.md`](plan.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

FSH is **synchronous**: operations mutate `$navFSH::fsh_db` in-memory and complete in a single wx idle tick. There is no ProgressDialog to wait for. Test sleeps are 1-2s typical (3s when a step might trigger refresh side-effects).

UUIDs: FSH-native form is dashed-uppercase (`9E4E-10CC-5E03-093E`). The `select=` parameter for `panel=fsh` uses this form verbatim. The DB panel and `/api/nmdb` use lowercase-no-dash form (`9e4e10cc5e03093e`). Conversion is purely textual: insert `-` every 4 chars and uppercase (db -> fsh), or strip `-` and lowercase (fsh -> db).

---

## Baseline Setup

Order matters: `op=suppress&val=1` MUST precede `op=load_fsh`. The in-memory FSH may be dirty (Patrick's interactive session or a prior module test run); loading on a dirty FSH raises a `discard / save / save-as / cancel` confirm dialog. With suppress enabled the dialog auto-handles as DISCARD; without it, the dialog blocks the wx idle loop and the test sequence hangs. See `../master_runbook.md` *Suppress ordering*.

```powershell
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "http://localhost:9883/api/test?op=refresh" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+fsh+module+reset" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=clear_e80" | Out-Null
Start-Sleep 5

# Create the empty paste-destination [DST] and capture its runtime uuid into $DST
# (no empty collection exists in the baseline DB). $DST is session-global.
curl.exe -s "http://localhost:9883/api/command?cmd=mark+create+DST" | Out-Null
curl.exe -s "http://localhost:9883/api/test?op=create_branch&name=navTestDST" | Out-Null
$global:DST = ""
$deadline = (Get-Date).AddMilliseconds(5000)
Start-Sleep -Milliseconds 800
while ((Get-Date) -lt $deadline -and -not $global:DST) {
    $log = curl.exe -s "http://localhost:9883/api/log?since=mark"
    if ($log -match "navTest: create_branch 'navTestDST' uuid=([0-9a-f]+)") { $global:DST = $matches[1]; break }
    Start-Sleep -Milliseconds 250
}
if (-not $global:DST) { Write-Host "FAIL: could not create/capture [DST]"; return }
$DST = $global:DST
Write-Host "[DST] = $DST"

curl.exe -s "http://localhost:9883/api/test?op=load_fsh&path=C:/base/apps/navMate/test/_fixtures/test.fsh" | Out-Null
Start-Sleep 3
curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null   # pin mod003 write-pref (fsh.40 / fsh.G12)

# Verify baseline
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$wp_n = @($f.waypoints.PSObject.Properties).Count
$gr_n = @($f.groups.PSObject.Properties).Count
$rt_n = @($f.routes.PSObject.Properties).Count
$tk_n = @($f.tracks.PSObject.Properties).Count
Write-Host "FSH baseline: wp=$wp_n gr=$gr_n rt=$rt_n tk=$tk_n (expect 50 4 3 123)"
```

## UUID Conversion Helpers

Drop these near the top of any session that runs FSH tests:

```powershell
function dbToFsh
{
    param([string]$db_uuid)
    $u = $db_uuid.ToUpper()
    return "$($u.Substring(0,4))-$($u.Substring(4,4))-$($u.Substring(8,4))-$($u.Substring(12,4))"
}
function fshToDb
{
    param([string]$fsh_uuid)
    return ($fsh_uuid -replace '-','').ToLower()
}
```

---

## Positive Tests

### Test 1 -- Paste WP to FSH (UUID-preserving)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` waypoints contains `9E4E-10CC-5E03-093E` named "BarillasMarina"; no `ERROR -` or `IMPLEMENTATION ERROR` in `/api/log?since=mark`. Record `[FSH_WP]` = `9E4E-10CC-5E03-093E`.

---

### Test 2 -- Paste Group to FSH (UUID-preserving)

Uses [GroupInRoute] = Popa (`244e8e100800400a`, 11 members). FSH does not have a Popa group at baseline (4 fixture groups: Michel_Agua, Michel_Sumwood, test, Timiteo).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` groups contains `244E-8E10-0800-400A` named "Popa" with 11 embedded `wpts`. Record `[FSH_GR]` = `244E-8E10-0800-400A`.

---

### Test 3 -- Paste Route to FSH (UUID-preserving)

Members must already be on FSH (test 2 placed them; preflight checks).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` routes contains `F34E-FDD6-0700-22E8` named "Popa" with 11 embedded `wpts`. Record `[FSH_RT]` = `F34E-FDD6-0700-22E8`.

---

### Test 4 -- Paste Track to FSH (UUID-preserving) -- FSH-unique

E80 blocks paste-to-tracks; FSH allows. Uses [TestTrack] (`1a4eed924904ebbe`).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eed924904ebbe&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` tracks contains `1A4E-ED92-4904-EBBE` named "2005-11-25-SanD" (truncated to FSH 15-char name limit; source DB name "2005-11-25-SanDiego2Oceanside"); no ERROR sentinel. Total FSH tracks = 124 (123 fixture + 1 new). Record `[FSH_TK]` = `1A4E-ED92-4904-EBBE`.

---

### Test 5 -- Copy FSH WP, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=9E4E-10CC-5E03-093E&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10250" | Out-Null
Start-Sleep 2
```

**Pass:** PUSH STARTED/FINISHED in log; `/api/nmdb` waypoint `9e4e10cc5e03093e` still has `collection_uuid=bc4e6a005d03cbce` (push does NOT move records); no ERROR.

---

### Test 6 -- Copy FSH Group, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=244E-8E10-0800-400A&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10250" | Out-Null
Start-Sleep 3
```

**Pass:** PUSH STARTED/FINISHED; `/api/nmdb` Popa group `244e8e100800400a` `parent_uuid` unchanged; 11 members still present; no ERROR.

---

### Test 7 -- Copy FSH Route, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=F34E-FDD6-0700-22E8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10250" | Out-Null
Start-Sleep 3
```

**Pass:** PUSH STARTED/FINISHED; Popa route `f34efdd6070022e8` in `/api/nmdb` has 11 route_waypoints; member `wp_uuid` values preserved.

---

### Test 8 -- Multi-select Group + Route, Push to DB

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=244E-8E10-0800-400A,F34E-FDD6-0700-22E8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10250" | Out-Null
Start-Sleep 3
```

**Pass:** log shows `_doCopy: fsh 2 item(s)`; PUSH STARTED/FINISHED; both UUIDs preserved in `/api/nmdb`; no ERROR.

---

### Test 9 -- Copy FSH WP, Paste New to DB (fresh UUID)

Uses [FSH_IsolatedWP1] = `80B2-C48A-5400-D3AE` ("Waypoint 25") from the fixture.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=80B2-C48A-5400-D3AE&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new "Waypoint 25" in `/api/nmdb` waypoints under `collection_uuid=$DST` with a FRESH UUID (NOT `80b2c48a5400d3ae`); byte 1 = `0x4e` (navMate-assigned); FSH-side `80B2-C48A-5400-D3AE` still present.

---

### Test 10 -- Cut FSH WP, Paste to DB (UUID preserved)

Uses [FSH_IsolatedWP2] = `83B2-167D-3F00-ED99` ("Waypoint 10").

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=83B2-167D-3F00-ED99&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/nmdb` waypoint `83b2167d3f00ed99` under `collection_uuid=$DST` (UUID preserved); FSH-side `83B2-167D-3F00-ED99` absent from `/api/fsh` waypoints.

---

### Test 11a -- Delete FSH WP (success)

Uses [FSH_IsolatedWP3] = `83B2-167D-3F00-37D9` ("Waypoint 14"). Top-level, no route ref.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.11a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=83B2-167D-3F00-37D9&right_click=83B2-167D-3F00-37D9&cmd=10220" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` waypoints does NOT contain `83B2-167D-3F00-37D9`; DELETE WAYPOINT STARTED/FINISHED; no ERROR.

---

### Test 11b -- Delete FSH Group (dissolve)

Dissolve cmd=10221 (DELETE_GROUP without WPS). The group shell is removed; embedded member wpts migrate to top-level `my_waypoints` (the implicit FSH ungrouped pool, mirrored as `/api/fsh.waypoints`). Route references to those WP UUIDs are unaffected because FSH routes embed their own wpt records (separate from the group's embedded records). Parallels db.5.

Uses [FSH_GroupAguaRoute] = `C782-7BB6-7A46-4722` (Michel_Agua, 10 members). All 10 are also embedded in the Michel_Agua route -- dissolving the GROUP does NOT touch the route.

```powershell
# Pre-snapshot
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$pre_wp_n  = @($f.waypoints.PSObject.Properties).Count
$pre_grp   = $f.groups.'C782-7BB6-7A46-4722'
$pre_grp_n = if ($pre_grp) { @($pre_grp.wpts).Count } else { 0 }
$pre_rt    = $f.routes.'80B2-C48A-3A00-A1F1'
$pre_rt_n  = if ($pre_rt) { @($pre_rt.wpts).Count } else { 0 }
$members   = if ($pre_grp) { @($pre_grp.wpts | ForEach-Object { $_.uuid }) } else { @() }

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.11b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=C782-7BB6-7A46-4722&right_click=C782-7BB6-7A46-4722&cmd=10221" | Out-Null
Start-Sleep 2

# Post-state verification
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$grp_present  = [bool]$f.groups.'C782-7BB6-7A46-4722'
$post_wp_n    = @($f.waypoints.PSObject.Properties).Count
$post_rt      = $f.routes.'80B2-C48A-3A00-A1F1'
$post_rt_n    = if ($post_rt) { @($post_rt.wpts).Count } else { 0 }
$migrated     = @($members | Where-Object { $f.waypoints.$_ })
Write-Host "Group shell present (expect False): $grp_present"
Write-Host "my_waypoints count: $pre_wp_n -> $post_wp_n (expect +$pre_grp_n)"
Write-Host "Members migrated to my_waypoints: $($migrated.Count) of $pre_grp_n"
Write-Host "Michel_Agua route wpts: $pre_rt_n -> $post_rt_n (expect unchanged)"
```

**Pass:** group shell `C782-7BB6-7A46-4722` absent from `/api/fsh.groups`; all 10 former members now keyed in `/api/fsh.waypoints` (top-level / my_waypoints); the Michel_Agua route's wpt count unchanged; no ERROR.

**Fail:** group still present, OR fewer than 10 members migrated, OR the route lost wpts (would indicate dissolve incorrectly cascaded to routes), OR an IMPLEMENTATION ERROR fired.

---

### Test 13 -- Delete via FSH Routes header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.13" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223" | Out-Null
Start-Sleep 3
```

**Pass:** `/api/fsh` routes is empty `{}`; groups + their embedded members still present; no ERROR.

---

### Test 14 -- Delete via FSH Groups header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.14" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10222" | Out-Null
Start-Sleep 4
```

**Pass:** `/api/fsh` groups is empty `{}`; all groups gone with their embedded members (4 at this point: the 3 fixture groups still present after fsh.11b dissolved Michel_Agua -- Michel_Sumwood, test, Timiteo -- plus Popa from test 2; the old "5 groups" count predates the fsh.11b dissolve); top-level isolated WPs preserved; tracks unchanged.

---

### Test 15a -- Re-upload Popa group to FSH

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.15a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** Popa group `244E-8E10-0800-400A` on FSH with 11 embedded members.

---

### Test 15b -- Delete FSH Group + members via specific group node

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.15b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=244E-8E10-0800-400A&right_click=244E-8E10-0800-400A&cmd=10222" | Out-Null
Start-Sleep 2
```

**Pass:** group `244E-8E10-0800-400A` absent from `/api/fsh`; all 11 members absent (members were embedded; gone with the group); no ERROR.

---

### Test 16a -- Re-upload IsolatedWP1 to FSH

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.16a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `9E4E-10CC-5E03-093E` present in `/api/fsh` waypoints.

---

### Test 16b -- Delete via FSH My Waypoints (all ungrouped)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.16b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10222" | Out-Null
Start-Sleep 3
```

**Pass:** `/api/fsh` waypoints is empty `{}` (or near-empty -- the 50 fixture WPs + the one we re-uploaded in 16a, minus any consumed by earlier tests, should all be gone); no ERROR.

---

### Test 17a -- Re-upload Popa group (setup for paste-new tests)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.17a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** Popa group on FSH with 11 members.

---

### Test 17b -- Re-upload TestRoute

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.17b" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** Popa route on FSH with 11 wpts.

---

### Test 18 -- Paste New WP to FSH (fresh UUID)

Uses [IsolatedWP2] from DB (`864e53b65f033436`, Mexico~99).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.18" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=864e53b65f033436&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new "Mexico~99" on `/api/fsh` waypoints with a FRESH FSH UUID (NOT `864E-53B6-5F03-3436`); DB record `864e53b65f033436` unchanged.

---

### Test 19 -- Paste New Group to FSH (all-fresh UUIDs)

Uses [TestGroup] = Timiteo (`1a4eaf5a8c00e922`, 6 members) from DB. The FSH fixture's Timiteo (`C482-CBA0-D14E-67B2`) was removed in test 14; this PASTE_NEW creates a fresh-UUID Timiteo on FSH.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.19" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=1a4eaf5a8c00e922&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10211" | Out-Null
Start-Sleep 3
```

**Pass:** new Timiteo group on FSH with a fresh FSH UUID (NOT `1A4E-AF5A-8C00-E922` and NOT `C482-CBA0-D14E-67B2`); 6 members each with fresh FSH UUIDs.

---

### Test 20 -- Paste New Route to FSH (fresh route UUID, member WP UUIDs reused)

Pre-cleanup: delete the existing Popa route on FSH if present (test 17b's upload) so the paste-new produces a distinct fresh route.

```powershell
# Pre-cleanup
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.20+precleanup" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10223" | Out-Null
Start-Sleep 3

# Actual test
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.20" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new "Popa" route on FSH with FRESH route UUID (NOT `F34E-FDD6-0700-22E8`); 11 embedded wpts; member WP UUIDs reused from existing FSH-side Popa group members (i.e. they match `244E-8E10-0800-400A` group members, not fresh).

---

### Test 21 -- Multi-select WPs, Paste to FSH

Uses [IsolatedWP1] + [IsolatedWP3] from DB. Pre-cleanup: ensure neither is on FSH (test 16b cleared my_waypoints).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.21" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e,f54e595460034e6e&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** log shows `_doCopy: database 2 item(s)`; both `9E4E-10CC-5E03-093E` and `F54E-5954-6003-4E6E` on `/api/fsh` waypoints with UUIDs preserved.

---

### Test 22 -- Route point Paste Before/After on FSH

Identify the fresh-UUID Popa route from test 20.

```powershell
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$FSH_RT_FRESH = ($f.routes.PSObject.Properties | Where-Object { $_.Value.name -eq "Popa" -and $_.Name -ne "F34E-FDD6-0700-22E8" } | Select-Object -First 1).Name
$rt = $f.routes.$FSH_RT_FRESH
$RP1 = $rt.wpts[0].uuid
$RP3 = $rt.wpts[2].uuid

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.22" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=rp:${FSH_RT_FRESH}:${RP1}&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=rp:${FSH_RT_FRESH}:${RP3}&right_click=rp:${FSH_RT_FRESH}:${RP3}&cmd=10212" | Out-Null
Start-Sleep 2
```

**Pass:** route's wpts count increases by 1; PASTE BEFORE STARTED/FINISHED; the RP1 wp_uuid now appears between the position previously occupied by RP3 and its predecessor.

---

### Test 23 -- Cut FSH Track, Paste to DB (UUID preserved)

Uses [FSH_TestTrack] = `A24E-672E-FE06-0A80` (Track2-006). Note: test 4 added a 124th track (the DB-imported 1A4E-ED92...), but tests 17a/17b/etc shouldn't have consumed tracks. Track headers haven't been touched yet.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.23" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=A24E-672E-FE06-0A80&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/nmdb` tracks contains `a24e672efe060a80` (FSH UUID converted to DB form); FSH `A24E-672E-FE06-0A80` absent from `/api/fsh`; no ERROR.

---

### Test 24 -- Copy FSH Track, Paste New to DB (fresh navMate UUID)

Uses [FSH_TestTrack2] -- pick a different track. Use `7F4E-B4C6-9607-CF02` ("BOCAS2-010").

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.24" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=7F4E-B4C6-9607-CF02&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** new track in `/api/nmdb` tracks with FRESH navMate UUID (NOT `7f4eb4c69607cf02`); FSH-side `7F4E-B4C6-9607-CF02` still present.

---

### Test 25 -- Delete FSH Track (specific node)

Use `634E-295C-1E07-D5F0` (SANBLAS3-002).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.25" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=634E-295C-1E07-D5F0&right_click=634E-295C-1E07-D5F0&cmd=10225" | Out-Null
Start-Sleep 2
```

**Pass:** `/api/fsh` tracks does NOT contain `634E-295C-1E07-D5F0`; DELETE TRACK STARTED/FINISHED; no ERROR.

---

### Test 26 -- Delete via FSH Tracks header

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.26" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Atracks&right_click=header%3Atracks&cmd=10225" | Out-Null
Start-Sleep 5
```

**Pass:** `/api/fsh` tracks is empty `{}`; DELETE TRACK STARTED/FINISHED; no ERROR.

---

### Test 28 -- Lossy-transform pre-flight (db_to_fsh long-name warning)

Setup: find or create a DB WP whose name length > 15 chars. Find a candidate via `/api/nmdb`.

```powershell
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$long = $nmdb.waypoints | Where-Object { $_.name.Length -gt 15 } | Select-Object -First 1
if (-not $long) { Write-Host "NOT_RUN: no DB WP with name > 15 chars"; return }
$LongWP = $long.uuid
Write-Host "LongWP $LongWP name='$($long.name)' length=$($long.name.Length)"

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.28" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$LongWP&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING:` line in log naming the truncation (e.g. `WARNING: navOps: name truncated for FSH ...` or analogous); PASTE proceeds to completion (lossy-transform is a warning, not a block); FSH-side WP has name truncated to 15 chars.

---

### Test 30a -- Upload IsolatedWP1 to FSH (setup for 30b)

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.30a" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `9E4E-10CC-5E03-093E` (BarillasMarina) on FSH.

---

### Test 31 -- UUID conflict clean-create path

Pre-cleanup: delete any pre-existing Mexico~99 records on FSH (test 18 may have left a fresh-UUID Mexico~99) so the paste-with-preserved-UUID lands without name collision.

```powershell
# Pre-cleanup: delete any FSH-side Mexico~99 records
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$bocas2s = @($f.waypoints.PSObject.Properties | Where-Object { $_.Value.name -eq "Mexico~99" })
foreach ($b in $bocas2s) {
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.31+precleanup" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=$($b.Name)&right_click=$($b.Name)&cmd=10220" | Out-Null
    Start-Sleep 1
}

# Actual test
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.31" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=864e53b65f033436&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `864E-53B6-5F03-3436` (Mexico~99) on FSH with UUID preserved; no conflict-resolution dialog text in log (clean-create path -- no UUID conflict because Mexico~99's FSH UUID didn't exist on FSH yet).

---

### Test 32a -- Ensure IsolatedWP1 on FSH (precondition for 32b/c)

Asserts that `9E4E-10CC-5E03-093E` is on FSH. If already present (e.g., from a prior test), PASS. If absent, paste it; PASS if the paste lands, FAIL if it doesn't.

```powershell
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
if (-not ($f.waypoints.PSObject.Properties.Name -contains "9E4E-10CC-5E03-093E"))
{
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.32a" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e&cmd=10200" | Out-Null
    Start-Sleep 1
    curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
    Start-Sleep 2
    $f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
}
```

**Pass:** `9E4E-10CC-5E03-093E` on FSH after the step, regardless of whether the paste was needed or skipped. **Fail:** WP still absent (paste failed).

---

### Test 40 -- Timed-track DB->FSH->DB round-trip on real Cat32 (headless)

The FSH-spoke twin of tracks.15 -- firmware-free and hardware-free, entirely in-memory.  COPYs the real `[TIMED_CAT32]` (uuid `65b3888535b54913`, 500 pts, varied ts) to the FSH tracks header under `force_timed=1` (FSH encode writes timed points into `$navFSH::fsh_db`), then COPYs the FSH track back and PASTE_NEWs it to DB (FSH->DB decode), asserting per-point ts survival incl. order.  This is the load-bearing FSH->DB decode regression -- the seam that previously stored the unix ts into `depth_cm`.

```powershell
$CAT = "65b3888535b54913"
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.40" | Out-Null
$src = curl.exe -s "http://localhost:9883/api/track_points?uuid=$CAT" | ConvertFrom-Json
$src_n = @($src.points).Count
$src_distinct = (@($src.points | ForEach-Object { $_.ts }) | Sort-Object -Unique).Count
"source Cat32: points=$src_n distinct-ts=$src_distinct first.ts=$($src.points[0].ts) last.ts=$($src.points[-1].ts)"
curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null

# DB -> FSH (encode): COPY Cat32, PASTE to FSH tracks header (uuid preserved -> FSH form; name truncates to 15)
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$CAT&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 3
$fsh_uuid = dbToFsh $CAT
"FSH now has timed track: $((curl.exe -s 'http://localhost:9883/api/fsh' | ConvertFrom-Json).tracks.$fsh_uuid.name) @ $fsh_uuid"

# FSH -> DB (decode): COPY FSH track, PASTE_NEW to DB (fresh uuid; lands under [DST])
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=$fsh_uuid&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10211" | Out-Null
Start-Sleep 2

$rt = @((curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json).tracks |
    Where-Object { $_.name -like '2005-10-09-Cat*' -and $_.collection_uuid -eq $DST })[0]
$dst = curl.exe -s "http://localhost:9883/api/track_points?uuid=$($rt.uuid)" | ConvertFrom-Json
$n        = @($dst.points).Count
$withts   = @($dst.points | Where-Object { [double]$_.ts -ge 315532800 }).Count
$distinct = (@($dst.points | ForEach-Object { $_.ts }) | Sort-Object -Unique).Count
"round-trip '$($rt.name)': points=$n with-ts=$withts distinct-ts=$distinct first.ts=$($dst.points[0].ts) last.ts=$($dst.points[-1].ts)"
```

**Pass:** the round-tripped DB row has 500 points, all with `ts >= 315532800`, `first.ts = 1128888553` and `last.ts = 1128912810` (endpoints exact and IN ORDER), and `distinct-ts` matching the source (~499) -- per-point timestamps survived the FSH round-trip intact.  `with-ts` < points, or a ~1.7e9 `depth_cm`, means the FSH encode or decode seam regressed.

---

## Guard Tests

### Test G1 -- Delete FSH Group+WPS blocked (members in route) [was fsh.12]

The old runbook used the fixture Timiteo group `C482-CBA0-D14E-67B2`, but fsh.14 (Delete via
FSH Groups header) deletes ALL groups including that fixture Timiteo, and fsh.13 deletes all
routes -- so by guard time the fixture Timiteo group + its route no longer exist and the
precondition is **orphaned** (the guard dispatched against a missing node, selecting 0 nodes).

Use instead the group-with-members-in-route that the positives leave standing: the Popa group
`244E-8E10-0800-400A` (re-uploaded at fsh.17a) whose 11 members are all referenced by the fresh
Popa route created at fsh.20 (fsh.20 reused the Popa group member UUIDs). Deleting that group +
WPs is blocked because its members are in a route.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G1" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=244E-8E10-0800-400A&right_click=244E-8E10-0800-400A&cmd=10222" | Out-Null
Start-Sleep 2
```

**Pass:** `ERROR - Cannot delete FSH group 'Popa' and its waypoints: one or more members are referenced by routes. Use Delete Group to dissolve without deleting members, or remove from routes first.`; no IMPL ERROR; Popa group + 11 members + the fresh Popa route still in `/api/fsh`.

---

### Test G2 -- DB-cut to FSH destination blocked [was fsh.27]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G2" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e&cmd=10201" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `ERROR - Cannot paste a database Cut to FSH` (or analogous sentinel); `/api/nmdb` waypoint `9e4e10cc5e03093e` still has its original `collection_uuid` (cut clipboard not consumed).

---

### Test G3 -- Intra-clipboard name collision [was fsh.29]

Find two DB WPs with the same name.

```powershell
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$dups = $nmdb.waypoints | Group-Object name | Where-Object { $_.Count -ge 2 } | Select-Object -First 1
$WP_A = $dups.Group[0].uuid
$WP_B = $dups.Group[1].uuid

curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G3" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$WP_A,$WP_B&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** ERROR sentinel `FSH operation blocked: N name collision(s):` with an `intra-clipboard waypoint name '<name>'` entry naming the colliding source items, followed by `Per policy, navMate does not auto-rename.  Resolve in the database and retry.`; no IMPL ERROR; no WP named `<name>` lands on FSH.

---

### Test G4 -- FSH-wide name collision [was fsh.30b]

Precondition: a second BarillasMarina must exist in DB with UUID != `9e4e10cc5e03093e`. The fixture DB has only one BarillasMarina, so the precondition is established by PASTE_NEW of [IsolatedWP1] into [DST] (mints a fresh-UUID BarillasMarina in DB). If the precondition already holds (a prior test created a second BarillasMarina), no setup is needed.

```powershell
# Ensure a second BarillasMarina exists in DB (precondition)
$nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
$second = $nmdb.waypoints | Where-Object { $_.name -eq "BarillasMarina" -and $_.uuid -ne "9e4e10cc5e03093e" } | Select-Object -First 1
if (-not $second)
{
    curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G4+precond" | Out-Null
    curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e&cmd=10200" | Out-Null
    Start-Sleep 1
    curl.exe -s "http://localhost:9883/api/test?panel=database&select=$DST&right_click=$DST&cmd=10211" | Out-Null
    Start-Sleep 2
    $nmdb = curl.exe -s "http://localhost:9883/api/nmdb" | ConvertFrom-Json
    $second = $nmdb.waypoints | Where-Object { $_.name -eq "BarillasMarina" -and $_.uuid -ne "9e4e10cc5e03093e" } | Select-Object -First 1
    if (-not $second) { Write-Host "fsh.30b FAIL: could not establish precondition (no second BarillasMarina)"; return }
}
$SameNameWP = $second.uuid

# Actual test: paste the second BarillasMarina to FSH; expect name-collision sentinel
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G4" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$SameNameWP&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** ERROR sentinel `FSH operation blocked: 1 name collision(s):` with a `waypoint 'BarillasMarina' (from waypoint 'BarillasMarina') already on FSH at UUID <existing>` entry, followed by `Per policy, navMate does not auto-rename.  Resolve in the database and retry.`; no IMPL ERROR; only one BarillasMarina on FSH (`9E4E-10CC-5E03-093E`, the original from fsh.30a). **Fail:** precondition could not be established, OR the sentinel did not fire, OR a second BarillasMarina landed on FSH.

---

### Test G5 -- PASTE at FSH WP object node blocked [was fsh.32b]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G5" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=9E4E-10CC-5E03-093E&right_click=9E4E-10CC-5E03-093E&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: paste at FSH destination type 'waypoint' not supported` (D4 positive-list rejection); FSH unchanged.

---

### Test G6 -- PASTE_NEW at FSH WP object node blocked [was fsh.32c]

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G6" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=9E4E-10CC-5E03-093E&right_click=9E4E-10CC-5E03-093E&cmd=10211" | Out-Null
Start-Sleep 2
```

**Pass:** same D4 IMPL ERROR sentinel; FSH unchanged.

---

### Test G7 -- D6: WP paste at FSH routes header blocked [was fsh.33]

D6 (spoke content-vs-destination) rejects waypoint clipboard items at the FSH routes header -- only route items are accepted at `header:routes`.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G7" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=9e4e10cc5e03093e&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Aroutes&right_click=header%3Aroutes&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: Cannot paste waypoint clipboard item at fsh 'header:routes' destination`; FSH unchanged.

---

### Test G8 -- D6: Group paste at FSH my_waypoints blocked [was fsh.34]

D6 rejects group clipboard items at the FSH my_waypoints pseudo-group -- only waypoint items are accepted there. Spokes do not support nested groups.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G8" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: Cannot paste group clipboard item at fsh 'my_waypoints' destination`; FSH unchanged.

---

### Test G9 -- D6: Route paste at FSH groups header blocked [was fsh.35]

D6 rejects route clipboard items at the FSH groups header -- only group items are accepted at `header:groups`.

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G9" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=f34efdd6070022e8&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Agroups&right_click=header%3Agroups&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: Cannot paste route clipboard item at fsh 'header:groups' destination`; FSH unchanged.

---

### Test G10 -- D6: Group paste at FSH named-group node blocked [was fsh.36]

D6 rejects group clipboard items at a named-group destination -- only waypoint items are accepted at a group node. Spokes do not support nested groups.

Uses DB Popa group (`244e8e100800400a`) as the clipboard group and a named group **present on FSH**
as the destination node. The old runbook used the fixture Timiteo `C482-CBA0-D14E-67B2`, but fsh.14
deletes all groups -- that node is orphaned by guard time (same gap as fsh.G1). Query a present
group dynamically (the fresh Timiteo from fsh.19 or the Popa group from fsh.17a).

```powershell
$f = curl.exe -s "http://localhost:9883/api/fsh" | ConvertFrom-Json
$destGrp = @($f.groups.PSObject.Properties)[0].Name   # any present named group on FSH
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G10" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=244e8e100800400a&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=$destGrp&right_click=$destGrp&cmd=10210" | Out-Null
Start-Sleep 2
```

**Pass:** `WARNING: IMPLEMENTATION ERROR: Cannot paste group clipboard item at fsh 'group' destination`; FSH unchanged.

---

### Test G11 -- Intra-batch post-truncation WP collision on FSH destination [was fsh.37]

Parallels e80.36 -- the same post-truncation comparison in `_collectNameConflicts` runs for `panel='fsh'` destinations (FSH shares the 15-char name limit with E80 per `fsh_name_comment_limits`).  Two DB WPs `BajaCalifornia~1` (`7b4e6d421403dc72`) and `BajaCalifornia~2` (`044e7e7017030a9e`) have distinct full names but both truncate to `BajaCalifornia~` (15 chars).

```powershell
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G11" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=7b4e6d421403dc72,044e7e7017030a9e&cmd=10200" | Out-Null
Start-Sleep 2
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=my_waypoints&right_click=my_waypoints&cmd=10210" | Out-Null
Start-Sleep 3
```

**Pass:** preflight aborts with the sentinel `ERROR - FSH operation blocked: N name collision(s):` followed by an `intra-clipboard waypoint name '...': waypoint 'BajaCalifornia~1' vs waypoint 'BajaCalifornia~2'` line and `Per policy, navMate does not auto-rename.  Resolve in the database and retry.`  The sentinel names the two distinct *source* WPs (their full names differ -- they can ONLY collide after truncation to `BajaCalifornia~`, so the block itself proves the post-truncation comparison fired; the message does not display the bare truncated key, and that is fine).  FSH waypoints count unchanged; NO write to in-memory `$navFSH::fsh_db`.

---

### Test G12 -- Timed-track lossy-warn matrix on db_to_fsh (preference-conditional)

The FSH twin of tracks.G4: proves `_preflightLossyTransform` fires the timed lossy lines identically for the `db_to_fsh` direction.  Uses `[TIMED_CAT32]` (uuid `65b3888535b54913`, `ts_source='gdb'` != `'e80'`).  Its 39-char name co-fires a `truncated_names` line (FSH shares the 15-char limit), so this asserts the timed line's presence/absence, not "exactly one line".  Two mutually-exclusive phases.

```powershell
$CAT = "65b3888535b54913"   # [TIMED_CAT32]
"using TIMED_CAT32 uuid=$CAT"
```

#### fsh.G12a -- force_timed=1 fires depth_degraded, NOT ts_dropped

```powershell
curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G12a+force_timed" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$CAT&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 3
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match 'lossyTransformWarning:' } | ForEach-Object { $_.text }
```

**Pass:** the `lossyTransformWarning:` lines INCLUDE `1 track(s) have centimetre depths that will be quantized to 0.1 ft (written as timed tracks).` and do NOT include any `... DROPPED ...` line.  (A `... names truncated ...` line co-fires from the 39-char name; expected, ignored.)  Under `suppress=1` the paste proceeds.

#### fsh.G12b -- force_timed=0 fires ts_dropped, NOT depth_degraded

```powershell
curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=0" | Out-Null
curl.exe -s "http://localhost:9883/api/command?cmd=mark+Test+fsh.G12b+stock_write" | Out-Null
curl.exe -s "http://localhost:9883/api/test?panel=database&select=$CAT&cmd=10200" | Out-Null
Start-Sleep 1
curl.exe -s "http://localhost:9883/api/test?panel=fsh&select=header%3Atracks&right_click=header%3Atracks&cmd=10210" | Out-Null
Start-Sleep 3
curl.exe -s "http://localhost:9883/api/log?since=mark" | ConvertFrom-Json |
    Select-Object -Expand lines | Where-Object { $_.text -match 'lossyTransformWarning:' } | ForEach-Object { $_.text }

curl.exe -s "http://localhost:9883/api/force_timed_tracks?cmd=set&val=1" | Out-Null   # restore default
```

**Pass:** the `lossyTransformWarning:` lines INCLUDE `1 track(s) carry timestamps that will be DROPPED (stock-track write mode).` and do NOT include any `... quantized to 0.1 ft ...` line.  (Truncation line co-fires; ignored.)  The write preference is restored to `1` afterward.

---

End of fsh module tests.
