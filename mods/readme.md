# E80 / E120 Firmware Modifications

This folder holds the **modification recipes** and **source code** for a set of
additive modifications to the Raymarine E80 / E120 multifunction-display
application firmware, together with the ABI header and overlay sources needed to
write an extension of your own.

The modifications are documented in detail in the
[**E80 firmware documentation**](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/e80_firmware/deployment/mods.md),
which describes the container and installer formats, the modification process,
and a design page for each individual mod.

## What is here

| pattern           | what it is                                                        |
|-------------------|-------------------------------------------------------------------|
| `e80_modNNN.txt`  | a modification recipe -- the per-region edit records for one mod   |
| `*.c`             | the authoring source a recipe was generated from                   |
| `e569.h`          | the firmware ABI -- addresses and call signatures an extension uses |
| `*.h`             | shared headers for the overlay scheme                              |
| `*.COE`, `*.COV`  | built code overlays, loaded from the CF card at runtime            |

Each `e80_modNNN.txt` corresponds to a design page in the documentation linked
above.

## What is not here, and why

No Raymarine code appears in this folder, in any form. That is a deliberate,
verifiable property of how the recipes are built:

- **No firmware.** No Raymarine firmware artifact, and no produced modified
  image or package, is distributed here. You supply your own lawfully-obtained
  firmware; the tooling never carries it.
- **No original bytes.** A recipe identifies the region it modifies by a
  **SHA-256 hash** of the stock bytes it overwrites -- a fingerprint, which is a
  fact about the image -- never by an embedded copy of those bytes. The hash
  doubles as a safety check: an apply against the wrong base aborts cleanly.
- **No disassembly.** The recipes carry the *new* bytes, which are our own
  compiled code, placed in reclaimed or unused regions. Addresses, offsets, and
  call signatures are facts about the artifact, in the same sense that a
  register address in a datasheet is a fact.

## Writing your own extension

`e569.h` declares the firmware entry points an extension can call -- their
addresses, signatures, calling conventions, and behavior. Combined with the code
overlay scheme, it is enough to write, build, and load your own code into a
running unit. The overlay sources here are the worked example.

The header is deliberately scoped to what an extension actually needs to call.
It is an ABI, not a catalog of the firmware.

## License

The files in this folder are licensed under the **MIT License** -- see
[LICENSE.TXT](LICENSE.TXT) in this directory, which governs these files in place
of the repository-level license.

MIT was chosen deliberately. The point of publishing an ABI is to let other
people build on it, and a copyleft license on an interface header would put an
obligation on every extension written against it.

## Disclaimer

This software is provided as-is, with no warranty of any kind, as set out in
LICENSE.TXT.

Modifying the firmware of a chartplotter is done entirely at your own risk. It
is not supported, sanctioned, or endorsed by the manufacturer, and it will not
be supported by them afterward. A failed, interrupted, or mismatched install can
leave a unit inoperable. Reinstalling a stock package returns a unit to the
original firmware version, but no recovery path is guaranteed.

Anyone using this material is responsible for their own equipment and for their
own decisions about what to run on it.

## Not affiliated with Raymarine

This is independent work. It is not affiliated with, authorized by, endorsed by,
or connected to Raymarine, Teledyne FLIR, or any of their subsidiaries or
affiliates. "Raymarine", "E80", and "E120" are used only to identify the
hardware this material interoperates with, and remain the property of their
respective owners.
