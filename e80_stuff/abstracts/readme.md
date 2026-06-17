# Abstracts

**Home** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**[DATABASE](DATABASE.md)** --
**[FIDS](FIDS.md)**

**[Up](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Tools](../tools/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The Patrick conceptual layer. The firmware's services and structures
described as they map to the /raymarine/NET protocol implementations
the project supports, plus other abstractions deemed useful to
remember. The umbrella doc (RAYNET) carries cross-cutting
synthesis -- threading model, timing implications, family-level
patterns. The per-service docs cover specific protocols, ordered by
project priority (WGRT maintenance is the core stated goal).

## Contents

Umbrella:

- [RAYNET.md](RAYNET.md) -- family-level synthesis: threading model, timing
  implications, common patterns across the SeatalkHS stack, and
  cross-cutting impacts on /raymarine/NET.

Per-service (priority-ordered):

- [RAYDP.md](RAYDP.md) -- service discovery and instantiation protocol;
  the complete service catalog mapped against observed SIDs; the
  gap surface of services that exist in firmware but are not yet
  implemented in /raymarine/NET.
- [WPMGR.md](WPMGR.md) -- waypoint manager service. Patrick stated
  long-term goal: WGRT (waypoint/route/group/track) maintenance
  core.
- [TRACK.md](TRACK.md) -- track service, including the writer-mode
  discovery that enabled the first programmatic track upload to
  an E80 over Ethernet.
- [FILESYS.md](FILESYS.md) -- filesystem access service. Clean, usable wire
  interface; resolves negatively on the long-open question of
  whether FILESYS supports writing to the CF card.
- [DATABASE.md](DATABASE.md) -- database protocol: the transactional command
  envelope, registration mechanics, the 10/1 Hz tiered broadcast.
- [FIDS.md](FIDS.md) -- the semantic data dictionary the DATABASE/DBNAV
  protocol carries: TDBItem type catalog, FID enumeration,
  encoding decisions. Peer of DATABASE; the substantive content
  of what the protocol delivers.

Ancillary abstractions (linked here, deliberately kept out of the
header menu and the Next cycle so further probes can be added
without churning the navigation):

- **[TFTP.md](TFTP.md)** -- standard RFC 1350 TFTP server compiled
  into e80.bin; listener bound on UDP 69 (wire-confirmed); both GET
  and PUT implemented; transfers gated by a single-byte flag
  normally flipped via a debug-shell text-CLI menu. Not part of
  /raymarine/NET; a generic file-transfer surface alongside the
  Raymarine wire services.
- **[FishHistory.md](FishHistory.md)** -- the fishfinder
  instrument-history service (firmware HistData, SID 0x16 / TCP
  2055, observed as `func22_t`); command structure and buffer
  geometry decoded; Patrick's name for the not-yet-implemented
  /NET service.
- **[Config.md](Config.md)** -- configuration of the persistent
  page sets and the Data application's data panels: the five page
  sets and their 600-byte on-flash layout blocks (consolidated in
  `\local\slotless\CMainApp0.lp`), the page-layout grammar, the
  application-ID table, and a preliminary outline of the
  recursively-divided data panels.

---

**Next:** [RAYNET](RAYNET.md) ...
