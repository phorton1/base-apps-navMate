# ocpn Module -- Runbook

Execution-layer steps for the ocpn module. For shared toolbox, see [`../master_runbook.md`](../master_runbook.md). For module scope and test inventory, see [`plan.md`](plan.md). For UUID lookup, see [`../uuid_index.md`](../uuid_index.md).

The ocpn spoke is a **poll-driven HTTP peer**: the real oESeries plugin under real OpenCPN POSTs its inventory to navMate and polls navMate for commands on its own `wxTimer` clock. So steps that depend on the plugin acting are **wait-and-poll**, not single-tick like FSH. This runbook drives the REAL plugin end to end; the only hand-fed inputs are the guard bodies.

## Two servers -- always qualify

- **navMate** -- `http://localhost:9883` -- `/api/ocpn` (`?dump=1` reads the ocdb), `/api/test`, `/api/nmdb`, `/api/command`, `/api/log`.
- **OpenCPN** -- `https://localhost:8443` -- `/api/rx_object` (POST a GPX body to import into the running OpenCPN). Self-signed TLS -> `curl.exe -k`.

## Preconditions (bench setup, once)

1. **OpenCPN + the oESeries plugin installed**, and the plugin configured to POST to navMate at `http://<this-machine>:9883` (the plugin's peer/target setting). Verify with the plugin enabled and navMate running.
2. **Paired API key for OpenCPN's REST.** On first contact OpenCPN shows a 4-digit PIN; the key is `substr(sha256_hex(sprintf("%04d", $pin)), 0, 12)` (oe `pincode.cpp`). Capture it once into `$OcpnApiKey` (below). `force=1` on `/api/rx_object` bypasses the receive-confirm dialog.
3. Paths: navobj.db = `C:\ProgramData\opencpn\navobj.db`; opencpn.exe = `C:\Program Files (x86)\OpenCPN\opencpn.exe`.

## Toolbox

Drop these near the top of an ocpn session.

```powershell
$Nav        = "http://localhost:9883"
$Ocpn       = "https://localhost:8443"
$OcpnApiKey = "88bc475ec984"         # source "navMateTest", PIN 0902 (paired 2026-07-08; OpenCPN persists the key per-source, so re-pair only if its config is reset)
$Navobj     = "C:\ProgramData\opencpn\navobj.db"
$NavobjBak  = "C:\_temp\base-apps-navMate\navobj_backup.db"
$NavobjMark = "C:\_temp\base-apps-navMate\navobj_test.marker"
$OcpnExe    = "C:\Program Files (x86)\OpenCPN\opencpn.exe"
$Seed       = "C:/base/apps/navMate/test/_fixtures/ocpn/seed.gpx"

# Back up the user's real navobj.db and drop a marker, then remove it so OpenCPN
# starts from a fresh empty database. Idempotent: won't overwrite an existing backup.
function Backup-Navobj {
    if (Test-Path $NavobjMark) { Write-Host "marker present -- navobj already backed up"; return }
    if (Test-Path $Navobj) { Copy-Item $Navobj $NavobjBak -Force }
    New-Item -ItemType File $NavobjMark -Force | Out-Null
    if (Test-Path $Navobj) { Remove-Item $Navobj -Force }   # OpenCPN recreates an empty one
    Write-Host "navobj backed up -> $NavobjBak (marker set)"
}

# FAILSAFE: works from any session -- fixed backup path + marker.
function Restore-Navobj {
    if (Test-Path $NavobjBak) { Copy-Item $NavobjBak $Navobj -Force }
    if (Test-Path $NavobjMark) { Remove-Item $NavobjMark -Force }
    Write-Host "navobj restored from $NavobjBak (marker cleared)"
}

function Start-Ocpn { Start-Process $OcpnExe; Start-Sleep 20 }   # let OpenCPN + REST + plugin come up
function Stop-Ocpn  { Get-Process opencpn -ErrorAction SilentlyContinue | Stop-Process -Force }

# Push a GPX file into the running OpenCPN via its REST /api/rx_object.
function Push-OcpnGpx {
    param([string]$path)
    curl.exe -sk -X POST --data-binary "@$path" `
        "$Ocpn/api/rx_object?source=navMateTest&apikey=$OcpnApiKey&force=1"
}

# Wait until navMate's ocdb has been populated by a plugin inventory POST.
function Wait-OcpnInventory {
    param([int]$timeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $d = curl.exe -s "$Nav/api/ocpn?dump=1" | ConvertFrom-Json
        if ($d.marks -and @($d.marks.PSObject.Properties).Count -gt 0) { return $true }
        Start-Sleep 2
    }
    return $false
}
```

---

## Baseline Setup

`op=suppress&val=1` precedes any mutating op (Suppress ordering, master_runbook).

```powershell
# navMate side
git -C C:/dat/Rhapsody checkout -- navMate.db
curl.exe -s "$Nav/api/test?op=refresh"        | Out-Null
curl.exe -s "$Nav/api/test?op=suppress&val=1" | Out-Null
curl.exe -s "$Nav/api/test?op=clear_ocpn"     | Out-Null
curl.exe -s "$Nav/api/command?cmd=mark+ocpn+module+reset" | Out-Null

# OpenCPN side: fresh OpenCPN, seed it, let the plugin POST
Backup-Navobj
Start-Ocpn
Push-OcpnGpx $Seed
if (-not (Wait-OcpnInventory 30)) { Write-Host "FAIL: no plugin inventory POST arrived"; Restore-Navobj; return }

# Verify baseline
$d = curl.exe -s "$Nav/api/ocpn?dump=1" | ConvertFrom-Json
$m = @($d.marks.PSObject.Properties).Count
$r = @($d.routes.PSObject.Properties).Count
$t = @($d.tracks.PSObject.Properties).Count
Write-Host "ocdb baseline: marks=$m routes=$r tracks=$t"
```

## Teardown / FAILSAFE

Always restore at the end of a run (and any time OpenCPN is left in the test state):

```powershell
Stop-Ocpn
Restore-Navobj      # <-- "restore navObjs.db" == this; safe from any session
```

---

## Guard Tests (context-menu preflight rejections via `/api/test`)

Guards drive the navOps preflight REJECTIONS the same way the positives drive navOps -- `/api/test?panel=...&select=...&cmd=...` -- because real right-click/menu interaction can't be orchestrated over the API. They do NOT POST to `/api/ocpn`. Each guard: `mark`, set the clipboard (COPY/CUT the source in the database panel), fire the paste at the WRONG ocpn destination node, then read `/api/log?since=mark` for the rejection message and confirm `navmate_dt` did not advance (nothing enqueued). Needs the ocpn pane populated (seed) + the DB baseline + `suppress=1`. Cmd ids: COPY=10200 CUT=10201 PASTE=10210 PASTE_NEW=10211.

Rejections log as `ERROR - <msg>` (user_error) or `WARNING: IMPLEMENTATION ERROR: <msg>` (impl_error). Pane node keys: `my_waypoints`, `header%3Aroutes`, `header%3Atracks`; a mark = its nav uuid; a route_point = `rp:<route>:<wp>`. DB fixtures used: `[IsolatedWP2]`=864e53b65f033436, Popa route=f34efdd6070022e8 (Popa0=314e56cc09005332), `[TestTrack]`=1a4eed924904ebbe, `[OCPN_NM_MARK]`/BarillasMarina=9e4e10cc5e03093e.

```powershell
# Helper: set clipboard, fire a paste at a wrong ocpn destination, assert rejection + no enqueue
function Guard-Reject {
    param([string]$tag,[scriptblock]$setClip,[string]$sel,[int]$cmd,[string]$expect)
    curl.exe -s "$Nav/api/command?cmd=mark+Test+$tag" | Out-Null
    $dt0 = (curl.exe -s "$Nav/api/ocpn" | ConvertFrom-Json).navmate_dt
    & $setClip; Start-Sleep 1
    curl.exe -s "$Nav/api/test?panel=ocpn&select=$sel&cmd=$cmd" | Out-Null; Start-Sleep 2
    $dt1 = (curl.exe -s "$Nav/api/ocpn" | ConvertFrom-Json).navmate_dt
    $log = curl.exe -s "$Nav/api/log?since=mark" | ConvertFrom-Json
    $rej = $log.lines | Where-Object { $_.text -match [regex]::Escape($expect) }
    Write-Host "$tag : PASS=$([bool]$rej -and ($dt0 -eq $dt1))  (rejected=$([bool]$rej) no_enqueue=$($dt0 -eq $dt1))"
}
$COPY = { param($s) curl.exe -s "$Nav/api/test?panel=database&select=$s&cmd=10200" | Out-Null }

# resolve a live standalone ocpn mark node (non-navMate-origin) for G2/G3
$d = curl.exe -s "$Nav/api/ocpn?dump=1" | ConvertFrom-Json
$OcpnMark = ($d.marks.PSObject.Properties | Where-Object { $_.Value.is_standalone -eq 1 -and $_.Value.name -ne 'BarillasMarina' } | Select-Object -First 1).Name

# G1 -- DB-Cut to OpenCPN blocked (user_error)
Guard-Reject 'ocpn.G1' { curl.exe -s "$Nav/api/test?panel=database&select=864e53b65f033436&cmd=10201" | Out-Null } `
    'my_waypoints' 10210 'Cannot paste a database Cut to OpenCPN'

# G2 -- PASTE at an ocpn mark object node blocked (impl_error, API bypass)
Guard-Reject 'ocpn.G2' { & $COPY '864e53b65f033436' } $OcpnMark 10210 "paste at OpenCPN destination type 'waypoint' not supported"

# G3 -- PASTE_NEW at an ocpn mark object node blocked (same gate)
Guard-Reject 'ocpn.G3' { & $COPY '864e53b65f033436' } $OcpnMark 10211 "paste at OpenCPN destination type 'waypoint' not supported"

# G4 -- D6: WP at ocpn Routes header blocked
Guard-Reject 'ocpn.G4' { & $COPY '864e53b65f033436' } 'header%3Aroutes' 10210 "Cannot paste waypoint clipboard item at ocpn 'header:routes' destination"

# G5 -- D6: Route at ocpn My Waypoints blocked
Guard-Reject 'ocpn.G5' { & $COPY 'f34efdd6070022e8' } 'my_waypoints' 10210 "Cannot paste route clipboard item at ocpn 'my_waypoints' destination"

# G6 -- D6: Track at ocpn Routes header blocked
Guard-Reject 'ocpn.G6' { & $COPY '1a4eed924904ebbe' } 'header%3Aroutes' 10210 "Cannot paste track clipboard item at ocpn 'header:routes' destination"

# G7 -- route_point at ocpn My Waypoints blocked
Guard-Reject 'ocpn.G7' { & $COPY 'rp:f34efdd6070022e8:314e56cc09005332' } 'my_waypoints' 10210 'route_point items can only be pasted at a route, route_point, or database collection destination'

# G8 -- same-uuid collision, ocpn->DB (COPY navMate-origin ocpn mark, PASTE into a DB collection)
curl.exe -s "$Nav/api/command?cmd=mark+g8dst" | Out-Null
curl.exe -s "$Nav/api/test?op=create_branch&name=navTestDST" | Out-Null; Start-Sleep 1
# extract JUST the 16-hex uuid (the log line is 'create_branch ... uuid=<hex> parent=<...>')
$DST = ((curl.exe -s "$Nav/api/log?since=mark" | ConvertFrom-Json).lines |
        Where-Object { $_.text -match 'create_branch .*uuid=([0-9a-f]{16})' } |
        ForEach-Object { $Matches[1] } | Select-Object -First 1)
curl.exe -s "$Nav/api/command?cmd=mark+Test+ocpn.G8" | Out-Null
$before = @((curl.exe -s "$Nav/api/nmdb"|ConvertFrom-Json).waypoints | Where-Object { $_.uuid -eq '9e4e10cc5e03093e' }).Count
curl.exe -s "$Nav/api/test?panel=ocpn&select=9e4e10cc5e03093e&cmd=10200" | Out-Null; Start-Sleep 1   # COPY navMate-origin mark
curl.exe -s "$Nav/api/test?panel=database&select=$DST&cmd=10210" | Out-Null; Start-Sleep 2            # PASTE -> collision
$after = @((curl.exe -s "$Nav/api/nmdb"|ConvertFrom-Json).waypoints | Where-Object { $_.uuid -eq '9e4e10cc5e03093e' }).Count
$rej = (curl.exe -s "$Nav/api/log?since=mark" | ConvertFrom-Json).lines | Where-Object { $_.text -match 'already exist.*same uuid' }
Write-Host "ocpn.G8 : PASS=$([bool]$rej -and ($before -eq $after))  (rejected=$([bool]$rej) no_dup=$($before -eq $after))"
```

A guard PASSES when its rejection message is present AND `navmate_dt` did not advance (G1-G7) / no duplicate DB row appeared (G8).  Note `select=$OcpnMark` (G2/G3) must be a runtime-resolved standalone mark uuid -- foreign uuids re-mint each ingest cycle; resolve from `/api/ocpn?dump=1`.

---

## Positive Tests

The ingest tests (ocpn.1-4) read what the plugin POSTed at baseline. PASTE/push tests (ocpn.5-20) are navMate navOps driven via `/api/test?panel=ocpn&...` (select keys = the runtime nav uuids resolved from `/api/ocpn?dump=1` -- the ocpn pane keys on the nav uuid, NOT the OpenCPN GUID; see `uuid_index.md`), with DB-side effects read from `/api/nmdb`. Foreign objects' navMate uuids are minted, not constant.

> First-bench stabilization: the exact `select=` keys, the plugin's poll latency for outbound steps, and the shared-point import behavior get pinned on the first real run (as every other module was "developed and stabilized" over real cycles, master_plan). The assertions below are fixed; the drive keys are filled in on that pass.

```powershell
# ocpn.1 -- inventory populated; shared point reconciled to ONE uuid
$d = curl.exe -s "$Nav/api/ocpn?dump=1" | ConvertFrom-Json
# assert: marks/routes/tracks counts match the seed; [OCPN_SHARED_PT] appears once,
# and the route's first vertex resolves to that SAME uuid (not a duplicate mark).

# ocpn.2 -- navMate-origin reverses table-free, no mint
# [OCPN_NM_MARK] GUID 9e4e10cc-6e61-4764-8d61-5e03093e7465 -> uuid 9e4e10cc5e03093e;
# assert the dump's uuid for it == 9e4e10cc5e03093e and it has no foreign guid-map entry.

# ocpn.3 -- foreign mint
# [OCPN_HAZARD] GUID 3f2a9c10-7b4e-4d21-9e88-1a2b3c4d5e6f -> a 0x4f uuid + one
# spoke_shadow row; the dump carries the raw icon 'Hazard-Danger'. The icon->sym
# fold (Hazard-Danger -> sym 7) is a DB-side property, verified at PASTE (ocpn.5) --
# /api/ocpn?dump=1 exposes the IconName, not the sym.

# ocpn.5 -- PASTE [OCPN_HAZARD] to DB, verify sym fold + multi-line comment (LF) + shadow
# SELECT key = the RUNTIME nav uuid (resolve from /api/ocpn?dump=1; foreign uuids are
# re-minted each ingest, and the pane keys on the nav uuid, NOT the OpenCPN GUID):
#   $hz = <OcpnHazard nav uuid from the dump>
#   COPY:  "$Nav/api/test?panel=ocpn&select=$hz&cmd=10200"
#   PASTE: "$Nav/api/test?panel=database&select=$DST&cmd=10210"
# /api/nmdb carries only structural fields (uuid,name,collection_uuid,wp_type,sym,color,...)
# -- NOT comment/lat/lon/shadow -- so assert those via a direct read-only query of
# navMate.db: waypoints.sym == 7 (Hazard-Danger fold), comment has an embedded \n (2 lines,
# canonical LF), and spoke_shadow.data (JSON) carries icon_name=Hazard-Danger PLUS the
# full category-B superset (range_rings/scamin/visible/... round-trip on an outbound push).

# ocpn.16 -- cross-spoke chain: [OCPN_HAZARD] -> DB -> E80
# after PASTE to DB, PASTE that DB mark to E80; read the E80 record: sym==7, comment
# FLATTENED to one line (no \n) and truncated at $E80_MAX_COMMENT.
```

(ocpn.4, 6-15, 18-20 follow the same shape -- see `plan.md` for the per-test assertions; the PASTE/push mechanics mirror the `fsh`/`e80` runbooks, substituting `panel=ocpn` and the runtime nav-uuid select keys. ocpn.19 = the option-b navMate-origin B round-trip via PUSH-to-DB; ocpn.G8 = the same-uuid collision gate.)
