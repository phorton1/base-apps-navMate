# Ghidra annotations

**[Home](readme.md)** --
**[diagnostics](diagnostics.md)** --
**ghidra**

**[Up](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**[Deployment](../deployment/readme.md)** --
**Tools** --
**[Cleanroom](../cleanroom.md)**

The **hand-added annotation layer** on the Ghidra program -- the names, comments,
signatures, and variable names we apply on top of the raw disassembly -- and how it is
exported, version-controlled, and re-applied. It is the hand-added complement to what
Ghidra *auto-derives* (the RTTI / vtable catalog): this is what *we* add by hand and keep.

It is documented here because the same vocabulary appears in two places: the
program-wide annotation export, and the **`ghidra:` annotation directives** carried inside
a modification recipe ([deployment/modification](../deployment/modification.md)), where a
mod describes the names and comments its own code deserves so the program reads correctly
straight from the recipe.

---

## 1. The annotation layer and the toolchain

Ghidra stores two things we care about beyond the bytes: **symbols** (function and label
names) and **comments**, plus per-function **signatures** and **variable** names. The ones
*we* set are marked `USER_DEFINED`, distinct from the `ANALYSIS`/`IMPORTED` defaults. Two
Jython scripts move that layer in and out:

- `scripts/_export_ghidra_annot.py` -- walks the current program's symbol table and comment
  storage (a sparse, fast walk -- no decompilation, no byte scan) and writes every
  `USER_DEFINED` name, every comment, and every user signature to one address-sorted text
  file, labeled by the program's own name. Read-only. Used to **version-control** the layer
  and to **diff one program against another**.
- `scripts/_import_ghidra_annot.py` -- reads that file back into a program, re-creating the
  functions, names, comments, signatures, and (where they match) variable names.

The export line format is:

```
<address>   <TAB>   <kind>   <TAB>   <text>
```

sorted by address. Every annotation reduces to one such line; the in-recipe directives
(section 3) are just a friendlier spelling of the same kinds.

## 2. The annotation kinds (the vocabulary)

| kind | what it sets | keyed by | ports across a rebuilt base? |
|---|---|---|---|
| `NAME-Function` | a function's name | address | yes |
| `NAME-Label` | a code/data label | address | yes |
| `CMT-PLATE` | the boxed header comment above a function/region | address | yes |
| `CMT-PRE` | a comment above an instruction | address | yes |
| `CMT-EOL` | a trailing comment on an instruction | address | yes |
| `CMT-POST` / `CMT-REPEAT` | post / repeatable comments | address | yes |
| `SIG-FUNC` | the function prototype (return + params) + calling convention | address | yes |
| `VAR-LOCAL` / `VAR-PARAM` | a local / parameter name | function entry **+ storage** | **no -- analysis-bound** |

The split in the last column is the important one and is explained in section 6: everything
**address-keyed** re-attaches to any program built on the same base; the **storage-keyed**
variable names re-attach only on a decompilation that produces the same variable layout.

## 3. In-recipe directives (the `ghidra:` layer of a mod record)

A modification recipe carries its annotations as **address-keyed directives**, interleaved
with the `edit` blocks ([deployment/modification](../deployment/modification.md) section 2).
Each is one line, or a `<< ... >>` block for multi-line comment text:

```
func   <start> <end> <name>                 create a function with that extent + name it
name   <addr> <name>                         rename a function    (NAME-Function)
label  <addr> <name>                         name a code/data label (NAME-Label)
sig    <addr> <prototype>  cc=<convention>   set the prototype    (SIG-FUNC)
local  <addr> <storage> <name>               name a local/param   (VAR-LOCAL / VAR-PARAM)
param  <addr> <storage> <name>
pre    <addr> <text | << ... >>>             a comment of that kind at that address
plate  <addr> <text | << ... >>>             (CMT-PRE / CMT-PLATE / CMT-EOL / ...)
eol    <addr> <text>
```

- `func` is the one verb beyond a plain export kind: it both **creates** the function (with
  an explicit body extent) and names it -- needed because a mod introduces routines that did
  not exist in the stock program.
- A comment directive takes **any** address, including a function the patch only *affects*
  (an off-patch plate on the enclosing function whose body a splice changed). That off-patch
  reach is the whole reason the directives are address-keyed rather than attached to the
  edit.
- Placement is by **convention, not requirement**: put `func`/`sig`/`pre` on the edit that
  defines the routine, and an off-patch `plate` next to the edit that invalidated it. Each
  directive carries its own address, so `apply_mod.py` applies them in a second pass (after
  all bytes are laid down) and textual order is purely cosmetic.

`apply_mod.py` applies these; `apply_mod.pl` (the binary patcher) ignores them. A mod with no
directives simply patches bytes.

## 4. What the `new` listing contributes

The inline disassembly listing inside an `edit ... new ... end` block is mostly **reader-only**
-- the hex is the byte truth, and the `# disassembly` / `; meaning` comments are the recipe's
annotated listing for a human (Ghidra disassembles the bytes itself). Exactly **two** things
cross from the recipe into the program automatically:

- a standalone **`# label:`** line -- a bare `identifier:` -- becomes a **`NAME-Label`** at the
  next instruction's address (this is how branch targets like `geo_loop` get named);
- the `edit` block's **rationale** line becomes a **`CMT-EOL`** stamp at the patch address.

Everything else a mod wants in the program is written explicitly as a directive (section 3).

## 5. How deep to annotate a mod

The bar is **more than none, less than everything** -- and the line falls naturally where two
boundaries coincide: *address-keyed vs. storage-keyed*, and *cheap vs. fragile*.

**Floor (required) -- the program must not lie, and the mod's code must be identifiable:**

- `func` create + name every routine the mod introduces (no `FUN_xxxx`);
- a `pre` synopsis on each, with a `docs/public`-relative pointer to the mod's design page;
- **repair any off-patch comment the mod invalidates** -- e.g. a plate that still describes a
  function's old behavior after a splice changed it. Leaving that stale is worse than no
  annotation.

**Free middle (take it -- it costs nothing):** labels and the rationale EOL come from the `new`
listing automatically (section 4); a `sig` on a new routine is one line and helps the
decompiler; a `local` on a **stack** variable that genuinely clarifies the decompiled C is
worth it (a named request buffer in the host function, say).

**Ceiling (deliberately excluded -- "every possible thing"):** exhaustively renaming and typing
**register** locals, and custom struct/enum datatypes. These are the storage-keyed,
analysis-bound, high-effort layer -- the most fragile and least portable, for the least
marginal gain. A register alias is documented better by the listing's own `; meaning` comments
than by a fragile `VAR-LOCAL`.

Within those bounds the depth is a **per-mod authoring decision**, made when the recipe is
finalized and recorded in that mod's design page -- the recipe is sovereign over the names it
gives the slots it touches, regardless of what the stock program called them.

## 6. Why annotations port (address-keyed vs. analysis-bound)

The project keeps a single analysis-complete base program and builds the mod programs above it
(`reference_ghidra_programs` in the project notes). Annotations re-attach across a rebuild
**only** as well as their key survives:

- **Address-keyed** annotations -- names, labels, comments of every kind, and signatures -- key
  on a code address, which is stable across any program built on the same base. They port
  freely, which is why the floor and most of the middle are address-keyed.
- **Storage-keyed** annotations -- `VAR-LOCAL` / `VAR-PARAM` -- key on `(function entry,
  storage, first-use offset)`. That key only matches a decompilation that produces the *same*
  variable layout. On a base whose decompiler analysis differs, a fraction of variables fail to
  re-attach (the parameter "drift" observed when porting onto a divergent base). This is the
  concrete reason variable naming sits at the ceiling: it is the one part of the layer that does
  not travel.

Signatures (`SIG-FUNC`) are the useful middle case -- address-keyed, so they port, and applying
one *recomputes* parameter storage, which can re-align parameters that a bare `VAR-PARAM` would
have lost.

---

**Next:** [Home](readme.md) ...
