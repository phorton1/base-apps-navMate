# DATABASE

**[Home](readme.md)** --
**[RAYNET](RAYNET.md)** --
**[RAYDP](RAYDP.md)** --
**[WPMGR](WPMGR.md)** --
**[TRACK](TRACK.md)** --
**[FILESYS](FILESYS.md)** --
**DATABASE** --
**[FIDS](FIDS.md)**

**[Up](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**Abstracts** --
**[Deployment](../deployment/readme.md)** --
**[Tools](../tools/readme.md)** --
**[Cleanroom](../cleanroom.md)**

Database protocol: the transactional command envelope, registration
mechanics, the 10/1 Hz tiered broadcast.

DATABASE (and its multicast arm DBNAV) is the E80's central
field-publishing service. From Patrick's perspective these have
always appeared as two services at two different ports: TCP 2050
for control (DATABASE, `d_DB.pm`) and multicast 2562 for the
field broadcast (DBNAV, `d_DBNAV.pm`). What the firmware
exploration revealed is that **inside the E80 they share a
single implementation**: one object called
`CLNetDBReportGenerator` owns both transports. The TCP side is
how clients tell the E80 "I'd like to know about this fid"; the
multicast side is the E80 telling everyone "here are the current
values of all the fids someone has asked about."

## The subscription / broadcast model

The report generator keeps three lists (RB-trees; conceptually,
Perl hashes keyed by fid):

- **`%field_subs`** -- fids whose **values** get broadcast at
  1 Hz.
- **`%uuid_subs`** -- fids whose **directory entries** (more on
  these below) get broadcast at 1 Hz.
- **`%heading_subs`** -- a special list for heading-family fids
  (HEADING, HEAD_MAG, HEAD_MAYBE); broadcast at **10 Hz**
  instead of 1 Hz.

A thread inside the E80 wakes every 100 ms and walks the heading
list emitting current values; every tenth wake it also walks the
other two lists. That's literally the entire broadcaster.

## How a fid gets into one of those lists

Two ways:

1. **Firmware preload at boot.** The report generator's
   constructor subscribes itself to five fids that are always-on:
   - HEADING (0x17) -> heading list, 10 Hz
   - SPEED (0x03), SOG (0x04), COG (0x1a), LATLON (0x44) ->
     field list, 1 Hz

   These five FIDs ALWAYS broadcast when the E80 has corresponding
   data. They are the source of the "broadcasts begin when the
   E80 has a fix and heading" behavior Patrick has observed for
   years.

2. **A TCP client sends `CMD_FIELD` (cmd 0x02) for the fid.**
   The per-Connection serviceLoop sees CMD_FIELD, calls
   `subscribe_FIELD`, which adds the fid to the appropriate
   list (heading-family fids go to the heading list
   automatically; everything else goes to the field list).

That's the entire registration scheme. CMD_FIELD is the only
thing that adds fids to the value broadcast. There's also a
CMD_UUID (cmd 0x00) that adds to the directory-entry list.

When RNS makes the broadcast "go rich," it's quietly sending
CMD_FIELD for every fid it cares about during startup -- no
magic, just a sequence of one-command-per-fid TCP exchanges.

## Values vs directory entries

- A **value** is the actual content of a field -- a heading in
  tenths of a degree, a depth in cm, a lat/lon pair. The FIELD
  broadcast (cmd_word `0x100300`) carries these. The E80 emits a
  fid's value only if it currently has valid data; if no compass
  is attached the HEADING fid is still in the heading list, the
  broadcaster tries to read it every 100 ms, gets back "not
  valid", and silently skips it. Once a compass starts feeding,
  the value pops into existence and the broadcast starts
  carrying it.

- A **directory entry** (UUID) is metadata: "fid 0x30
  (ENG_RPM1) corresponds to the engine identified by UUID
  0xABCD...". Useful when a fid can have multiple physical
  sources -- a twin-engine boat has two engines feeding ENG_RPM1,
  each with its own UUID. The UUID broadcast (cmd_word
  `0x100301`) enumerates up to 10 (fid, uuid) pairs per
  subscribed fid. Directory entries can exist when values don't
  (engine connected but not running), and can be absent (no
  engine attached at all).

Both broadcasts use the same wire layout for each per-fid record
-- the only difference is what's in the `data` field (a value, or
a uuid).

## Command vocabulary

The Patrick-empirical 6 commands plus 3 new firmware-only ones,
all in the form `0x001001<C>` for SEND-direction and
`0x001002<C>` for INFO-direction frames:

```
SEND:
  0x00100100  CMD_UUID    8 B    add fid to UUID subscription list
  0x00100101  CMD_DEF     8 B    request a field definition
  0x00100102  CMD_FIELD   8 B    add fid to FIELD subscription list (broadcast subscribe)
  0x00100103  CMD_EXISTS  8 B    check whether a field exists
  0x00100104  CMD_NAME   12 B    enumerate items by fid (reply form is overloaded)
  0x00100105  CMD_QUERY  12 B    one-shot value query
  0x00100106  CMD_06     12 B    declare "FIELD-update incoming"  (NEW)
  0x00100107  CMD_07            declare "UUID-update incoming"   (NEW)
  0x00100108  CMD_08     12 B    declare "QUERY-update incoming"  (NEW)

INFO (transaction sub-protocol):
  0x00100200  INFO_START 20 B   begin transaction; cache UUID + metadata
  0x00100201  INFO_CHUNK var    append chunk into accumulator
  0x00100202  INFO_END   16 B   commit the transaction (per CMD_06/07/08)

DIR-05 (new direction):
  0x00100500  cmd-05-00         clean no-op handler (likely "cancel"/"close")
```

## The three new SEND commands

Six SEND commands (0x00..0x05) match Patrick's existing
`d_DB.pm` table. Three more exist that have never been observed
empirically:

- **0x06** -- "I'm about to upload a FIELD update"
- **0x07** -- "I'm about to upload a UUID update"
- **0x08** -- "I'm about to upload a QUERY-shaped update"

These aren't standalone -- they're the **opening move of a
three-part conversation**. The client sends one of 0x06/0x07/0x08
to declare what kind of update is coming. The E80 stashes the
"kind" in a per-connection state slot. Then the client sends
INFO_START + one-or-more INFO_CHUNK + INFO_END, accumulating the
payload in a buffer. When INFO_END arrives, the E80 looks at the
stashed kind to know how to interpret what just came in.

This is the **write/update side** of DATABASE -- analogous to
TRACK's writer-mode that was cracked a day earlier. These
commands have never been sent because the empirical exploration
has only ever been a reader. They are not currently needed for
any open problem in Patrick's tooling, but they are now
documented for the day a write capability is wanted.

## DBNAV wire format

The multicast packet header:

```
cmd_word    (2 bytes) - 0x0300 (FIELD broadcast) or 0x0301 (UUID broadcast)
sid         (2 bytes) - 0x0010 = 16
num_fields  (4 bytes) - count of TFieldRecords in payload
```

Each TFieldRecord (one per FID per packet):

```
fid       (4 bytes)
type      (2 bytes)  - firmware semantic-type ID (see [FIDS](FIDS.md))
len       (2 bytes)
data      (len bytes)
type8     (1 byte)
ttl       (1 byte)
extra_len (2 bytes)
extra     (extra_len bytes)
```

Max packet size 1000 bytes; flushed via `sendto` and a new packet
starts on overflow. Patrick's `d_DBNAV.pm decode_field` reads
exactly this layout.

The 2-byte `type` field is the firmware's own semantic-type ID
for the data the record carries. See [FIDS](FIDS.md) for what
this opens up.

## Gap findings vs the existing /raymarine/NET implementation

1. **Three new SEND commands** beyond Patrick's 0x00..0x05 set
   (0x06/0x07/0x08, the transaction sub-protocol). Not currently
   needed; documented for future.
2. **New direction 0x05** (cmd_word `0x100500`) with a no-op
   handler -- probably "cancel" or "graceful close".
3. **The INFO|FIELD reply (cmd_word `0x100002`) is overloaded.**
   In response to CMD_NAME it carries a `(fid, count,
   uint16[count])` fid-list, not the `[seq, uuid]` form
   `d_DB.pm`'s parse rule currently assumes.
4. **The wire `type` field opens automatic decoder selection.**
   See [FIDS](FIDS.md).

## What this changes / what to do about it

- The existing `winDBNAV` viewer and `d_DBNAV` parser are
  fundamentally correct. The wire format Patrick reverse-engineered
  from observation matches the firmware exactly.
- `$WITH_DB` and `$WITH_DBNAV` defaults in `shark.pm` are
  appropriate (on when DATABASE is the focus, off otherwise --
  these broadcasts are chatty enough to obscure other modules'
  log output).
- The practical near-term improvement: change `d_DB.pm`'s
  per-fid sweep from `CMD_UUID` to `CMD_FIELD` (or do both), so
  the broadcast stream gets populated even with no RNS in
  parallel. This is the "stop depending on RNS for FID
  discovery" move.
- The transaction-write protocol (0x06/0x07/0x08 +
  INFO_START/CHUNK/END) is a parked future capability.

---

**Next:** [FIDS](FIDS.md) ...
