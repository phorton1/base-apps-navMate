# navMate User Manual - Import & Export

**[Home](readme.md)** --
**[Getting Started](getting_started.md)** --
**[The Map](the_map.md)** --
**[Organizing Data](organizing_your_data.md)** --
**[Copy, Cut & Paste](copy_cut_paste.md)** --
**[Multi-Editor](winMultiEditor.md)** --
**Import & Export** --
**[FSH Files](winFSH.md)** --
**[Connecting an E-Series](connecting_eseries.md)** --
**[Using Your E-Series](using_eseries.md)** --
**[OpenCPN](opencpn.md)**

navMate is happy to exchange data with the other tools you already use. It speaks two common
file formats -- **KML** (Google Earth) and **GPX** (GPS devices and apps) -- plus a plain-text
backup of your whole database.

## Google Earth (KML)

Google Earth is a wonderful way to **look at, annotate, and share** your navigation data over
high-resolution imagery -- and a handy way to **bring existing data in** from Google Earth or any
program that writes KML. Think of it as two separate one-way trips rather than a live link: data
out for viewing, and data in for onboarding.

**Sending your data out to view:**

- **Database -> Export KML** writes your entire database to a `.kml` file. You can also
  right-click any folder and choose **Export KML file** to export just that part.
- Open the file in Google Earth, look around, annotate it, and share it.

Google Earth is a great place to *view* your data, but it is not meant to edit your navMate
collection -- the record stays in navMate. If you later re-import a file navMate wrote, navMate
recognizes the items it originally exported (by a hidden identity tag) and updates them in place
rather than duplicating them; treat that as a convenience for re-onboarding, not as a way to edit
your database from inside Google Earth.

**Bringing data in:**

- **Database -> Import KML** reads a `.kml` file into your database.

What comes in cleanly:

- **Placemarks** (single points) become **waypoints**.
- **Paths / lines** become **tracks**.
- **Folders** become folders.

A file that navMate itself exported carries extra hidden tags, so its waypoint **types** and
**symbols** come back exactly as they were. A KML from Google Earth or another program does not have
those tags, so navMate makes a reasonable guess at each waypoint's type and symbol from its name and
sensible defaults -- everything still imports, but you may want to touch up a few symbols afterward.


## GPS files (GPX)

GPX is the common language of handheld GPS units, phone apps, and other planning software. To
bring a file in, right-click a folder in the database tree and choose **Import GPS file**.
navMate reads `.gpx` directly, and `.gdb` (Garmin) files too when the free `gpsbabel` tool is
installed. To send data out to another program, KML is the most capable format navMate exports.

Treat GPX as a one-time **handoff** between programs, not a live sync. navMate carries a hidden
identity tag through GPX, so re-importing a file navMate wrote reuses the original items instead of
duplicating them -- but a GPX round-trip flattens your folder hierarchy and does not carry every
detail, and files from other programs come in as new items. If you want a genuine two-way connection
with a charting program, that is what the [OpenCPN](opencpn.md) plugin is for; GPX is for the
occasional handoff.

## Plain-text backup

For a complete, human-readable backup, **Database -> Export to Text** writes your whole database
to a `.txt` file, and **Import from Text** restores it. This is a belt-and-suspenders backup, in
addition to simply copying your `navMate.db` file.

**Next:** [FSH Files](winFSH.md)
