# navMate - OpenCPN Spoke

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Data Model](data_model.md)** --
**[UI Model](ui_model.md)** --
**[Implementation](implementation.md)** --
**[navOperations](navOperations.md)** --
**[Spoke Contract](navOps_spoke_contract.md)** --
**OpenCPN** --
**[KML Specification](kml_specification.md)** --
**[GE Notes](ge_notes.md)** --
**[Testing](testing.md)** --
**[winFSH](winFSH.md)** --
**[winMultiEditor](winMultiEditor.md)** --
**[E80Config](e80_config.md)** --
**[Timed Tracks](timed_tracks.md)**

repos: **[phorton1](https://github.com/phorton1)** --
**[Ray Library](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/readme.md)** --
**[oESeries Plugin](https://github.com/phorton1/src-OpenCPN-oESeries/blob/master/docs/readme.md)** --
**navMate App**

## Overview

The OpenCPN spoke connects navMate's canonical store to [OpenCPN](https://opencpn.org)
through the companion **[oESeries](https://github.com/phorton1/src-OpenCPN-oESeries/blob/master/docs/readme.md)**
plugin - a separate C++ OpenCPN plugin. It follows the same hub-and-spoke contract as
the E80 and FSH spokes (see [Spoke Contract](navOps_spoke_contract.md)): navMate is the
hub of record, OpenCPN is a lossy projection, and the hub never forgets what the spoke
cannot carry.

The spoke exists to do two things well: **populate OpenCPN from a navMate archive**, and
**archive OpenCPN-created geometry back into navMate**. It is not a live-navigation
integration - OpenCPN brings the chart engine, AIS, and real-time GPS that navMate does
not attempt to duplicate; navMate brings the lifelong, hierarchical knowledge store that
no chartplotter holds.

## Transport and Roles

Unlike the live E80 spoke and the KML/FSH file spokes, the OpenCPN spoke is a **polling
network peer**. navMate runs its embedded HTTP server (`navServer.pm`); the oESeries
plugin is a polling HTTP client. The two directions are asymmetric:

- **Inbound (OpenCPN -> navMate).** The plugin POSTs its full inventory - marks, routes,
  tracks - to `/api/ocpn`. navMate parses it into an in-memory spoke model (the `ocdb`).
  As with every spoke, nothing enters the canonical database until a user **paste**
  crosses the boundary; the inventory itself is a live, read-only projection.

- **Outbound (navMate -> OpenCPN).** navMate is the server and cannot push
  synchronously. A push or paste *into* the spoke enqueues a `commands[]` batch that the
  plugin fetches on its next poll, applies, and acknowledges with `results[]`. A
  `db_version` generation counter gates steady state, so a poll with nothing new returns
  no work.

## Identity

OpenCPN addresses objects by RFC 4122 GUID; navMate by its own uuid. The `navIdentity.pm`
codec bridges the two:

- **navMate-origin** objects carry a synthesized GUID that embeds a `navMate` magic and
  reverses back to the uuid table-free.
- **Foreign (OpenCPN-born)** objects are minted a navMate uuid tagged with the OpenCPN
  provenance byte, plus a persistent `ocpn_guid_map` row so the object's original opaque
  GUID survives round-trips even after the plugin has forgotten it.

## The Data Model at the Seam

- **Marks vs route vertices.** The plugin classifies each point as a standalone mark or a
  pure route vertex. Routes materialize their points as waypoint records - navMate, like
  the E80, has no anonymous vertices. Points shared between objects reconcile by identity
  to a single uuid.
- **Routes full-embed their points**, because OpenCPN cannot reference-share a waypoint
  across routes.
- **Manifestation XOR.** A navMate waypoint that is a route member manifests *once* - as
  the vertex - not also as a standalone mark.
- **Symbols.** A `sym`-to-`icon` table maps navMate symbols to OpenCPN icon names; a raw
  `icon_name` shadow preserves a foreign icon that has no navMate symbol equivalent.

## Persistence

The spoke's on-disk state is an additive minor schema bump (see [Data Model](data_model.md)):

- `ocpn_guid_map` - the foreign GUID <-> navMate uuid mapping.
- an `icon_name` shadow column on waypoints - preserves a foreign icon with no navMate
  symbol.
- a `db_version` mutation counter, driven by triggers on the waypoint / route / track
  tables - the generation gate the outbound direction polls against.

Foreign-origin objects and their raw icons persist across sessions, so an object pulled
in from OpenCPN and later pushed back out re-emits its original GUID rather than a fresh
navMate-minted one.

## Fidelity Boundary

The oESeries plugin reaches OpenCPN through its plugin ABI, which has **no partial
update**: changing an object is delete-then-add, rebuilt from a fixed value-copy
structure. The consequences, by object type:

- **Marks are safe** - the mark structure is rich and navMate merges on apply. (One
  field, `scamax`, is dropped by OpenCPN 5.12.4's own update path and is shown greyed.)
- **Editing an existing route or track loses** the attributes the structure cannot carry
  - route-level styling and planning fields, shared-waypoint visibility, and object
  links; track styling and metadata.
- **Fresh add and delete are lossless.**

navMate cannot shadow-restore these lost fields, because they never cross the seam
inbound either. This is a **deliberately accepted limitation**: the spoke's value -
populating OpenCPN from an archive and archiving OpenCPN geometry - does not depend on
lossless in-place editing of every OpenCPN attribute. The plugin side documents the
exhaustive per-field detail in its
[plugin limitations](https://github.com/phorton1/src-OpenCPN-oESeries/blob/master/docs/notes/OpenCPN_Plugin_Limitations.md)
note.

## navMate-Side Modules

- `navOCPN.pm` - the spoke model (`ocdb`) and the `/api/ocpn` HTTP handlers.
- `nmOCPNDirectOps.pm` - the transport-free ingest / project / command-build layer.
- `navIdentity.pm` - the uuid <-> GUID codec and foreign-GUID reconciliation.
- `winOCPN.pm` - a read-only wx pane that browses the live OpenCPN inventory; mutation
  crosses the boundary through navOps, not in the pane.
- `navOpsOCPN.pm` - the paste / push integration that makes `ocpn` a spoke to navOps.

The `/api/ocpn` endpoint encodes ascii-escaped JSON so the plugin's parser receives valid
input, bypassing navMate's default HTML-oriented JSON encoder.

The **wire contract** itself - endpoints, command and result shapes, the sync handshake -
is owned and specified on the plugin side, in the oESeries repository's
**[protocol.md](https://github.com/phorton1/src-OpenCPN-oESeries/blob/master/docs/protocol.md)**.

## Alternative Considered

A full-fidelity channel - transferring complete GPX through OpenCPN's peer interface,
and/or a plugin reading OpenCPN's object database directly - was explored and parked in
favor of shipping the plugin channel as-is. The edit-time attribute loss above is
accepted rather than engineered around.

---

**Next:** [winFSH](winFSH.md)
