# navMate User Manual - Organizing Data

**[Home](readme.md)** --
**[Getting Started](getting_started.md)** --
**[The Map](the_map.md)** --
**Organizing Data** --
**[Copy, Cut & Paste](copy_cut_paste.md)** --
**[Multi-Editor](winMultiEditor.md)** --
**[Import & Export](import_export.md)** --
**[FSH Files](winFSH.md)** --
**[Connecting an E-Series](connecting_e80.md)** --
**[Using Your E-Series](using_e80.md)**

The **database window** is where navMate really earns its keep. It shows your entire
navigation knowledge base as a tree of folders that you build and arrange however makes
sense to you.

![example_database.jpg](images/example_database.jpg)

## The four kinds of things

Everything in navMate is one of four kinds of object:

- **Waypoints** -- a single marked position (an anchorage, a hazard, a dock, a favorite
  fishing spot). Each carries a name, a position, a symbol, a color, and an optional depth
  and comment.
- **Routes** -- an ordered list of waypoints that make up a planned passage.
- **Tracks** -- the recorded trail of where the boat actually traveled.
- **Folders** -- containers you create to organize the above.

navMate has two kinds of folder. A **branch** is a general-purpose folder; it can hold
waypoints, routes, tracks, and other branches, nested as deep as you like. A **group** is a
special folder that holds *only* waypoints -- it matches the way a Raymarine E-Series
organizes its waypoints, so groups are what travel cleanly to and from the plotter.

## Building your hierarchy

This is the part no chartplotter does well. You are free to organize your data into folders
within folders, arranged any way you think about your sailing -- by ocean, by year, by boat,
by "places I love" versus "places to avoid." A lifetime of marks that would be an
unmanageable flat list on a plotter becomes something you can actually find your way around.

To build it, right-click a folder (or the empty top of the tree) and choose **New -> Branch**,
**Group**, **Route**, or **Waypoint**. You move things around with copy, cut, and paste --
that is the [next chapter](copy_cut_paste.md).

## Editing an item

Click any item and its details appear in the **editor panel** on the right. What you can edit
depends on what you selected:

- a **waypoint** -- name, comment, latitude/longitude, type, symbol, color, and depth;
- a **route** or **track** -- name, comment, and color;
- a **folder** -- name and comment.

Positions can be typed as plain decimal degrees or as degrees-and-minutes; navMate shows you
the converted value as you type. Change anything and the **Save** button lights up; click it
to write the change.

## Visibility checkboxes

Every item also has a checkbox that controls whether it shows on the map (see
[The Map](the_map.md)). Checking a folder shows or hides everything inside it at
once.

## Keeping your work safe

navMate keeps a local history of your database so you can always step back. When you have made
changes, **Database -> Commit** saves a snapshot (you are asked for a short note), and
**Database -> Revert** rolls back to the last snapshot if you change your mind.

A few conveniences worth knowing:

- You can open **more than one database window** at a time (**View -> Database**) -- handy for
  copying between two parts of a large hierarchy.
- **Save / Restore Outline** remembers which folders you had expanded.
- **Save / Restore Selection** remembers a named set of selected items, so you can recall, say,
  "my Bahamas trip" without re-finding everything.

**Next:** [Copy, Cut & Paste](copy_cut_paste.md)
