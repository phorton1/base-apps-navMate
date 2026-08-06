# navMate User Manual - Aerial Imagery

**Back to:** [Using Your E-Series](using_eseries.md)

The [custom firmware](custom_firmware.md) gives your E-Series plotter an ability the stock software
does not have: it can draw **your own satellite and aerial photography** underneath the chart, on
the plotter's own screen, from imagery you build yourself.

<!-- SCREENSHOT: the money shot -- same anchorage, chart-only vs. aerial, side by side on the unit -->

Official charts are surveyed, authoritative, and frequently wrong about the last hundred metres --
the reef that grew, the sandbar that moved, the unmarked pass every local uses and no chart shows.
A photograph shows what is actually there. Once it is on a card in the unit, it is there when the
internet is not, which in the places where it matters most is nearly always.

## Where it helps

For a great many of the places worth taking a boat, aerial photography has simply never been
available -- remote coasts, small island groups, the shallow water where local knowledge is the only
chart there is. This lets you build your own coverage for exactly the places **you** care about, at
the level of detail **you** choose, and carry it aboard on an ordinary CF card.

It sits alongside your existing charts on a chart card, or works on its own on a blank card with no
charts on it at all.

## What it looks like on the plotter

The photography composites **underneath** everything you navigate by. The chart's land and sea
fills turn translucent so the imagery shows through, while your boat, the cursor, waypoints,
routes, tracks, depth figures, buoyage, and labels all stay crisp and opaque on top. You are not
trading the chart for a photograph -- you are seeing both at once.

Where you have no imagery, the chart simply looks the way it always has.

<!-- SCREENSHOT: zoomed in on a pass or reef, showing symbology crisp over photo -->

## What you will need

1. **The custom firmware**, installed on the plotter -- see [Custom Firmware](custom_firmware.md).
2. **`AERIAL.COE`** -- the extension itself, downloaded from GitHub (below).
3. **A CF card** with room on it -- either alongside your charts on a chart card, or a blank card
   with nothing else on it. **Not a Navionics Platinum card**, though; see *Limits worth knowing*.
4. **`.RCT` files** -- the imagery, which you build yourself in **chartMaker**.

Items 2 and 4 are both required. `AERIAL.COE` is the code and the `.RCT` files are the imagery, and
the feature does nothing at all unless the card carries both.

navMate does not put any of this on a card for you, and does not carry imagery of any kind. It
builds the firmware; the rest is yours to assemble. That is the same arrangement as the firmware
itself, and for the same reason:

> **navMate ships no firmware. chartMaker ships no imagery.** You supply the Raymarine package, you
> choose the imagery source, and you build both yourself.

## Step 1 -- Get AERIAL.COE

`AERIAL.COE` is a small file that lives on the CF card, not in the firmware. The plotter looks for
it at startup and loads it if it is there. Download it from:

**https://github.com/phorton1/base-apps-navMate** (the `mods` folder)

Keeping it on the card rather than baked into the firmware is deliberate: **the firmware you flashed
never changes**, and turning the feature off is a matter of renaming or deleting one file.

## Step 2 -- Build your imagery with chartMaker

**[chartMaker](https://github.com/phorton1/base-apps-chartMaker)** is a separate free application
that builds offline satellite chartsets. You draw the regions you care about on a map, say how much
detail each one deserves, point it at an imagery source of your choosing, and it produces `.RCT`
files for your plotter.

chartMaker has its own user manual; this page only describes what to do with the files once you
have them.

### Card space is the thing to think about

A CF card is small and photography is large, and that single fact shapes how you should use this.

It is why chartMaker builds **separate regions** rather than one enormous chartset. Each region is
its own `.RCT` file, and the card carries whichever ones you want. You mix and match for the cruise
you are actually doing: the whole coast at modest detail, plus three or four anchorages and passes
at the highest detail you can get. Next season, a different set.

There is no manifest and nothing to configure. The plotter reads **whatever `.RCT` files it finds**
on the card, so adding and removing coverage is a matter of dragging files on and off. Any subset
is a valid set.

## Step 3 -- Lay out the card

```
AERIAL.COE                 the extension (card root)
RASTER\                    a folder named RASTER, at the card root
    BOCAS.RCT              your imagery -- as many or as few as you like
    ESCUDO.RCT
    ...
```

Put the card in the unit and restart it.

## Turning it off

Remove either half and restart. Renaming or deleting `AERIAL.COE` takes out the code; emptying or
removing the `RASTER` folder takes out the imagery. Either way the plotter runs the stock display
path exactly as if the files had never been there. Nothing needs to be un-installed and the firmware
does not change.

This is worth knowing because it makes the whole feature a **card-level decision, reversible in
seconds** -- swap cards, and the plotter behaves differently.

## An interesting one: two networked plotters

If you have a master and a slave E-Series on a network, there is an arrangement worth knowing about.

The **master** holds the chart card, along with a modest set of `.RCT` regions, since most of that
card is already spoken for. The **slave** holds a plain, high-capacity CF card with no charts on it
at all: it receives the charts over the network from the master, which leaves its entire card free
for imagery. The slave can then carry substantially more coverage, and at greater detail, than the
master ever could.

So the master gives you the chart, and the slave beside it gives you a far richer photographic view
of the same water. Setting up the network is covered in
[Connecting an E-Series](connecting_eseries.md).

<!-- SCREENSHOT: master and slave side by side, chart on one, deep aerial detail on the other -->

## Troubleshooting

**Nothing appears.** `AERIAL.COE` hooks into the plotter's display machinery as soon as it loads,
but it draws nothing until it finds imagery it can actually use. Check, in order:

- **The firmware.** The unit must be running the custom firmware. Check its **Unit Info** screen, or
  use **ESeries -> About ESeries** in navMate.
- **The card layout.** `AERIAL.COE` at the card root, and a folder named `RASTER`, also at the root,
  holding the `.RCT` files.
- **The `.RCT` files themselves.** Each one is checked before it is used, so a file that is not a
  chartMaker-built `.RCT` is ignored no matter what it is named.
- **A matched pair.** `AERIAL.COE` and the firmware belong together. An extension built for a
  different firmware will not load. If you re-flash, take `AERIAL.COE` from the same place you got
  the firmware.
- **A restart.** The extension is loaded at startup, so anything you change on the card takes effect
  on the next boot.

**Imagery appears in some places but not others.** That is normal. You see photography where one of
your regions covers the view, at the zoom levels that region was built for; everywhere else the
chart looks exactly as it always has. Choosing regions and zoom levels is covered in chartMaker's
own manual.

## Limits worth knowing

- **Both parts must be present.** The feature does nothing unless `AERIAL.COE` is on the card *and*
  a `RASTER` folder on that card holds at least one usable `.RCT` file. Either one alone does
  nothing visible.
- **Do not put `AERIAL.COE` on a Navionics Platinum card.** The `.RCT` files and the `RASTER` folder
  are inert -- any chart card simply ignores them. The extension is a different matter: it is code,
  loaded and run by the plotter, and it hooks into the same display machinery a Platinum card's own
  aerial photography uses. That combination has never been tested. Keep the extension off Platinum
  cards.
- **Imagery is a picture, not a survey.** It is undated, uncorrected, and shows the water on the day
  it was photographed. Sandbars move. Use it for context and for what the chart does not show --
  never as your authority for depth, for clearance, or for a safe course.
- **You supply the source.** chartMaker works with imagery services you choose, on whatever terms
  those services set. That choice, and its licensing, is yours.
- **The plotter is doing real work.** Decoding photography on twenty-year-old hardware is not free.
  Charts, menus, and alarms stay responsive, but imagery may take a moment to fill in after a large
  pan or zoom.

**Back to:** [Using Your E-Series](using_eseries.md)
