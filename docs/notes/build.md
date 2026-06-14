# navMate Build / Packaging Cookbook

How to build the installable, Perl-free Windows distribution of navMate -- the
procedure and the configuration that make it work. This is a reference, not a
history. Internal dev doc: not wired into the docs nav headers.


## Toolchain

- **Cava Packager 2.0** (build 2.0.80.263) -- GUI at
  `C:\Program Files (x86)\Cava Packager 2.0\bin\cavapackager.exe`. Single-instance.
  Scans a Perl/wxPerl app and bundles a private ActivePerl 5.12 (perl512.dll) plus
  wxWidgets 3.0 into Windows exe(s). Abandonware; the `.cpkgproj` project file is a
  SQLite database. The build is a **GUI operation** (Distribution -> Scan and Build
  Project) -- `cavaconsole.exe` is a runtime diagnostic console, NOT a headless builder.
- **Inno Setup 5.5.9** -- `C:\Program Files (x86)\Inno Setup 5\ISCC.exe` -- compiles the
  generated `innosetup.iss` into the user-facing installer exe.
- **Dev Perl: `C:\Perl`** (ActivePerl 5.12.4) -- the SAME version Cava bundles, so every
  XS module that works in dev is ABI-compatible with the packaged build.


## Project layout (`C:\base_dist\navMate`)

A separate git repo (private; on GitHub as `base_dist-navMate`), `USES /base/apps/navMate`.

- `cava20.cpkgproj` -- the project config, a SQLite database. Readable, diffable, and
  (with Cava CLOSED) writable directly via DBD::SQLite.
- **Tracked files** (per `.gitignore`, which ignores everything and re-includes by
  exception): `.gitignore`, `cava20.cpkgproj`, and `cava20/msw/installer.config` (the
  installer-tab Storable hash -- re-included so `doinstaller` / `pre_installer_script` /
  `require_privileges` / `program_group` are not lost to the `*` rule). Everything else
  (`cava20/`, `cava20-temp/`, `cava20-logs/`, `installer/`, `release/`, the built exes) is
  regenerable by a Scan-and-Build and is intentionally untracked, so the repo stays lean
  and binary-free.
- **Lesson:** add the `.gitignore` BEFORE the first commit -- `.gitignore` cannot evict
  files that are already tracked.


## The three executables

navMate packages as THREE exec targets from the one `.cpkgproj`, each its own exe + icon:

| Exe             | exec_type        | Manifest               | Script                  | Icon              | Role                                   |
| --------------- | ---------------- | ---------------------- | ----------------------- | ----------------- | -------------------------------------- |
| `navMate.exe`   | 2 (console+GUI)  | asInvoker (default)    | `navMate.pm`            | grey anchor       | console-bearing dev / diagnostic shape |
| `navMateGUI.exe`| 1 (console-less) | asInvoker (default)    | `navMate.pm`            | blue anchor       | the GUI-only user shape                |
| `netWizard.exe` | 1 (console-less) | requireAdministrator   | `_netWizard/netWizard.pm`| green bolt+anchor | the elevated E-Series network wizard   |

- **Icon convention:** blue = GUI, grey = console; the wizard is a green lightning bolt
  striking an anchor. The `.ico` files live at `apps/navMate/_res/site/` (`navMate*.ico`,
  `netWizard.ico`).
- **Cava `manifest_exec_level`:** 1 = asInvoker, 2 = highestAvailable, 3 =
  requireAdministrator. The wizard needs **3** (it runs `netsh` to set the adapter IP).
- **Icons are INTERNALIZED by Cava** -- the tracked config stores only a filename pointing
  into Cava's iconresource store, so each exe's icon must be set via the Cava GUI icon
  field (one click) pointing at the `.ico`. SQL alone cannot wire it.


## Scan configuration (`@INC` / module packing)

- **`extrapaths`** (`local_config_values`):
  `C:/base;C:/base/apps/navMate;C:/base/apps/navMate/_netWizard`
  - `C:/base` -- resolves `Pub::` and `Pub::Ray::NET::*`.
  - the navMate folder -- navMate loads its locals by BARE name (`use n_defs` / `n_utils` /
    `navDB` / `nmFrame` / ...; also `e80Config.pm` + `e80ScreenGrab.pm`, which MUST stay
    unqualified), so the folder has to be on the scan path for them to pack. Chosen over
    qualifying the names because the bare-name convention is permanent.
  - `_netWizard` -- so the `nw_*` wizard modules pack for `netWizard.exe`.
- **`include_module`** (force-include the runtime-loaded modules a static scan misses):
  `DBD::SQLite`, `JSON::PP`, `threads`, `threads::shared`.
- **`codemask` = 1** (Plain Text Perl Code, not Masked) -- the source is open on GitHub;
  masking adds nothing.


## Packaged-vs-dev seam (the `$publisher` / path model)

Packaged and dev differ only in environment-keyed defaults, surfaced through the Pub::Utils
standard dirs plus the per-environment prefs file. `$Cava::Packager::PACKAGED` is the switch.

- **`$publisher = 'phorton1'`** segments the packaged roots:
  - `$data_dir` (packaged) = `Documents/phorton1/navMate` -- holds `navMate.db`, the
    canonical hub data, kept in My Documents deliberately.
  - `$temp_dir` (packaged) = `AppData/Local/phorton1/navMate`.
  - dev keeps `/base_data/{data,temp}`.
- **`DATABASE_PATH` pref:** packaged default `$data_dir/navMate.db`; dev default the live
  `/dat/Rhapsody` DB.
- **`HTTP_PORT` pref:** dev 9883, packaged 9873 -- so a dev and an installed navMate run
  side by side.
- **`$resource_dir`:** `_site` and `sym_catalog` live under `apps/navMate/_res/{site,
  sym_catalog}`; navServer's `HTTP_DOCUMENT_ROOT` and the sym reads use `$resource_dir`;
  Cava's `resource_path` = `_res`, so the whole tree bundles. The `sym_cache` thumbnails
  write to `$temp_dir/sym_cache` (writable in both modes).
- **`MAP_BROWSER` pref** replaces a hardcoded browser; the Commit/Revert (DB-to-git) menu
  items are gated off when packaged.
- **`$LOCAL_IP`:** `Pub::Ray::NET` binds its sockets to `$LOCAL_IP` (`a_defs.pm`, default
  `10.0.0.200`), which `initServices` resolves from a `LOCAL_IP` pref if one is set. The
  network wizard writes that pref; shark, which loads no prefs, uses the default.
- **Prefs model:** no prefs file is written by default. `init_prefs` sets the changeable
  prefs into the hash as in-hash non-defaults (set-only-if-absent), so a hand-made
  `navMate.prefs` overrides any of them. Defaults live in code at their natural site (DB in
  `navPrefs`, port in `navServer`).


## The installer (Inno Setup via `PreInstallApp.pm`)

- **Enable:** `installer_capable` + `doinstaller` = 1 in `cava20/msw/installer.config`
  (the Storable hash). A build then emits the Inno installer alongside the SFX.
- Cava 2.0 emits `innosetup.iss` for an OLDER Inno; the installed Inno 5.5.9 rejects three
  things (ISCC stops at the first):
  - `MinVersion=,<nt>` -- legacy 9x,NT comma form, invalid since 5.5.x dropped 9x support.
  - `OutputManifestFile=<path>` -- a path is no longer accepted (bare filename only).
  - `[Languages]` Basque/Slovak -- those `.isl` files no longer ship.
- **Fix + feature injection:** `apps/navMate/_installer/PreInstallApp.pm` (set as
  `installer.config` `pre_installer_script`) rewrites `innosetup.iss` before the ISCC compile:
  - 5.5.9 fixups: comment `MinVersion`, re-emit a bare `OutputManifestFile` in `[Setup]`,
    drop the `[Languages]` section, add `CloseApplications=force`.
  - `[Run]` OPTIONAL post-install checkbox "Run the navMate network wizard now" ->
    `{app}\bin\netWizard.exe` (`Flags: postinstall nowait skipifsilent runascurrentuser
    32bit`). **`runascurrentuser` is required:** Inno's postinstall `[Run]` defaults to
    de-elevated (`runasoriginaluser`), and `CreateProcess` cannot elevate a
    requireAdministrator exe.
  - **Windows Firewall:** idempotent delete-then-add inbound-allow rules for all three exes
    (names "navMate" / "navMate GUI" / "navMate Wizard"), `profile=any
    remoteip=10.0.0.0/8` -- scoped to the RAYNET /8 so the programs are unreachable on any
    non-10.x network, and so the "allow access" prompt never appears. A matching
    `[UninstallRun]` removes them on uninstall.
  - **First-run data seed:** two `[Files]` entries populate the user's OWN data dir
    (`{userdocs}\phorton1\navMate`, the `setStandardDataDir` model): `_installer\examples\example.db`
    -> `navMate.db` with `onlyifdoesntexist` (fresh installs only, never clobbers an existing hub)
    + `uninsneveruninstall`, and `_installer\examples\*` -> `{userdocs}\phorton1\navMate\examples`
    (the user's writable demo copy). The examples are INSTALLER payload, compiled into the installer
    at ISCC time -- deliberately NOT in `_res` (the app never reads them at runtime). The app keeps
    "no navMate.db -> create empty", so deleting the db stays the user's reset gesture.
- **Shortcuts:** `installer.config` `desktopicons` drives the Start-Menu + Desktop
  shortcuts for the app and the wizard.
- **Artifacts:** SFX = `navmate-mswin-x86-<ver>.exe` (run-in-place); the installer's base
  name is the `installer.config` `name` field.


## Version scheme

`0.9.x`: `0.9` = pre-release, `.x` = build/cycle. Set it in the Cava GUI (the trailing
field auto-bumps on build). Current: **0.9.3**.


## Build procedure

1. Open Cava (single-instance); confirm the project loaded.
2. If you edited `cava20.cpkgproj` via SQL, do it with Cava CLOSED and back it up first.
3. **Distribution -> Scan and Build Project.** Read `cava20-logs/build.log` and `scan.log`;
   zero Warning/Error lines is the target. Each missing runtime-loaded module becomes
   another `include_module` row -- rebuild until clean. (Benign notices: SSL libs not added
   for Net::SSLeay/Crypt::SSLeay; utf8/unicore; the Cava-on-modern-Windows OS-signature.)
4. Confirm `netWizard.exe` packed all `nw_*` modules (the build.log "Building file" list)
   and got the requireAdministrator manifest.
5. The installer compiles via ISCC after `PreInstallApp.pm` rewrites the `.iss`.
6. Install and smoke-test the four wizard launch paths -- Start-Menu icon, Desktop icon,
   in-app **Utils -> "E-Series Network Wizard"**, and the installer Finish-screen checkbox.
   All four UAC-elevate.
7. Commit `cava20.cpkgproj` (and `installer.config` if it changed).


## Gotchas / durable lessons

- The build is a GUI operation (Scan and Build); `cavaconsole.exe` is a runtime console,
  not a builder.
- The `.cpkgproj` is the single source of truth and is SQLite -- to compare projects, dump
  and diff the DBs directly.
- Cava launched off-screen once: saved window position `left/top = -32000` (the Windows
  minimized-window sentinel). Fix: quit Cava, edit
  `C:\Users\Patrick\AppData\Local\cava\cavapack\packager\conf\wxapp.config`, section
  `[CF::Packager::Form::MainWindow/position]`, set on-screen `left`/`top`, relaunch.
- Icons must be set in the GUI (internalized), not via SQL.
- Add the `.gitignore` before the first commit.


## Inline::C / navMatch packaging

- `navMatch.pm`, `navMatchC.pm`, `winFind`, and `Inline.pm` bundle normally -- Cava packs
  every module into the compressed `package.lib`, so bundling is confirmed in the build.log
  "Building file" list, not by looking for loose files under `release/`.
- The compiled kernel cache (`config-MSWin32-x86-multi-thread-5.012004` plus
  `lib/auto/navMatchC_XXXX/navMatchC_XXXX.dll`) lives under the resource tree at
  `_res/_Inline`, so `resource_path = _res` bundles it into `{app}/res/_Inline`.
- `navMatchC.pm` derives `INLINE_DIR` from `$resource_dir/_Inline`. In dev that is the
  in-repo `_res/_Inline` (writable, where Inline built it). When packaged, navMatchC
  xcopy's the bundled cache out to `Win32::GetFullPathName("$temp_dir/_Inline")` -- a
  writable, drive-lettered temp dir -- and points Inline there. BOTH are required: Inline
  0.5 rejects a directory that is read-only (Program Files) OR drive-less (the packaged
  `$resource_dir` is a `/PROGRA~2/...` path). `INLINE_DIR` is a hardcoded path, not an
  `@INC` entry, so `PERLLIB` has no bearing on it.
- The committed `.dll` loads as-is, no recompile: PE machine `0x014c` (i386 / 32-bit x86),
  Inline key `MSWin32-x86-multi-thread-5.012004` -- identical to Cava's bundled perl
  (5.12.4). Inline validates that key on load, so a mismatch is refused (rebuild) rather
  than mis-loaded.


## e80Config / e80ScreenGrab (advanced features)

These two depend on a separate hardcoded port and on CUSTOM E80 FIRMWARE running on the
device; they are "advanced / requires custom firmware" features, not baseline for a public
install. (The firewall is no longer a manual step -- the installer pre-authorizes inbound
access for all three exes.)
