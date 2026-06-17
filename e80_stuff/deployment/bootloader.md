# Bootloader

**[Home](readme.md)** --
**[containers](containers.md)** --
**[installer](installer.md)** --
**bootloader** --
**[modification](modification.md)** --
**[mods](mods.md)**

**[Up](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**Deployment** --
**[Tools](../tools/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The inferred stage-0 bootstrap: the code that runs from reset, owns the
NOR flash layout, and performs the **inflate-to-RAM** primitive that both
the installer and normal boot depend on. This doc is largely *presumed
functionality* -- the stage-0 code itself is not in any artifact we hold
(see "Artifact horizon" below). What is solid is stated as such; what is
inferred is marked.

## Why there must be a stage-0 we cannot see

`e80.bin` contains none of the update-loading vocabulary -- no `autorun`,
`.dob`, `DB1`, `DL1`, or `upgrade` strings. So the running application is
not what detects a CF card or chain-loads the installer. Something earlier
does, and it is in neither `e80.bin` (the *output* of inflation) nor the
install-time stubs (which run only during an upgrade). This earlier code
is **stage-0**.

## Where stage-0 lives (inference from negative space)

The internal NOR is 32 MB (two AM29LV128M, 16 MB each). The installer's
write actions populate these offsets (see [installer](installer.md) for
the decode):

```
NOR base 0x50000000   (32 MB total)
  +0x000000 .. 0x070000  (448 KB) -- written by NOTHING in the package
  +0x070000              ClearFlash erase target (contents not identified)
  +0x080000              install-time config seed (Reset2FSH writes ~15 KB)
  +0x0a0000              the application (compressed)
  +0xc40000             demo content (ends ~0xcd8000)
  +0xcd8000 .. 0x2000000 (~19 MB) -- written by NOTHING in the package
```

The bottom **448 KB (`0x50000000 .. 0x50070000`) is written by no action
in the upgrade package.** That is the signature of a protected boot region:
the place stage-0 itself lives, which the package deliberately never
rewrites so an upgrade cannot brick the bootloader. NOR is memory-mapped
and execute-in-place, so the ARM can fetch from it at reset (the reset
vector aliased/remapped into this region).

This is an **inference from what the package does not touch**, not a
readout. Confidence is high (it explains why upgrades are non-destructive
and why the application is not at offset 0), but the code has not been read.

## The NOR residency map (what permanently lives in flash)

After an install, NOR holds the following. Only the **install-written**
regions have decoded start addresses; the region above the demo content the
installer does not touch -- it is likely NOR managed by the runtime (see
[runtime](../architecture/runtime.md)).

| NOR region | offset | contents | accessed as |
|------------|--------|----------|-------------|
| boot region | `0x50000000` | **stage-0** (inferred) | executed at reset |
| config seed | `0x50080000` | small install-time seed (~15 KB written) | data |
| application | `0x500a0000` | compressed application image | inflated to RAM at boot |
| demo content | `0x50c40000` | demo media (~625 KB) | data, read by application |
| runtime region | above the demo region | likely NOR managed by the runtime | not written by the installer |

The install seed at `0x50080000` is just a ~15 KB factory-reset baseline
(Reset2FSH), not a live store. Everything above the demo region
(`~0x50cd8000 .. 0x52000000`) the package leaves alone -- likely NOR managed
by the runtime; its driver and bounds are a runtime concern (see
[runtime](../architecture/runtime.md)).

Only the **application** is inflated and executed. The config and demo
regions are **data** the running application reads (settings / navigation data via
the runtime filesystem; demo media drawn by the application). There is no parade of
blocks each inflating to its own RAM home -- one inflate (the application), then the
application reads the rest. Region *start* addresses are code-confirmed
(installer.md); the runtime filesystem's driver and bounds are a runtime
concern, covered in [runtime](../architecture/runtime.md).

## The inflate-to-RAM primitive (one mechanism, two uses)

The decompressor that turns a compressed image into runnable code is used
in two situations:

1. **Installer boot** (CF card present): stage-0 finds `autorun.dob` on the
   CF, inflates its gzip payload to RAM, and runs it transiently. This is
   **hardware-confirmed non-destructive**: running the installer and
   rebooting out of it leaves the already-installed E80 firmware intact, so
   `autorun.dob` is run from RAM, never flashed over the application.
2. **Normal boot** (no CF, the everyday case): stage-0 inflates the
   installed application from NOR `0x500a0000` into RAM and jumps to it.

Both require the same primitive: "find a compressed image, inflate it to
RAM, jump." The application must be inflated because it cannot run in place
(it is gzip-compressed in NOR) and is far too large to store uncompressed
in the 32 MB part (it inflates to ~23.8 MB; the application NOR slot is only
~11.6 MB before the demo region). So at normal boot, exactly one image is
inflated: the application, to RAM **`0x00000000`** (the base `e80.bin` is built
for -- see [runtime](../architecture/runtime.md)).

## What stage-0 must know

- Where the application is in NOR (`0x500a0000`) -- or how to find it (scanning NOR
  for the `DB1 `/loader-stub signature is the plausible implementation,
  mirroring how it scans the CF for `autorun.dob`).
- Where to place the inflated image (RAM `0x0`) and to jump there.

Demo mode and Factory Reset do **not** require boot-loader knowledge: demo
is a persistent flag the already-running application reads (hardware-confirmed --
the application runs underneath the slideshow, simulating); Factory Reset is most
likely a similar early-application check or a separate install action, not a
distinct boot image. There is one application image; behaviour is selected
by flags and by which data regions the application reads.

## Artifact horizon (what we cannot resolve from what we hold)

The stage-0 code -- the reset prelude, the CF/NOR image finder, the
boot-time inflater, the application-location knowledge -- is in **none** of our
artifacts. It is not in `e80.bin`, `autorun.bin` (itself a thing stage-0
runs), or the action stubs. It is inferred to sit in the protected NOR boot
region (`0x50000000`), or possibly Pandora SoC masked ROM. Reading it would
require a raw dump of that NOR region from a live unit (if reachable via a
raw flash read) or JTAG. Every chain of boot reasoning bottoms out here:
the behaviour is tightly constrained by evidence, the *code* is beyond the
horizon.

(The install-time decompressor and the boot-time inflater are distinct: the
boot inflater is not proven to be the install loader stub, and is treated as
stage-0.)

---

**Next:** [modification](modification.md) ...
