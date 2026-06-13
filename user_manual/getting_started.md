# navMate User Manual - Getting Started

**[Home](readme.md)** --
**Getting Started** --
**[The Map](the_map.md)** --
**[Organizing Data](organizing_your_data.md)** --
**[Copy, Cut & Paste](copy_cut_paste.md)** --
**[Multi-Editor](winMultiEditor.md)** --
**[Import & Export](import_export.md)** --
**[FSH Files](winFSH.md)** --
**[Connecting an E-Series](connecting_e80.md)** --
**[Using Your E-Series](using_e80.md)**

This chapter gets navMate onto your computer and takes you on a first look around. You do
**not** need a chartplotter connected for any of this -- navMate is fully useful on its own.
Connecting an E-Series plotter comes later, in [its own chapter](connecting_e80.md).

## 1. Install navMate

Run the navMate installer and follow the prompts. Everything navMate needs is included -- you
do not need to install Perl or any other software first.

The first time it runs, navMate creates a folder for your data under your Windows **Documents**
folder, at `Documents\phorton1\navMate`. Your entire knowledge base lives in a single database
file there (`navMate.db`), which makes it easy to find and easy to back up: copy that one file
and you have copied everything.

<!-- [SCREENSHOT] images/installer.png -- the navMate installer welcome page -->

## 2. First run

The first time navMate starts you will see:

- a **console window** -- text and status messages; you can mostly ignore it; and
- the **database window** -- your navigation data shown as a tree.

The **map** does not open on its own. It opens in your web browser as soon as you show
something on it (see [The Map](the_map.md)), or whenever you choose **View -> Open Map**.

On a brand-new install the database starts nearly empty. That is expected -- the next chapters
show you how to fill it.

<!-- [SCREENSHOT] images/first_run.png -- the database and console windows on first launch -->

## 3. Try it without a plotter

The quickest way to see navMate work is to bring in some data you already have:

- If you use **Google Earth**, export a `.kml` file and choose **Database -> Import KML**.
- If you have a **GPS file** (`.gpx`) from another device or app, right-click a folder in the
  database tree and choose **Import GPS file**.
- Or simply right-click and choose **New -> Waypoint** to drop a mark by hand.

Tick the checkbox next to anything in the tree and it appears on the map. That is the
whole loop -- organize on the left, see it on the right -- and it works with no boat, no plotter,
and no network in sight.

**Next:** [The Map](the_map.md)
