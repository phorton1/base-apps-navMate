# navMate User Manual - Import & Export

**[Home](readme.md)** --
**[Getting Started](getting_started.md)** --
**[The Map](the_map.md)** --
**[Organizing Data](organizing_your_data.md)** --
**[Copy, Cut & Paste](copy_cut_paste.md)** --
**[Multi-Editor](winMultiEditor.md)** --
**Import & Export** --
**[FSH Files](winFSH.md)** --
**[Connecting an E-Series](connecting_e80.md)** --
**[Using Your E-Series](using_e80.md)**

navMate is happy to exchange data with the other tools you already use. It speaks two common
file formats -- **KML** (Google Earth) and **GPX** (GPS devices and apps) -- plus a plain-text
backup of your whole database.

## Google Earth (KML)

Google Earth is a wonderful way to look at, annotate, and share your navigation data over
high-resolution imagery.

- **Database -> Export KML** writes your entire database to a `.kml` file. You can also
  right-click any folder and choose **Export KML file** to export just that part.
- Open the file in Google Earth, look around, even tidy things up there.
- **Database -> Import KML** brings a navMate KML file back in. The re-import is **additive and
  matched by identity** -- navMate updates the items it recognizes and adds new ones, rather
  than wiping out what you already have.

<!-- [SCREENSHOT] images/export_kml.png -- a navMate export opened in Google Earth, showing
     waypoints and a route -->

## GPS files (GPX)

GPX is the common language of handheld GPS units, phone apps, and other planning software. To
bring a file in, right-click a folder in the database tree and choose **Import GPS file**.
navMate reads `.gpx` directly, and `.gdb` (Garmin) files too when the free `gpsbabel` tool is
installed. To send data out to another program, KML is the most capable format navMate exports.

## Plain-text backup

For a complete, human-readable backup, **Database -> Export to Text** writes your whole database
to a `.txt` file, and **Import from Text** restores it. This is a belt-and-suspenders backup, in
addition to simply copying your `navMate.db` file.

**Next:** [FSH Files](winFSH.md)
