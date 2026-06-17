# Mods

**[Home](readme.md)** --
**[containers](containers.md)** --
**[installer](installer.md)** --
**[bootloader](bootloader.md)** --
**[modification](modification.md)** --
**mods**

**[Up](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**Deployment** --
**[Tools](../tools/readme.md)** --
**[Cleanroom](../cleanroom.md)**

The **catalog of specific modifications**. [modification](modification.md) is the
generic *process* -- the record format, the build pipeline, the version formula, the
safety floor. This page is the *instances*: which mods exist, what version each
package carries, what each package contains, and what has been confirmed on hardware.
Each mod has its own design page.

## The mods

| mod | what it is | enables | design |
|---|---|---|---|
| **mod001** | a remote peek / poke / call diagnostics primitive on the unadvertised Diagnostics service (UDP 6667), built by reclaiming a pair of dead helper routines | the live-device read/write channel the project reads hardware with ([tools/diagnostics](../tools/diagnostics.md)); the substrate under the config backup/restore library ([cleanroom/e80Config_API](../cleanroom/e80Config_API.md)) | [mod001](mod001.md) |
| **mod002** | a fast, tear-free full-screen capture ("grab") over the Diagnostics TCP port (6668), built by reclaiming a dead handler body; also stamps the running app version | the live-screen capture library ([cleanroom/e80ScreenGrab_API](../cleanroom/e80ScreenGrab_API.md)) | [mod002](mod002.md) |

The `mod001` name was **reused**: the *first* mod001 (a firmware enable-gate flip) was
proven to install but reached a dead end and was reverted; the slot was re-scoped to
the diagnostics primitive. That history is in [mod001](mod001.md).

## Version assignments

[modification](modification.md) defines the *formula* -- each new mod takes the next
number above stock, the gaps are intentional, the label is display + installer-ordering
only (never a schema/persistence version), and downdate is supported. The assignments:

| version | package / state |
|---|---|
| 5.69 | stock E80/120_App (and the original, reverted mod001, built at 5.69) |
| 5.70 | reserved (intentional gap) |
| 5.71 | standalone mod001 (peek / poke / call); its version records stamp `569 -> 571` |
| 5.72 | the mod002 package = mod001 + mod002; the version stamp chains `571 -> 572` |

## Package composition

Mods are **byte-disjoint** -- each patches its own regions -- so a package is just a
linear chain of `apply_mod` steps over a chosen base binary, and one package can carry
one mod or several. What we actually build:

| package | version | mods included |
|---|---|---|
| `E_App_Upg_Uni.mod002.pkg` | 5.72 | mod001 + mod002 |

The aggregation is **client-driven**: a client that wants two capabilities (e.g. the
config backup *and* the screen grab) needs firmware carrying both mods, so the shipped
package carries both. This is the *binary / package* view -- the only relationship
between two byte-disjoint mods is that they coexist in one image. The one exception is the
**version stamp**: each mod stamps the app's reported version to match its own package, so
stacking them chains the stamp (stock `569` -> mod001 `571` -> mod002 `572`) -- the only bytes
two mods share, which `apply_mod`'s `old_hash` makes explicit and verified. (The Ghidra program
lineage is a different projection, kept in the project's internal notes, not here.)

## Hardware confirmations

- **The build/flash pipeline is proven on a real unit** -- a resized / recompressed
  package installs and boots, and a relabel is booted-visible (Unit Info shows the new
  build machine + date). The container-level proof is in [installer](installer.md); the
  pipeline in [modification](modification.md).
- **mod001** -- the earlier behavioral-edit mod001 was installed and booted on hardware
  (the first end-to-end proof of the scheme); the diagnostics primitive is in active use
  against real units. See [mod001](mod001.md).
- **mod002** -- proven end-to-end on a real E80: a single GRAB command returned a full
  atomic snapshot that the host composited to a correct image; the reflashed 5.72
  package shows the new version + build stamp. See [mod002](mod002.md).

---

**Next:** [mod001](mod001.md) ...
