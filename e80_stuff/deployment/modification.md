# Modification

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

The proven scheme for producing a **modified firmware image** and installing it
on hardware Patrick owns: how an edit is recorded, how the package is rebuilt to
pass the manufacturer's own gates, why it is safe to flash, and what has been
confirmed on a real unit. This is the *vehicle*; the *instrument* it currently
carries (the diagnostics peek/poke/call channel) is
[tools/diagnostics](../tools/diagnostics.md).

This doc builds on [installer](installer.md) (the container/checksum mechanics)
and [containers](containers.md) (the byte-level facts).

---

## 1. Posture

Modification here is bounded, and the bounds are part of the method.

- **Cooperative with the design, not subversive of it** -- it works through the
  manufacturer's own installer and satisfies the installer's own integrity
  checks, reaching only states the shipped firmware already supports.
- **Additive, carrying nothing of the manufacturer's** -- the new bytes are the
  modder's own work; the recipe verifies each region it overwrites by a *hash*,
  never a copy of the original code (section 2). No manufacturer image, package,
  or derivative is redistributed.
- **On the owner's own hardware, from the owner's own firmware** -- the tooling
  never carries firmware; it transforms a copy the owner already lawfully holds.
- **In service of preservation** -- interoperability and data backup -- with an
  accompanying disclaimer, in the spirit of the device's own limitations-on-use
  notice.

There is **no technical protection measure** to circumvent. The update path
gates on two **additive byte-sum checksums** only -- no CRC, no signature, no
crypto (see [installer](installer.md)). Recomputing the sums after an edit is
arithmetic, not circumvention. A build only ever fixes length fields and
recomputes those byte-sums.

## 2. The edit record (one record, two engines)

A modification is captured as a serialized **edit record**, not as a forked binary. The record
is **publishable by construction**: it carries a *hash* of each region it overwrites -- never the
original bytes -- plus the new bytes it writes (which are our own work) and, optionally, the
Ghidra annotations that describe them. Two engines apply the same record, so they cannot drift:

- `scripts/apply_mod.pl <NNN> <target.bin>` -- applies record `NNN` to a binary (the **MOD**
  step): for each edit it **hashes the target region and checks it against the record's hash**,
  then writes the new bytes. It verifies every region before writing any, and is idempotent.
  Lineage-blind -- copy the base binary to the target first (section 3), and it patches what you
  point it at. It ignores the annotation directives.
- `scripts/apply_mod.py` -- the Ghidra (Jython) counterpart: applies the **same byte edits** to
  the loaded program, *and* lays down the record's annotation layer (below), so the program reads
  correctly straight from the recipe with no hand-replay after a revert. One record, two engines.

Edits are **length-preserving** -- the new bytes are exactly as long as the region they replace
-- so surrounding bytes are untouched and every downstream offset is unchanged.

### Record file format

A record is a human **synopsis** (the mod's purpose + `docs/public`-relative links), then a
sequence of **edit blocks**, optionally interleaved with **annotation directives**. An edit block
names its target and carries the bytes to write as an inline assembly listing -- the listing and
the bytes are **one artifact**, never two copies that can drift:

```
edit <address> <file_offset> <length> <old_hash>
    <one-line rationale>                       (optional; indented)
new
    # free banner / comment lines               (reader-only)
    # label:                                    (a bare "identifier:" -> a Ghidra label)
    <hex>   # <disassembly>  ; <meaning>        (the bytes; the comment is reader-only)
    ...
end
```

- **`edit`** names the target on one mandatory line: the **address**, the **file offset**
  (identical for this image), the region **length**, and the **`old_hash`**. The hash is how the
  applier confirms it is overwriting the *correct* original code -- computed against the reader's
  own firmware -- **without the record ever carrying that original code**.
- The optional **indented line** below `edit` is a one-line **rationale**; `apply_mod.py` lays it
  down as an EOL comment at the patch address (the per-edit stamp). It sits on its own line so it
  never tails the long hash.
- **`new` ... `end`** carries the **bytes to write** as an inline disassembly listing. The hex is
  the **single source of truth** -- nothing duplicates it, and a written region's hash is
  regenerable from it, so no "new hash" is stored. Within the listing only one thing crosses into
  Ghidra: a standalone **`# label:`** line (a bare `identifier:`) becomes a label at the next
  instruction. Every other comment -- the `# disassembly` and `; meaning` trailing a hex line, and
  the free banner/prose lines -- is **reader-only**: the recipe's annotated listing for a human,
  which Ghidra does not ingest (it disassembles the bytes itself).

There is **no `old` section and no original bytes** -- verification is by `old_hash` alone. Both
engines **verify every** region's hash **before writing any** bytes, and are **idempotent**
(re-applying an applied record is a no-op).

**`old_hash`** is the **SHA-256 of the original region's bytes** -- the full digest (64 hex), the
same fixed width regardless of region size. Checking it against the reader's own firmware before
any write means a record can never be applied to the wrong firmware or the wrong region; and
because it is a hash, the record never redistributes the manufacturer's original code.

### Annotation directives (the Ghidra layer)

A byte patch makes the *binary* correct but leaves the *Ghidra program* unannotated. So a record
may also carry **address-keyed annotation directives** -- `func` (create + name a routine with its
extent), `sig` (its prototype), `pre` / `plate` / `eol` and the other comment kinds (at *any*
address, including a function the patch only *affects*), `name` / `label`, and `local` / `param`.
`apply_mod.py` applies them after the bytes; `apply_mod.pl` ignores them. By convention they sit
next to the edit they concern -- function naming on its defining edit, an off-patch plate near the
edit that invalidated it -- but each carries its own address, so placement is cosmetic. A mod with
no directives simply patches bytes; simple mods stay simple.

The directive **grammar**, the full annotation vocabulary, and **how deep to annotate a given
mod**, are specified in [tools/ghidra](../tools/ghidra.md). The *specifics* of each mod -- its
design, the version it carries, what it unlocks -- live in the mod catalog ([mods](mods.md)).

## 3. The build pipeline (three decoupled steps)

Each mod has its **own binary**, `modified/e80_mod<NNN>.bin`, preserved as a
layer so any package is rebuildable from its own image at any time. The pipeline
is three independent, separately-run steps; the **only** step that knows about
lineage is the copy:

1. **COPY (lineage).** `cp modified/e80_mod<PREV>.bin modified/e80_mod<NNN>.bin`
   -- start the new mod's binary from whatever base you choose (normally the
   previous mod's output; a different base is a "branch"). The **first** mod copies
   the stock application image -- `cp bin/e80.bin modified/e80_mod001.bin` -- the
   read-only extracted stock E80/120_App image (see [containers](containers.md)).
   This is the only place a lineage/branch decision is made.
2. **MOD.** `apply_mod.pl <NNN> e80_mod<NNN>.bin` (section 2) -- apply record
   `NNN`'s byte edits to that binary.
3. **BUILD.** `build_mod_pkg.pl [--version <v>] e80_mod<NNN>.bin mod<NNN>` -- wrap the
   patched binary into `modified/E_App_Upg_Uni.mod<NNN>.pkg`. The build is
   **lineage-blind**: it takes an explicit input binary, an output label, and an
   optional version, and packages whatever it is handed -- it has no idea which
   mod, or where the binary came from. (The label is just the `.pkg` name suffix,
   so a branch build is `build_mod_pkg.pl e80_branchX.bin branchX`.) If `--version`
   is given (e.g. `--version 5.72`) it relabels the DOB version descriptor (see
   "Version labeling" below); omit it to keep the base version.

The extract, apply, build, and verify logic lives in the cleanroom library
`e80Firmware.pm` -- the in-process engine navMate uses; `build_mod_pkg.pl`,
`apply_mod.pl`, and `verify_db1_checksums.pl` are thin command-line wrappers over
it (one core, two front-ends). `build_mod_pkg.pl` supersedes the one-time
`_rebuild_pkg.pl` / `_relabel_pkg.pl` test harnesses (which first proved the
tooling reproduces Raymarine's exact bytes and that a relabel is booted-visible).
The BUILD step:

1. **re-gzips** the input application image;
2. **rebuilds the DL1** around it, handling the full length/checksum cascade --
   the E80 record's gzip length and `dword[3]`, App2FSH's `dword[3]` + `word1` +
   its 4-byte length-prefix, the downstream `Demo2FSH`/`DemoSlides` offset
   shift, and both byte-sum checksums per child -- with a **structural audit**
   that replays the installer's DOB walk and asserts every block lands on `DB1 `
   magic (see [installer](installer.md) for the cascade detail);
3. **relabels** the build descriptors -- build machine / builder signature (header
   `+0x60`) and build date (current GMT, `+0x40`) -- into the DL1 header and all
   seven DB1 child headers, then recomputes the checksums in span-safe order;
4. emits `modified/E_App_Upg_Uni.<label>.pkg`.

`scripts/verify_db1_checksums.pl [package.pkg]` is the standalone 14/14 checksum check (it
defaults to the stock package).

**Building from a different layout (or from your own firmware).** The steps above resolve to
this repository's own `bin/` (stock package) and `modified/` (work dir), located relative to
the scripts. To build elsewhere -- from a separately-held stock package and work directory,
with no `bin/` or `modified/` present -- pass the locations explicitly; the recipe is otherwise
identical:

- `build_mod_pkg.pl --stock <stock.pkg> --outdir <dir> [--builder <handle>] [--version <v>] <input.bin> <label>`
- `verify_db1_checksums.pl <package.pkg>`
- `apply_mod.pl <NNN> <path/to/target.bin>` -- the record is read from `mods/` relative to the
  script; the target binary is whatever path you supply.

A package that carries several mods is just a linear chain of copies: e.g. mod002
ships *with* mod001 by copying `e80_mod001.bin` to `e80_mod002.bin`, applying
record 002, and building -- the result is mod001+mod002 in one package. (Which
package carries which mods is cataloged in [mods](mods.md).)

### Version labeling

The package/app version (e.g. `v5.69`) is a **DOB-header text descriptor** at
header `+0x14`, carried in the DL1 envelope and the App2FSH + E80/120_App child
headers. It is **display + installer-ordering only**: the running app reads it
from NOR for Unit Info and the boot disclaimer (the string exists nowhere in the
app image -- it is not a code constant; verified by an exhaustive byte scan), and
the installer compares it to decide update vs downdate (downdate is supported --
re-flashing an older labeled package is accepted). It is **not** a
schema/persistence version -- those are separate constants in the app image
("Persistence Version Number", chart "View Data Version Number", etc.) and are
never touched here -- so bumping it is safe across up/downdate.

`build_mod_pkg.pl ... --version <v>` relabels that field (e.g. `v5.69` -> `v5.72`)
wherever it carries the app version, leaving component headers' own versions
alone. The numbering **formula**: each new mod takes the next number above stock,
and the gaps are intentional. The specific per-package version assignments live in
the mod catalog ([mods](mods.md)).

## 4. Why it is safe to flash (the bricking floor)

The modification inherits the stock package's safe targeting because it **never
touches the flasher stubs or the destination/region fields** -- only the application
payload bytes. A wrong byte in the application payload yields only a bad *application
image*, which is recoverable by reflashing the stock package: the recovery
actors (`ClearFlash`, `App2FSH`) are independent of the application image's content, and
the **stock-CF reflash recovery path is hardware-confirmed** (a rejected resize
package left the unit fully recoverable; see History,
2026-05-30). The boot region (the inferred stage-0) is written by no action in
the package at all (see [bootloader](bootloader.md)).

## 5. Hardware-confirmed

The pipeline is proven on a real E80, not just on the bench: a resized/recompressed
package installs and boots (so stage-0's boot-time inflater tolerates a resized
stream), a relabel is booted-visible (Unit Info shows the new build machine + date),
and a behavioral edit installs and boots with the user config retained. The
container-level resize/boot proof is in [installer](installer.md); the per-mod
confirmations are in the mod catalog ([mods](mods.md)).

## 6. What a mod unlocks is separate from whether it installs

The build and flash mechanics documented here are proven regardless of what any given
mod targets -- *whether* a mod installs is independent of *what* it unlocks. The
specific mods (including how the `mod001` slot was re-scoped after its first target,
the TFTP gate, proved a dead end) are in the mod catalog ([mods](mods.md)); the
current `mod001` peek/poke/call instrument is [tools/diagnostics](../tools/diagnostics.md).

---

**Next:** [mods](mods.md) ...
