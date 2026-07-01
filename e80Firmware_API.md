# e80Firmware -- Firmware Package Build API

Return to [**Cleanroom**](../cleanroom.md)

[e80Firmware](e80Firmware.pm) is a navMate-side Perl library that turns a stock
E80 application package into a **modified, flashable package**. It extracts the
application image from a stock `E_App_Upg_Uni` package, applies one or more
modification records to that image, and repackages it -- recomputing the
container's length cascade and checksums -- into a labeled package the unit's
installer accepts. A companion call verifies a stock package's DB1 checksums.

This document is the client-facing API: how to call the library, the builder
signature contract, the progress object, and the operation guarantees. It does
not cover the package-format internals.

## What it does: the four operations

A build is a short in-memory pipeline. The user supplies their own stock package;
the library never carries firmware of its own.

1. **extract** the application image from a stock package (one gzip stream inside
   the `E80/120_App` container);
2. **apply** one or more modification records to that image, in memory and in
   order (a multi-mod package is a record applied on top of the previous result);
3. **build** the modified package -- re-compress the image, rebuild the container
   length cascade, stamp the build descriptors, recompute every checksum, and
   verify the result before writing it.

`verify` is a standalone read-only check of a stock-layout package.

## Requirements

- Perl with `Digest::SHA`, `IO::Compress::Gzip`, `IO::Uncompress::Gunzip`, `POSIX`,
  and the `Pub::Utils` module (the library imports `display`, `error`, and
  `warning` from it).
- Read access to a stock `E_App_Upg_Uni` package and the modification record(s).
- A writable output directory for the built package.

No network access and no device contact: this is offline file work. Installing the
result onto a unit is the normal CF-card upgrade, separate from this library.

## Loading and calling

The library **exports** its four entry points
(`extract_app_image`, `apply_mod_record`, `build_mod_pkg`, `verify_db1_checksums`)
via `Exporter`, so `use e80Firmware;` imports them unqualified. It resolves on
`@INC` by bare name from the recipient root:

```perl
use e80Firmware;

my $img = extract_app_image($stock_pkg)            or die "extract failed";
apply_mod_record($mod001_record, \$img)            or die "mod001 failed";
apply_mod_record($mod002_record, \$img)            or die "mod002 failed";
my $out = build_mod_pkg(stock   => $stock_pkg,
                        image   => \$img,
                        label   => 'mod002',
                        outdir  => $out_dir,
                        version => '5.72',
                        builder => $handle)         or die "build failed";
```

All four are **synchronous**. The build is fast (sub-second to a few seconds);
there is no device round-trip. Each accepts an optional shared progress hash (see
below); on failure each reports the reason and returns a false value rather than
dying.

## API

### extract_app_image($pkg\_path \[, $progress\]) -> $image\_bytes | undef

Reads the stock package at `$pkg_path` and returns the inflated application image
as a byte string. Returns `undef` on failure (reason via `error()` /
`$progress->{error}`). Read-only.

### apply_mod_record($record\_path, \\$image \[, $progress\]) -> 1 | 0

Applies a modification record (`e80_mod<NNN>.txt`) to the image referenced by
`\$image`, **in place**. Verify-all-then-write: every region's SHA-256 is checked
against the record's recorded original-region hash before any byte is written, so
a record that does not match the image is rejected with no partial edit. Idempotent
(a region already equal to its new bytes is skipped). Returns 1 on success, 0 on
failure. Annotation directives in the record are ignored here (they drive the
annotation layer, not the binary patch).

To stack mods, call once per record against the same `\$image`, in order. A record
whose recorded original hashes assume an earlier mod must be applied after it.

### build_mod_pkg(%args) -> $output\_path | undef

Repackages an application image into a labeled, flashable package and returns its
path. Returns `undef` on failure (reason via `error()` / `$progress->{error}`).

| Arg | Required | Meaning |
|-----|----------|---------|
| `stock` | yes | path to a stock package (read-only: static container pieces + geometry) |
| `image` | yes | `\$image_bytes` -- the patched application image to package |
| `label` | yes | filename-safe label; output is `E_App_Upg_Uni.<label>.pkg` |
| `outdir` | yes | directory to write the output package into |
| `builder` | no | the builder signature (see below); empty/absent -> `navMate` |
| `version` | no | app version to relabel, e.g. `"5.72"` (digits and dots) |
| `build_time` | no | epoch seconds for the build-date descriptor (default: now) |
| `progress` | no | a shared progress hash (below) |

The build re-compresses the image, rebuilds the container, stamps the build
descriptors, recomputes all fourteen checksums, and **verifies + structurally
audits** the result; it writes nothing if verification fails. `build_time` is a
parameter so a build is reproducible -- pin it (and `builder`, `version`) to
reproduce a prior package byte-for-byte.

### verify_db1_checksums($pkg\_path) -> ($ok, \\@rows)

Walks the seven DB1 children of a **stock-layout** package and checks both the
header and payload byte-sum checksums against the values stored in each. Returns
`($all_ok, \@rows)`, each row a hash of `{ name, magic, hok, pok, hsum, hstored,
psum, pstored }`. Read-only. A freshly built (resized) package's trailing children
shift, so this is for stock-layout inputs -- a built package is already verified
internally by `build_mod_pkg`.

## The builder signature

The build stamps a short **builder signature** into the package's build
descriptors. It is rendered on the unit's **Unit Info** screen alongside the build
date, so the person who built the package sees their own mark on the device. It is
the `builder` argument to `build_mod_pkg`.

**Contract (enforce this in the UI before calling):**

- Allowed characters: `A`-`Z`, `a`-`z`, `0`-`9`, `-`, `.` -- i.e. the regex
  **`^[A-Za-z0-9.-]{1,15}$`**.
- Length 1 to 15 characters.
- **No spaces** (and no other punctuation).
- **Empty or absent** -> the neutral default `navMate`.
- A **non-empty value that fails the rule is refused**: `build_mod_pkg` returns
  `undef` and reports the reason via `error()` / `$progress->{error}`. It is not
  sanitized or truncated -- it is rejected.

Because the library refuses an invalid handle (rather than fixing it up), a UI
should validate the field against the exact regex above *before* calling, so the
user gets immediate feedback instead of a failed build. A suggested field hint:
*"Letters, numbers, `-` and `.`; no spaces; up to 15 characters."*

Examples that pass: `Bob-Smith`, `Bob.Smith`, `BobSmith`, `J.Smith`, `nav-42`.
Note that `Bob Smith` (with a space) is **refused** -- steer users to a
space-free form.

## The progress object

Each entry point accepts an optional `$progress` -- a `threads::shared` hash the
caller creates and the library **only mutates** (it never replaces the hash). This
is the same contract a wx progress dialog provides, and the same one the sibling
cleanroom libraries use.

| Field | Written by | Meaning |
|-------|------------|---------|
| `label` | library | current phase text (e.g. `"Compressing image"`) |
| `done` | library | phase step completed |
| `total` | library | total phase steps for the current operation |
| `error` | library | failure reason (set when an operation returns false) |
| `active` | caller | set to 1; the operation is running |

Progress is coarse (a handful of phase labels per operation) because a build is
fast and offline. Passing no `$progress` is fine; the operations simply skip the
updates.

## Behavior and guarantees

- **In-memory pipeline.** `extract` returns the image, `apply` mutates a scalar
  ref, `build` consumes one. Nothing is written between steps; only the final
  package lands on disk, in `outdir`.
- **Verify-all-then-write, twice over.** `apply` checks every region's hash before
  editing; `build` re-inflates its own gzip to confirm a bit-exact round-trip and
  re-checks all fourteen checksums plus a structural audit before writing. A failed
  check produces no output file.
- **Reproducible.** Identical `image`, `builder`, `version`, and `build_time`
  produce a byte-identical package (the gzip header fields are pinned). This is how
  a prior build is reproduced exactly.
- **No firmware travels with the tool.** The user supplies the stock package and
  their own modification records; the library carries neither.

---

Return to [**Cleanroom**](../cleanroom.md)
