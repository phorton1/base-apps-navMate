# navMate User Manual - The Map

**[Home](readme.md)** --
**[Getting Started](getting_started.md)** --
**The Map** --
**[Organizing Data](organizing_your_data.md)** --
**[Copy, Cut & Paste](copy_cut_paste.md)** --
**[Multi-Editor](winMultiEditor.md)** --
**[Import & Export](import_export.md)** --
**[FSH Files](winFSH.md)** --
**[Connecting an E-Series](connecting_e80.md)** --
**[Using Your E-Series](using_e80.md)**

navMate shows your navigation data on a **map** -- an interactive, satellite-imagery
view that opens in your web browser right alongside the application windows.

<!-- [SCREENSHOT] images/map.png -- the map with waypoints, a dashed route, and a
     track shown over satellite imagery -->

## Opening the map

The map does not open on its own when navMate starts. It opens the first time you put
something on it: **double-click** any item in the database, E80, or FSH tree -- or tick its
checkbox -- and the map opens in your web browser showing that item. You can also open it at
any time with **View -> Open Map**. It runs locally on your own computer -- navMate does not
need an internet connection to work, though the satellite imagery itself is fetched online
when you are connected.

## What you see on the map

- **Waypoints** appear as small symbols -- the same anchor, hazard, fish, and marker icons
  your E-Series uses. A waypoint set up as a *label* shows its name as text; a *sounding*
  shows its depth.
- **Routes** are drawn as dashed lines connecting their waypoints in order.
- **Tracks** -- the breadcrumb trail of where the boat actually went -- are drawn as solid
  colored lines.

Folders are not drawn on the map; only the waypoints, routes, and tracks inside them are.

## Showing and hiding things

The map does not show everything at once -- it shows what you have **checked** in the tree
windows. Every item has a checkbox:

- Tick a waypoint, route, or track and it appears on the map immediately.
- Tick a folder and everything inside it appears.
- Un-tick to hide. **View -> Clear Map** hides everything at once.

This is how you focus: check just the region or the trip you care about, and the map shows
only that. navMate remembers what was visible from one session to the next.

## Editing on the map

When you select a track or route, navMate lets you adjust it directly on the map -- drag a
point, insert or delete points, trim or split a track. This is handy for tidying up a recorded
track or fine-tuning a planned route by eye against the satellite image.

**Next:** [Organizing Data](organizing_your_data.md)
