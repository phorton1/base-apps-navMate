# navMate Windows Installer Releases

The downloadable **Windows installer** for navMate lives on this repository's
[**Releases**](https://github.com/phorton1/base-apps-navMate/releases) page, not in this
folder: the installer exe is a GitHub Release asset, so this repo stays text-only and lean.

navMate is *pure Perl / wxPerl*. The installer bundles it with a private **ActivePerl 5.12**
via the ancient **Cava Packager 2.0** -- the only tool that still packages this Perl/wx stack
as a standalone Windows exe. The full build method is arcane and effectively unpublishable,
but **all** source (navMate, `Pub::`, and `Pub::Ray`) is here on GitHub and is guaranteed
free of malware or adware.

> **Pre-release notice.** Every `0.9.x` build is an early-access **pre-release**: useful, but
> not guaranteed in any way, shape, or form, and likely to be deleted at the first official
> **1.0.0** release.

This is a release LOG, not a changelog. For what changed between any two releases the git
history is authoritative: `git log navMate<older>..navMate<newer>`.

## Releases

| date | version | notes |
| ---- | ------- | ----- |
| _(none yet)_ | | |

Each release is the same tag `navMate<version>` stamped across the five repos it was built
from, so it is fully reproducible. Provenance per release is recorded here at release time:

<!-- Entry template (newest first, added when a release is cut):

### navMate0.9.5 -- YYYY-MM-DD (pre-release)

<one terse line of highlights>

built from:
    navMate            <sha>
    Pub                <sha>
    Pub::Ray           <sha>
    base_dist/navMate  <sha>  (private)
    Perl               <sha>  (private)
toolchain: ActivePerl 5.12.4 + Cava Packager 2.0.80.263 + Inno Setup 5.5.9
-->
