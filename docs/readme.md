# navMate - Lifelong Navigation Knowledge Management

**Home** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**[Spoke Contract](navOps_spoke_contract.md)** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)** --
**[Testing](testing.md)** --
**[winFSH](winFSH.md)** --
**[winMultiEditor](winMultiEditor.md)** --
**[E80Config](e80_config.md)** --
**[Timed Tracks](timed_tracks.md)**

repos: **[phorton1](https://github.com/phorton1)** --
**[Ray Library](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/readme.md)** --
**[shark Tool](https://github.com/phorton1/base-apps-shark/blob/master/docs/shark.md)** --
**navMate App**

**navMate** is a desktop application for managing a mariner's complete navigation
data - waypoints, groups, routes, and tracks - across a lifetime of voyaging, across
multiple boats, and across multiple chartplotter devices. It is the primary management
surface for that data, not a companion to any single device.

Where chartplotters are operationally scoped - designed for the region your boat is in
right now, with the dozens of objects relevant to the current passage - navMate operates
at a different scale and time horizon entirely. A career sailor accumulates thousands of
waypoints, hundreds of routes, and years of track history. That knowledge has no home on
any chartplotter. navMate is that home.

The Raymarine E80/E120 SeatalkHS protocol (**RAYNET**) is the first transport
implementation. navMate's architecture is designed to support additional chartplotter
protocols and navigation systems behind a common transport abstraction. The knowledge
base, data model, and UI are the product. Everything else is a boundary adapter.

## Documentation Outline

- **[Architecture](architecture.md)** -
  Architectural vision: scope, UI layers, transport abstraction, relationship to
  chartplotters and OpenCPN, distribution path.

- **[Data Model](data_model.md)** -
  SQLite schema: collections hierarchy, WRT tables (Waypoints, Routes, Tracks),
  waypoint types, UUID strategy, timestamp sources, design decisions.

- **[UI Model](ui_model.md)** -
  Three concurrent UI surfaces (console, wx panels, Leaflet canvas), collection
  tree with checkbox visibility control, Leaflet
  selection operations, session state persistence.

- **[Implementation](implementation.md)** -
  Module inventory by layer: foundation, data transport, context operations,
  HTTP server, and wx UI.

- **[navOperations](navOperations.md)** -
  Copy / Cut / Paste operations across both panels: selection rules, clipboard
  vocabulary, pre-flight validation, paste compatibility matrix, operation
  semantics, and HTTP test machinery.

- **[KML Specification](kml_specification.md)** -
  KML file structure, style naming and templates, ExtendedData tags, object-to-KML
  mapping for collections, waypoints, routes, and tracks; re-import semantics.

- **[GE Notes](ge_notes.md)** -
  Google Earth round-trip workflow, safe and unsafe GE editing operations, the
  additive-only re-import asymmetry, track editing policy.

- **[Testing](testing.md)** -
  Outward-facing overview of the navOps test suite at `../test/`. Module
  organization (db, e80, tracks, fsh, hub), shared headers, fixtures, full-cycle
  orchestrator, and results archival.

## Credits

- **[wxPerl / wxWidgets](https://www.wxwidgets.org/)** - the cross-platform GUI
  toolkit used for navMate's windows, panels, and dialogs.
- **[SQLite](https://www.sqlite.org/)** (via `DBD::SQLite`) - the embedded
  database engine that holds the navigation knowledge base.
- **[Leaflet](https://leafletjs.com/)** (v1.9.4) - open-source JavaScript library
  for the interactive map canvas (BSD 2-Clause license). Tile imagery sourced
  separately from Google Maps and Esri.
- **[Leaflet-Geoman](https://geoman.io/leaflet-geoman)** (v2.16.0) - open-source
  Leaflet plugin for geometry editing: vertex drag, insert, delete, and custom
  track editing operations (MIT license).
- **[Google Maps](https://developers.google.com/maps)** - satellite tile imagery
  via the Maps JavaScript API (`lyrs=s`). Requires a Google Maps Platform API key;
  usage subject to Google Maps Platform Terms of Service.
- **[Esri](https://www.esri.com/)** - place name label overlay tiles via the
  ArcGIS Online REST tile service. Free for display use; attribution required.

## License

Copyright (C) 2026 Patrick Horton

navMate is free software, released under the
[GNU General Public License v3](../LICENSE.TXT) or any later version.
See [LICENSE.TXT](../LICENSE.TXT) or <https://www.gnu.org/licenses/> for details.

## Please Also See

- [**phorton1/base-apps-navMate**](https://github.com/phorton1/base-apps-navMate) -
  this repository on GitHub

- [**Ray Library**](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/readme.md) -
  the reverse-engineered SeatalkHS protocols, FSH file format, and CSV
  conversion library that navMate's E80 and FSH spokes are built on.

- [**shark**](https://github.com/phorton1/base-apps-shark/blob/master/docs/shark.md) -
  the SeatalkHS engineering tool; the laboratory in which the protocols
  were reverse engineered.

---

**Next:** [Architecture](architecture.md)
