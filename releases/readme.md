# navMate Windows Installer Releases

The downloadable **Windows installer** for navMate lives on this repository's
[**Releases**](https://github.com/phorton1/base-apps-navMate/releases) page, not in this
folder: the installer exe is a GitHub Release asset, so this repo stays text-only and lean.

navMate is *pure Perl / wxPerl*. The installer bundles it with a private **ActivePerl 5.12**
via the ancient **Cava Packager 2.0** -- the only tool that still packages this Perl/wx stack
as a standalone Windows exe. The full build method is arcane and effectively unpublishable,
but **all** source (navMate, `Pub::`, and `Pub::Ray`) is here on GitHub and is guaranteed
free of malware or adware.

> **1.0.0 is the first official release.** The `0.9.x` entries below were pre-releases, published
> for early access and not retained.

This is a release LOG, not a changelog. For what changed between any two releases the git
history is authoritative: `git log navMate<older>..navMate<newer>`.

## Releases

| date | version | notes |
| ---- | ------- | ----- |
| 2026-08-06 | 1.0.0 | First official release. Custom firmware v5.75 adds runtime code extensions, including aerial imagery: satellite photography drawn under the charts on the plotter, built with chartMaker |
| 2026-07-10 | 0.9.10 | Adds OpenCPN sync (waypoints, routes, tracks) via the oESeries plugin; foreign-character support; GPX export; installer/uninstall fixes |
| 2026-07-01 | 0.9.9 | Renames "E80" to "ESeries" throughout; user-manual and network-setup wording fixes |
| 2026-06-29 | 0.9.8 | Fixes Save Configuration so the panelset layer is captured correctly on every E-Series plotter; plus map/UI fixes |
| 2026-06-28 | 0.9.7 | Timed Track Recording -- date/time + water depth at each track point; plus an About E80 dialog and a Help menu |
| 2026-06-17 | 0.9.6 | e80Mod -- the E-Series Firmware Builder: build a custom v5.72 plotter firmware from your own stock v5.69, offline |
| 2026-06-15 | 0.9.5 | first public pre-release -- Leaflet map waypoint editor, seeded example database, E-Series network wizard |

Each release is the same tag `navMate<version>` stamped across the five repos it was built
from, so it is fully reproducible; the tags in git are the authoritative provenance.

### navMate1.0.0 -- 2026-08-06

The first official release.

- **Custom firmware v5.75** -- adds mod005, which lets the plotter load code extensions from a CF
  card at startup.
- **Aerial imagery** -- with `AERIAL.COE` and `.RCT` files built in chartMaker, the plotter draws
  your own satellite and aerial photography underneath the charts, geo-registered below the boat,
  cursor, and waypoints.
- Adds the **Aerial Imagery** chapter to the User Manual.

### navMate0.9.9 -- 2026-07-01 (pre-release)

- Renames "E80" to "ESeries" throughout the app -- the same firmware runs on both the E80 and the
  larger E120, so "ESeries" now covers both.
- Identifies individual plotters as E80(n) / E120(n) in the About ESeries dialog and in the Screen
  Grab and Save Configuration choosers.
- Updates the User Manual for the new wording.
- Corrects the network-connection advice to recommend a plain Ethernet switch.

### navMate0.9.8 -- 2026-06-29 (pre-release)

Fixes a bug saving an E-Series plotter's display configuration, so the instrument-panel
settings are now captured correctly on any unit. Fixes the second Database window not
refreshing after edits. Adds Paste Before / Paste After on top-level branches. Enhances the
custom color picker. Makes the Find window remember its position during a session.

Built from (the `navMate0.9.8` tag in each repo):

```
navMate            <navMate0.9.8 commit>
Pub                0c26037
Pub::Ray           e25162d
base_dist/navMate  c557a99   (private)
Perl               a3c6c457  (private)
```

### navMate0.9.7 -- 2026-06-28 (pre-release)

Adds **Timed Track Recording**: on a custom-firmware plotter, navMate can record the date/time
and water depth at every point of a track, view that detail in the E80 and FSH windows, and
carry it losslessly between the database, the plotter, and `.fsh` files. Also adds an **About
E80** dialog (per-unit identity and firmware build details) and a **Help** menu (User Manual +
About navMate), and updates the **User Manual** with screenshots and some cleaned-up concepts.

Built from (the `navMate0.9.7` tag in each repo):

```
navMate            83aca77
Pub                0c26037
Pub::Ray           ead8a65
base_dist/navMate  a6232b6   (private)
Perl               a3c6c457  (private)
```

### navMate0.9.6 -- 2026-06-17 (pre-release)

Adds **e80Mod**, the E-Series Firmware Builder: turn your own stock Raymarine **v5.69**
firmware into a modified **v5.72** image on your own machine, entirely offline, then flash it
from the plotter's own CF-card menu. Reached from **Utils -> E-Series Firmware** or its
Start-menu / desktop shortcut.

Built from (the `navMate0.9.6` tag in each repo):

```
navMate            1d0429b
Pub                0c26037
Pub::Ray           a2012aa
base_dist/navMate  582d040   (private)
Perl               a3c6c457  (private)
```

### navMate0.9.5 -- 2026-06-15 (pre-release)

First public, hand-rolled pre-release -- Leaflet map waypoint editor (database / E80 / FSH),
a seeded example database, and the E-Series network setup wizard.

Built from (the `navMate0.9.5` tag in each repo):

```
navMate            c927ab4
Pub                0c26037
Pub::Ray           f925765
base_dist/navMate  2c72c24   (private)
Perl               a3c6c457  (private)
```

<!-- Entry template (newest first, added when a release is cut):

### navMate<version> -- YYYY-MM-DD

<one terse line of highlights>

No SHA block: the `navMate<version>` tag in each of the five repos is the provenance.
(0.9.x entries are marked "(pre-release)"; releases from 1.0.0 on are not.)
-->
