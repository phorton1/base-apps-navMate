# navMate User Manual - Using Your E-Series

**[Home](readme.md)** --
**[Getting Started](getting_started.md)** --
**[The Map](the_map.md)** --
**[Organizing Data](organizing_your_data.md)** --
**[Copy, Cut & Paste](copy_cut_paste.md)** --
**[Multi-Editor](winMultiEditor.md)** --
**[Import & Export](import_export.md)** --
**[FSH Files](winFSH.md)** --
**[Connecting an E-Series](connecting_e80.md)** --
**Using Your E-Series**


**Important Note:** *navMate has been tested with **v5.52** of the Raymarine firmware, and
exhaustivly tested with the only still available Raymarine
[**v5.69 firmware**](https://www.raymarine.com/en-us/download/e-series-classic-software) and the
[**custom v5.73 firmware**](custom_firmware.md) you can produce from navMate.
**navMate may not work with earlier versions of Raymaine firmware**, and
so, if you're on firmware older than 5.52, we recommend upgrading your plotter to 5.69 or 5.73 if you wish to use it with navMate.*


Once your computer and plotter are connected ([previous chapter](connecting_e80.md)), the **E80
window** -- open it with **View -> E80** -- shows a live view of what is on the plotter: its
waypoints, groups, routes, and tracks, right next to your database window.

**TODO: Screenshot** <!-- [SCREENSHOT] images/win_e80.png -- the E80 window beside the database window, with a group
     selected on each side -->

## The trip cycle

navMate is built around a simple rhythm that matches how boating actually works:

1. **Before a passage** -- pick the waypoints, routes, and tracks you will want for where you are
   going, and **send them out** to the plotter.
2. **During the passage** -- use the plotter as you always do: drop new marks, record your track,
   adjust routes underway.
3. **After the passage** -- **bring back** everything new the plotter recorded and file it into
   your permanent collection.

The plotter holds what fits the trip; navMate holds everything, for good.

## Sending and bringing back

You move data between the two windows with the same copy and paste from the
[Copy, Cut & Paste](copy_cut_paste.md) chapter -- there is no separate transfer command:

- **Send to the plotter** -- copy items in your database window and paste them into the E80
  window. For items already on the plotter, navMate offers **Push to E80** to update them in
  place.
- **Bring back** -- copy items in the E80 window and paste them into a folder in your database.
  For items already in your database, navMate offers **Push to DB**.

navMate looks out for the plotter's limits as you go -- it warns you, for example, if a name is
too long for the plotter or a color cannot be matched exactly -- so a transfer never quietly
loses information.

Two more E80 menu commands worth knowing:

- **E80 -> Refresh E80-DB** re-reads everything currently on the plotter.
- **E80 -> Clear** wipes all routes, groups, waypoints, and tracks off the plotter, after a
  confirmation that shows you the counts first -- the quick way to start a trip with a clean unit.

## Seeing what is on the network

**E80 -> About E80** opens a window listing every plotter navMate can currently see on the network
-- each with its name, firmware version, network address, and whether it is the master. Pick a
plotter to see its details.

**TODO: Screenshot** <!-- [SCREENSHOT] images/about_e80.png -- the About E80 window listing a plotter and its details -->

On a plotter running the [custom firmware](custom_firmware.md), About E80 also reads the unit's
**model**, **firmware build date**, and the **builder handle** you chose when you built it -- a
quick way to confirm a plotter is running exactly the firmware you think it is, without walking over
to the unit.

## Advanced Features -- Custom Firmware

The three features below -- saving the plotter's display configuration, capturing its screen, and
recording timed tracks -- are **not part of the stock E-Series software**. They work only on a
plotter running optional **custom firmware** that you can build and install yourself, for free,
using navMate's own tool. Nothing of Raymarine's is bundled: you supply your own firmware, navMate
modifies a copy of it, and you flash the result onto your unit at your own risk.

If your plotter is running the stock firmware, these menu commands are **greyed out**. They become
available the moment navMate sees the plotter is running the custom firmware, and then work exactly
as described.

**Click [here](custom_firmware.md) to learn how to build the [Custom Firmware](custom_firmware.md)**

### Managing the plotter's screens

navMate can also look after the plotter's **display configuration** -- the page layouts and
instrument panels you have set up on the unit. From the **E80** menu:

- **Save Configuration** captures the current setup into a folder navMate keeps for you.
- **Restore Configuration** writes a saved setup back to a plotter -- handy for setting up a new
  or borrowed unit just the way you like it.
- **Clear Configuration** resets the unit to its defaults.

### Capturing the screen

**Grab Screen** takes a picture of whatever the plotter is showing right now and saves it as an
image file -- useful for notes, sharing, or documentation.

### Recording timed tracks

A stock E-Series track is just a string of positions. With the custom firmware, navMate can ask the
plotter to record **timed tracks** instead -- each point also stamped with the date, time, and
depth as you passed it. Bring such a track back into navMate and you can see exactly when you were
where, and how deep the water was.

From the **E80** menu, **Timed Track Recording...** shows whether the plotter is recording timed
tracks right now, and lets you turn it on or off. The setting lives on the plotter and stays as you
leave it.

**TODO: Screenshot** <!-- [SCREENSHOT] images/timed_tracks.png -- the Timed Track Recording dialog showing the current setting -->

**Next:** [Home](readme.md)
