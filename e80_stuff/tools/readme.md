# Tools

**Home** --
**[diagnostics](diagnostics.md)** --
**[ghidra](ghidra.md)**

**[Up](../readme.md)** --
**[Architecture](../architecture/readme.md)** --
**[Abstracts](../abstracts/readme.md)** --
**[Deployment](../deployment/readme.md)** --
**Tools** --
**[Cleanroom](../cleanroom.md)**

How we look at the artifact -- the static binary and the live device -- and the
surfaces that verify what we find. This axis is mostly Claude-facing reference
material: the machinery the exploration runs on.

## Contents

- [**diagnostics.md**](diagnostics.md) -- the **live-device instrument**: the
  `mod001` peek / poke / call channel that re-purposes the firmware's
  unadvertised Diagnostics service. How the confirmed device facts were
  confirmed. (Ours, not a device feature.)
- [**ghidra.md**](ghidra.md) -- the **hand-added annotation layer**: the export /
  import / apply toolchain, the annotation kinds, the in-recipe annotation
  directives a mod record carries, and how deep to annotate a mod -- what we add
  by hand and version, as opposed to what Ghidra auto-derives.

## Probe and instrument scripts

The durable client tooling that drives the live device over the wire:

- `scripts/_diag_dbg.pl` -- the peek/poke/call client for the `mod001`
  diagnostics channel (see [diagnostics](diagnostics.md)).
- `scripts/_diag_stat.pl`, `scripts/_diag_lstree.pl` -- STAT/size and crude
  directory-listing of the `\local` flob filesystem, built on the channel.
- `scripts/_tftp_probe.pl "<path>" [ip]` -- TFTP RRQ/GET probe; runs the full
  RFC 1350 read transfer and writes `temp/got_<name>`. Binds a fixed local UDP
  port (9973).
- `scripts/_tftp_put.pl [name] [ip]` -- single-block TFTP WRQ/PUT probe.

Host prerequisite for the TFTP probes (Windows): the standing inbound firewall
rule `_prh_src_e80_TFTP` (allow UDP 9973, private networks), because the
server's transfer reply comes from a new ephemeral TID port a stateful firewall
would otherwise drop.

The firmware-**modification** build tooling (`apply_mod.pl` / `apply_mod.py`,
`build_mod_pkg.pl`, `verify_db1_checksums.pl`) is documented with the scheme it
serves, in [deployment/modification](../deployment/modification.md).

---

**Next:** [diagnostics](diagnostics.md) ...
