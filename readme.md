# navMate

*A home for a lifetime of navigation -- your waypoints, routes, and tracks, across every
boat and every chartplotter you have ever owned.*

<!-- TODO: hero screenshot -> images/navMate-hero.png (the Leaflet chart with a route loaded) -->

**navMate** is a free desktop application for managing your complete navigation data -- your
waypoints, groups, routes, and tracks -- in one place. Plan and organize on your computer with
the whole world in view, and keep all of it, forever. navMate works entirely on its own: you do
**not** need a chartplotter, a boat, or a network connection to use it.

When you *do* have a Raymarine E-Series plotter, navMate adds a significant capability on top of
that: it connects to the plotter over the network so you can push the waypoints and routes you
need out to your E80, and pull your tracks back off the boat at the end of a passage.

## Works with

- **Windows 10 / 11.** A self-contained desktop application -- nothing else to install, and
  fully useful on its own, with or without a chartplotter connected.
- **Raymarine E80 / E120** chartplotters, over a standard Ethernet cable (SeatalkHS / RAYNET) --
  optional, for users who want to move data to and from their plotter.
- **Developers** can also run navMate directly from its Perl source -- see the
  [Developer / Technical docs](docs/readme.md).

<!-- TODO: list additional devices/protocols here as they are supported -->

## Download

**[Download the latest navMate installer](https://github.com/phorton1/base-apps-navMate/releases)**
from the GitHub Releases page -- grab the installer from the most recent release at the top
of the list and run it.

New here? Start with **[Getting Started](user_manual/getting_started.md)** -- the quickest
path from a downloaded installer to your first look around navMate.

## Documentation

- **[User Manual](user_manual/readme.md)** -- install navMate, use it on its own, and connect to an E-Series.
- **[Getting Started](user_manual/getting_started.md)** -- download to first connection.
- **[Developer / Technical docs](docs/readme.md)** -- architecture, data model, and the
  reverse-engineered Raymarine SeatalkHS protocol, for the curious and for contributors.

## Credits

navMate stands on the work of these open-source projects:

- **[wxPerl / wxWidgets](https://www.wxwidgets.org/)** -- the cross-platform GUI toolkit
  used for navMate's windows, panels, and dialogs.
- **[SQLite](https://www.sqlite.org/)** (via `DBD::SQLite`) -- the embedded database engine
  that holds the navigation knowledge base.
- **[Leaflet](https://leafletjs.com/)** (v1.9.4) -- open-source JavaScript library for the
  interactive map (BSD 2-Clause license). Tile imagery sourced separately from Google Maps
  and Esri.
- **[Leaflet-Geoman](https://geoman.io/leaflet-geoman)** (v2.16.0) -- open-source Leaflet
  plugin for geometry editing: vertex drag, insert, delete, and custom track editing
  operations (MIT license).
- **[parsefsh](https://github.com/rahra/parsefsh)** by Bernhard R. Fischer -- the open-source
  C project that first decoded the Raymarine FSH archive format; navMate's FSH support
  (through the Pub::Ray library) is built on that groundwork (GPL).
- **[OpenCPN](https://opencpn.org/)** -- the open-source marine chart plotter navMate exchanges
  waypoints, routes, and tracks with, via the companion `oESeries` OpenCPN plugin built against
  OpenCPN's plugin API. OpenCPN and any of its assets navMate incorporates (for example, its
  waypoint icon set) are used under the GNU General Public License v3.
- **[Google Maps](https://developers.google.com/maps)** -- satellite tile imagery via the
  Maps JavaScript API (`lyrs=s`). Requires a Google Maps Platform API key; usage subject to
  the Google Maps Platform Terms of Service.
- **[Esri](https://www.esri.com/)** -- place-name label overlay tiles via the ArcGIS Online
  REST tile service. Free for display use; attribution required.

## License

Copyright (C) 2026 Patrick Horton

navMate is free software, released under the
[GNU General Public License v3](LICENSE.TXT) or any later version.
See [LICENSE.TXT](LICENSE.TXT) or <https://www.gnu.org/licenses/> for details.

The `mods/` folder is licensed separately, under the
[MIT License](mods/LICENSE.TXT) -- so that firmware extensions written against its
ABI header carry no copyleft obligation. See [mods/readme.md](mods/readme.md).

## Please Also See

- [**Pub::Ray (base-Pub-Ray)**](https://github.com/phorton1/base-Pub-Ray) -- the
  reverse-engineered Raymarine SeatalkHS / RAYNET protocols, the FSH file format, and the CSV
  conversion library that navMate's E80 and FSH spokes are built on. See especially its
  [**docs/e80_firmware**](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/e80_firmware/readme.md)
  folder, which documents the E-Series firmware internals behind navMate's custom-firmware
  features.

---

*navMate is an independent project and is not affiliated with, nor endorsed by, Raymarine.
"Raymarine", "SeatalkHS", "RAYNET", and "E80" are trademarks of their respective owner and
are used here only to describe compatibility.*

*Part of the [phorton1](https://github.com/phorton1) projects.*
