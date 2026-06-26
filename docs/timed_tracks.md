# navMate - Timed Tracks

**[Home](readme.md)** --
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
**Timed Tracks**

repos: **[phorton1](https://github.com/phorton1)** --
**[Ray Library](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/readme.md)** --
**[shark Tool](https://github.com/phorton1/base-apps-shark/blob/master/docs/shark.md)** --
**navMate App**

## Purpose

A stock E-Series track is a bare polyline -- a string of positions with no time. The **custom
firmware** adds *timed-track recording*: with it enabled, the plotter stamps every track point it
records with the wall-clock date/time and the true depth at that point. navMate provides the switch
that turns the behavior on and off, and shows the richer data once a timed track is brought back.

navMate is only the **writer of the switch and the reader of the result**; the recording itself is
done by the firmware. The firmware mechanism -- what the switch is and how the stamping works -- is
documented in the Ray library:
[mod003 -- per-track-point datetime + corrected depth](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/e80_firmware/deployment/mod003.md),
in particular
[The toggle](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/e80_firmware/deployment/mod003.md#the-toggle).
This document is the navMate side only and does not restate the firmware internals.

> **Requires custom firmware (v5.73).** Timed-track *recording* exists only on a unit running the
> custom firmware, built offline from the owner's own firmware by navMate's **e80Mod** tool; see
> [custom_firmware](../user_manual/custom_firmware.md). Reading and displaying timed data already
> present in a track works regardless of firmware.

## The switch

From the **E80** menu, **Timed Track Recording...** (`$COMMAND_E80_TIMED_TRACKS`,
`nmE80TimedTracks.pm`) manages the setting. It is a two-phase interaction so the wx thread never
blocks on the network:

1. **Read** -- a worker thread reads the plotter's current setting behind a progress dialog.
2. **Show** -- once the read completes, a checkbox dialog presents the current state (ENABLED /
   DISABLED) with the box pre-set to it, so the dialog reflects reality before the user touches it.
3. **Apply** -- only if the user changed the box, a second worker writes the new value and confirms
   it by reading it back (the write is unacknowledged on the wire, so navMate verifies by re-read).

The setting lives on the plotter as a single firmware-read database item (see
[The toggle](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/e80_firmware/deployment/mod003.md#the-toggle));
navMate is its writer. An absent/zero item is the timed default; a non-zero value selects stock
recording.

## Master-only gating

Unlike the **multi-device** configuration and screen-capture operations (which target any reachable
FILESYS unit -- see [E80Config](e80_config.md)), the timed-track switch is **master-only**: it acts
on the single unit the DATABASE service is connected to -- the data master that owns the shared
database the switch lives in. navMate gates the menu command on that connected unit's firmware
version (`nmE80TimedTracks::available` / `connectedUnitVersion`), enabling it only at **v5.73+**. On
a network whose master is stock but a slave is modded, the switch correctly stays disabled -- the
master's database would ignore it.

## HTTP endpoint

`navServer.pm` exposes the same core headlessly:

    /api/timed_tracks?cmd=get               -- read the current state
    /api/timed_tracks?cmd=set&enabled=0|1   -- 1 = timed recording ON, 0 = stock

`get` returns `{ connected, version, value, enabled }`; `set` returns
`{ ok, version, enabled, nochange }` or `{ error }`. `set` is gated v5.73+ so navMate never writes
the item on firmware that ignores it. Both run blocking on the HTTP thread, with no dialogs.

## Displaying timed data

A timed track's extra fields surface wherever tracks are shown:

- **winE80** and **winFSH** distinguish timed from stock tracks, and the track-point detail shows
  the per-point date/time and depth alongside position.
- In the database, the data lands in `track_points.ts` / `depth_cm` / `temp_k` (see
  [Data Model](data_model.md)); `0` is the "no reading" sentinel for stock or KML-sourced points.

## Status and scope

Built and in use: the recording switch (menu + `/api/timed_tracks`) and the timed-vs-stock display
in winE80 / winFSH. **In progress -- do not rely on yet:** the cross-spoke *translation* of timed
data as tracks move between the database, the E80, and FSH files (preserving or projecting the
per-point time and depth across those formats) is designed but largely unbuilt. Until it lands,
treat timed data as faithfully *shown* but not guaranteed to *round-trip* across every spoke. The
hub-and-spoke rationale is in [Spoke Contract](navOps_spoke_contract.md).
