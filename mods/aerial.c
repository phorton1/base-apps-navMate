/* This code is licensed under the MIT License -- see LICENSE.TXT in this directory. */
/* ====================================================================
 * aerial.c -- E80/E120 custom raster-aerial overlay: the AERIAL COE.
 * AUTHORING SOURCE ONLY. The COE builder packs this file into
 * AERIAL.COE (a self-hooking code extension; COE magic 'COE1'). The generic
 * mod4a linking loader (mods/mod005.c) finds it on the CF card and loads it at
 * runtime -- this file is never flashed.
 *
 * *** A SELF-HOOKING COE (not a firmware half) ***
 * This file is the whole aerial brain PLUS the four render-path detours it
 * installs into live firmware .text at load. It is not compiled twice, and it is
 * not "half" of anything: the linking loader is a separate, feature-blind file
 * (mod005.c, mod4a). At load, coe_common's apply_edits splices each detour onto
 * its firmware site with an 8-byte `ldr pc` -- after verifying the site's stock
 * bytes against orig_sum (from @base) -- so the detour body runs in the heap-
 * loaded COE; then coe_init publishes CTX and the export table.
 *
 * Each detour reads CTX from the aerial anchor (0x044bb300) and falls through its
 * own `if(!CTX)` stay-stock path until coe_init has published, so the splices are
 * inert (native-only) between install and init. `aerial_ctx_t` (below) leads with
 * the EXPORT TABLE = the ABI: coe_init fills it with this overlay's own (relocated)
 * heap addresses; a detour reaches its C handler by loading the address from an
 * `EXP_*` slot, the host reaches enable/disable the same way, and
 * `_Static_assert(offsetof(...)==EXP_*)` pins those literals. The mod4a loader is
 * GENERIC -- it accepts any COE by code_sum hash and does NOT check abi_version --
 * so a stale COE is caught by the `if(!CTX)` guard and by the host's aerial_abi.pl,
 * not refused at load.
 *
 * The brain lives on the card, not in NOR -- handing its codespace back to the
 * firmware image -- and because the loader is generic, a second COE needs no new
 * flashed wedge of its own.
 *
 * MODEL: event-driven, tail-append. The core write is
 * ChartingAppPD_compositeKey5_to_L3 @0x006da638 -- the key-5 -> L3 blit, the
 * actual last write to L3. Its detour lets native run IN FULL (trampoline =
 * displaced prologue + continue at +4) then appends our composed tiles, so our
 * photo is simply last. No race to lose, no second painter behind us. One more
 * detour (the 6_3_2 reveal) rides the same self-hooking mechanism -- see the @hook block below.
 *
 * *** THE L3 PAINTER ***
 *   ChartingAppPD_drawLayerByKind @0x006d9a18   (vtable entry #4)
 *       walks the map at this+0x64 and dispatches on kind:
 *         8     -> renderOverlayToSurface
 *         0x10  -> compositeLayers_6_3_2 + compositeLayers_4_6_1
 *         0x20  -> compositeLayers_4_6_1
 *         0x100 -> compositeKey5_to_L3(this,0,this+0xf0)   <== THE AERIAL, key-5 -> L3
 *
 * compositeKey5_to_L3 @0x006da638 is the ONLY writer of L3, called from exactly one site,
 * bl @0x006d9b4c inside drawLayerByKind. drawOverlays is entry #6 on the same interface -- a
 * sibling vmethod called separately by the frame driver, testing only flags &8/&0x10/&0x20 and
 * ignoring 0x100. The aerial is not drawn inside drawOverlays, which is why the painter always
 * lands after drawOverlays has returned.
 *
 * BINDINGS:
 *  - FileX raw C API: media=*(0x005d9a40)+0xa4, fcb=rm_malloc(0x180),
 *    fx_file_open/read/seek/close.
 *  - decode_blob(blob,len,dst,stride)->RGB555: an asm primitive that drives the low-level
 *    firmware CJpeg decoder (construct/init/installSource/run/startDecompress/readScanlines/
 *    finish) and packs to RGB555. Lives in mods/decode_blob.bin and is @imported from there.
 *  - L3 scanout base = 0xd6000000 + *(0xd7fd005c) (native-programmed live plane).
 *
 * MEMORY: a 12-byte dead-.bss anchor (CTX/aerial_flags/reserved @0x044bb300) -> one heap
 * object. The big
 * buffers (backbuffer + tile cache + JPEG scratch) are fixed-size + card-
 * independent: allocated ONCE at feature-enable and KEPT (no per-card churn ->
 * no heap fragmentation). Only card-specific state (zoom dir, presence bitmaps,
 * file handle) is (re)built per card.
 *
 * TARGET: ARM920T (ARMv4T), ARM state, LE. No libc, no Thumb, no blx.
 * ==================================================================== */
// @coe_name AERIAL                 // -> AERIAL.COE (the card file mod4a's scanning LL loads)
// @base mod005                     // the mod image aerial hashes its hook sites against (the builder resolves this token)
// @coe_version 11                // COE build stamp -> header +0x1c
// @slot 4                        // aerial's 12-B .bss contract slot = D2[4] @0x044bb300 (LL sets STATE=LOADED)
//
// --- SELF-HOOKING EDITS: each detour body below is copied onto its firmware site by an
//     8-byte `ldr pc` splice that the COE builder generates from these @hook lines. coe_common's
//     apply_edits verifies each site's original bytes (orig_sum from @base) before writing, then
//     coe_init publishes CTX (aerial anchor 0x044bb300). Each detour reads CTX from that anchor and
//     falls through its own if(!CTX) stay-stock path until then. ---
// @hook compositeKey5_to_L3_detour   0x006da638   // key5 -> L3 (the aerial photo blit)
// @hook compositeLayers_6_3_2_detour 0x006da2f8   // key6 <- key3|key2 (the REVEAL, pre-blit)
#include <stdint.h>
#include <stddef.h>                           /* offsetof -- for the export-table asserts */
#include "coe_common.h"                        /* shared contract: coe_slot_t, STATE enum, COE_SET_STATE */
#include "hbuddy.h"                             /* HBUDDY.COE library contract: hbuddy_arm/stage/log/reset/freeze
                                                * -- guarded wrappers, no-op when HBUDDY.COE is absent (*.off) */
#include "e569.h"                              /* firmware v5.69 ABI: rm_malloc/free, FileX file+dir, threads,
                                                * RayLib events, layer lookup/surface, markAerialDirty, POST_UI_MSG
                                                * + 0x67, merc<->latlon, L3_BASE/SCR_*, CORAL_CTR */
typedef uint8_t  u8;  typedef uint16_t u16;
typedef uint32_t u32; typedef int32_t  s32; typedef int16_t s16;

/* --- firmware ABI bindings are in e569.h (included above): rm_malloc/free, the FileX
 *     file + directory API, threads + RayLib events, layer lookup/surface, markAerialDirty,
 *     POST_UI_MSG + UI_MSG_REDRAW/RC_MSG_TARGET, merc<->latlon. Only the aerial's OWN
 *     anchors, belts, and flag words are defined in this file. --- */
#define FX_DIRENT_MAX 512      /* our own belt: never spin the enumerator unbounded */

/* --- aerial-specific runtime signals (L3_BASE / SCR_* / CORAL_CTR are in e569.h) --- */
/* PhotoOverlayRC registry: <=4 slots, ONE PER CHART WINDOW (verified live --
 * a 2-window page fills slots 0 and 1; a 1-window page fills only slot 0). Per RC:
 *   +0x04 vtbl 0x016435bc
 *   +0x7c -> INTO its ChartingAppPD at PD+0x0c (multiple-inheritance embedded interface)
 *            => PD = *(RC+0x7c) - 0x0c is THE PAIRING between a hook entry and its geo
 *   +0x9c geometry provider (obj = prov-4; bounds obj+0x2b4 = {e0,n0,e1,n1} semicircles)
 * Each window's geometry MUST come from its own slot: a 2-window page composes the left
 * window's geo into the right window's rect if anything reads slot 0 for both. */
#define RC_REG   ((u8**)0x044c66e4)
#define RC_SLOTS 4
/* AERIAL: composite-hook flag word -- the third .bss anchor word (0x044bb300=CTX,
 * +4=AERIAL_FLAGS, +8=here). Poke-able at runtime; coe_init BAKES CF_DEFAULT at boot
 * (self-start). Two flags remain, both baked ON in CF_DEFAULT:
 *     bit0  CF_HOOK_6_3_2  0x00000001  arm the 6_3_2 reveal detour (key3 opaque-fill band 0x21-0x2f
 *                          -> blend twin 0x01-0x0f, so chart fills reveal L3 while symbology stays
 *                          opaque). Clear the bit -> the detour is inert (native-only).
 *     bit28 CF_GREEN       0x10000000  fill the window green before tiling, so any area the tiler
 *                          does not cover shows GREEN (not native's key-5 yellow) if it ever leaks.
 * The kind5 detour (suppress/draw) is ungated -- it runs on CTX + published exports alone.
 * The COE never pokes the CLUT (stock CLUT: 0x21-0x2f opaque, 0x01-0x0f blend); the reveal is
 * entirely the key3 index remap. */
#define COMPOSITE_FLAGS (*(volatile u32*)0x044bb308)
#define CF_DEFAULT      0x10000001u  /* baked by coe_init: GREEN | HOOK_6_3_2 */
#define CF_HOOK_6_3_2   0x00000001u
#define CF_GREEN        0x10000000u

#define TILE_PX 256
#define TILE_555 (TILE_PX*TILE_PX*2)
#define CACHE_SLOTS 40     /* a screenful of tiles (~32) + scroll margin, so pans reuse decodes */
#define AFFS 16
#define MAP_MUL 32     /* fixed-point scale for the geo->screen inverse (semicircles-per-px); see map_x */
#define REVEAL_TRIES 10u   /* 0x67 reveal-post retry budget per composed frame; poller ~150ms => up to
                            * ~1.5s of retries to outlast native's post-pan-paint busy window */

/* One coverage block. `fh` is THE FUSION KEY: blocks from every .RCT on the card are merged into
 * one pyramid, and each block remembers which file serves its tiles. Nothing downstream of
 * block_for needs to know a region exists -- files are CONTAINERS, not places. */
typedef struct {
    s32 x_min,x_max,y_min,y_max; u32 grid_w,grid_h;
    u32 index_off; u8* bitmap;
    s32 merc_e_w,merc_n_n; s32 step_e,step_n;
    void* fh;                   /* the .RCT this block's tiles are read from */
} block_t;
typedef struct { u8 zoom; u32 nblk; block_t* blk; } zoomdir_t;
typedef struct { u8 used,z; s32 x,y; u32 lru; u16* px; } cslot_t;
/* a chart window's screen rect (from native) + its derived geo->screen affine.
 * TRANSIENT: rebuilt from the slot + the live provider at each compose/present. */
typedef struct {
    s32 sx,sy,sw,sh; s32 span_e,span_n;
    s32 org_e,org_n,scale_x,scale_y,inv_e,inv_n; u8 zoom;
} window_t;
/* ---- THE REVEAL MASK (Phase 2) --------------------------------------------------------------
 * The aperture is the set of screen pixels that actually have imagery under them. It is carried
 * as a LIST OF RECTANGLES, not a per-pixel bitmap: the reveal then walks only those rects, so the
 * LOOP BOUNDS ARE THE MASK and no per-pixel position test exists at all -- the only per-pixel work
 * left is the irreducible value test. Cost tracks revealed area instead of plane area.
 *
 * MASK_Z is the AUTHORED level -- the zoom at which the user's polygon is represented. It is NOT
 * the drawn level: at coarse zoom the tiler paints a parent tile whose imagery spills well past
 * the authored polygon, and that spill must stay hidden under an opaque chart. Parent-completeness
 * guarantees the drawn set is always a superset of the revealed set, so the aperture can never
 * expose an unpainted pixel. Hardcoded for now; it becomes an RCT header field once chartMaker
 * builds the multi-region card (see raster_chart_format.md). */
#define MASK_Z         15u
#define MASK_MAX_RECTS 128     /* 8 B each = 1 KB/window. Overflow -> mask_full -> reveal the whole
                                * plane (= pre-Phase-2 behaviour), so the degenerate case is never
                                * WORSE than what shipped, just no better. An irregular polygon can
                                * put several runs on one cell row, so keep real headroom here. */
typedef struct { s16 x0,y0,x1,y1; } mrect_t;   /* KEY-BUFFER coords, inclusive */

/* PERSISTENT per-window state, KEYED on the ChartingAppPD `this` the hook is entered with.
 * Re-paired against the LIVE registry on every hook entry and never trusted across one --
 * so when a page change destroys a PD and rm_malloc's first-fit hands its address to some
 * other object, that address simply matches no RC and we stand down. The O(4) re-pair IS
 * the validation; there is no stale-pointer window to hit. */
typedef struct {
    u32 used;                             /* 0 = free slot */
    u32 pd;                               /* the ChartingAppPD `this` = the key */
    s32 last_e0,last_n0,last_e1,last_n1;  /* bounds of the LAST COMPLETED compose */
    u32 dirty;                            /* hook sets (this window's view moved); thread clears */
    u32 drawing;                          /* tiles placed by the IN-PROGRESS compose */
    u32 drew;                             /* tiles of the last COMPLETED compose = present gate */
    /* ---- cached reveal mask for THIS window. Rebuilt only when the view moves or the card
     * changes; consumed every composite. The key is (view bounds, card_gen) -- NOT the view
     * alone, because the presence bitmaps change on mount/teardown and no view descriptor can
     * express that. mask_ok distinguishes "built, and empty" from "not built yet". */
    u32 mask_ok, mask_gen, mask_built_z;   /* mask_built_z: the mask_z this mask was cut at, so a
                                            * live poke of the knob invalidates the cache */
    s32 mask_e0,mask_n0,mask_e1,mask_n1;
    u32 mask_full;                        /* 1 = too fragmented to describe; reveal the whole plane */
    u32 nmrects;
    mrect_t mrects[MASK_MAX_RECTS];
    /* 1 = we have committed at least ONE complete frame into L3 for this window. Gates BOTH the
     * reveal and the suppression of native's key5->L3 blit, which together make the yellow flash
     * structurally impossible:
     *   no frame yet -> DON'T reveal. The chart stays opaque until we have something to show.
     *                   (Suppressing this early would swap yellow for whatever L3 happens to
     *                   hold -- black or garbage -- which reads as a fault, not as "not ready".)
     *   have a frame -> ALWAYS suppress. L3 is ours and native can never repaint it yellow; an
     *                   interrupted compose simply leaves the last GOOD frame on the glass.
     * Cleared on teardown, so card-out / AO-off still close the aperture. Safe only because the
     * Phase 2 aperture is bounded -- a stale frame can now only be seen where imagery belongs. */
    u32 has_frame;
    u32 revealed;                         /* 1 = key3 currently carries OUR remap for this window.
                                           * Drives the un-reveal on the covered->uncovered edge:
                                           * key3 keeps whatever we last wrote, so merely ceasing
                                           * to reveal would strand an aperture onto an empty
                                           * backbuffer. */
    /* SNAPSHOT of THIS window's geometry, captured by the kind5 hook on the coherent PD (rect off
     * pd+0xf0, geo bounds off the live RC). The render thread composes from a COPY of these and
     * never dereferences the PD -- it is the whole reason the render thread cannot fault. Written
     * on a view change, same gate as dirty. */
    s32 snap_sx,snap_sy,snap_sw,snap_sh;
    s32 snap_e0,snap_n0,snap_e1,snap_n1;
    u32 k5_surf;                          /* key-5 surface ptr for THIS window (probe) */
    u32 k5_d0, k5_d1;                     /* surface desc words 0/1: flags|bpp|w , h|mask */
    u32 k5_base;                          /* surface VRAM base (desc+0x0c) */
    /* 0x67 REVEAL RE-FIRE retry budget. A single 0x67 post AT settle often lands too early -- native is
     * still finishing its own optimized-pan paints, so our post gets absorbed into an optimized (not
     * full) paint and the 6_3_2 reveal never runs (bench-proven: the same post a beat later reveals).
     * So we RETRY: compose arms reveal_tries and clears `revealed`; post_reveal (render thread, fast
     * path) and the poller (every ~150ms) each post 0x67 and decrement, until the 6_3_2 hook confirms
     * the reveal by setting `revealed=1` (stops the retry) or the budget runs out (bounds a no-coverage
     * view, where 0x67 never reveals, to a fixed number of posts instead of forever). */
    u32 reveal_tries;
} wslot_t;
#define MAX_FILES 16   /* card-scoped .RCT set (a 2GB helm card holds ~10); heap-cheap */
/* ==== THE ABI CONTRACT -- the only part of the ctx anything outside the COE brain may touch ====
 * Lives at the HEAD of aerial_ctx_t, deliberately. The COE's own detours run at their fixed .text
 * splice sites and read these with `ldr rX,[rY,#imm12]`, whose displacement range is 0..4095; at the
 * TAIL of a ~12KB struct those literals drift toward that ceiling every time something is inserted
 * ahead of them. At the head they are permanently immune however large the COE-private tail grows.
 *
 * abi_version is FIRST because it is the key that makes every other offset trustworthy: a host tool
 * peeks CTX+0, learns which ABI it is talking to, and only then knows where anything else lives. It
 * also gives a free "not booted" test -- the ctx is mzero'd at alloc, so 0 means nothing published yet.
 *
 * THE RULE: any change INSIDE this struct bumps AERIAL_ABI. Anything below it is COE-private and
 * changes freely, because nothing outside the COE addresses it -- the host reaches the volatile
 * interior through the published pointers below (x_knobs, x_win_slots), never by offset.
 * The generic mod4a loader does NOT gate on abi_version (it accepts any COE by code_sum hash), so a
 * stale COE is not refused at load -- it is caught instead by the detours' `if(!CTX)` stay-stock path
 * and by the host's aerial_abi.pl, which verifies this abi_version against the source tree. */
typedef struct {
    u32 abi_version;                  /* +0    == AERIAL_ABI. Read this before trusting any offset. */
    /* ---- exports: published BY the COE (coe_init), called by the COE's own detours and the host ---- */
    u32 x_aerial_coe_start;           /* +4    void(*)(void)     -- host: buffers + threads (the "enable") */
    u32 x_aerial_deactivate_region;   /* +8    void(*)(void)     -- host: stand down                      */
    u32 x_aerial_suppress_native_L3;  /* +12   int (*)(u32 self) -- kind5 PRE: 1 = suppress native blit   */
    u32 x_aerial_draw_L3;             /* +16   int (*)(u32 self) -- kind5 POST: draw our tiles to L3      */
    u32 x_compositeLayers_6_3_2_hook; /* +20   int (*)(self,phase,flags,rect) -- the REVEAL (pre-blit)    */
    /* ---- published INTERIOR POINTERS: how the host reaches COE-private state without knowing
     * a single interior offset. Add to these rather than teaching a script a new displacement. ---- */
    u32 x_knobs;                      /* +24   &fence_max -- host pokes the Coral fence + mask_z knobs */
    u32 x_win_slots;                  /* +28   &win[0]    -- per-window state; stride = sizeof(wslot_t)   */
    u32 x_reserved[24];               /* +32..+127  future exports without a re-layout                    */
    u32 fw_reserved[16];              /* +128..+191  detour->brain headroom without a re-layout            */
} aerial_abi_t;                       /* 192 bytes */

typedef struct {
    aerial_abi_t abi;                         /* +0 -- THE ABI CONTRACT (see above). */
    /* ================= everything below here is COE-PRIVATE and freely re-arrangeable ================= */
    u8 inited, enabled, active;               /* enabled = feature flag (aerial_coe_start) */
    u32 card_gen, tick;
    u32 scr_w, scr_h;                         /* derived once from the CRTC */
    /* THE FUSED PYRAMID: every .RCT on the card merged into one zdir over the union zmin..zmax.
     * Each block carries its own file handle, so nothing here is per-region scratch any more. */
    zoomdir_t* zdir; u32 zmin,zmax; void* blob;
    /* THE REGION SET's authored level: the MIN zoom_author (hdr+0x0a) over every file on the card,
     * 0 if no file declares one. Set-wide by contract -- the files on a card are a SET, and each
     * carries the set's properties redundantly because the set has no file of its own. MIN (not
     * MAX) because a level finer than some file's data leaves that file with no coverage outline
     * at all, so its imagery would draw but never be revealed; coarser only blunts the outline.
     * zauthor_split records that they disagreed, which is a card-authoring error we absorb but
     * report (see the hbuddy stamp in chartset_load). */
    u32 zauthor, zauthor_split;
    u16* backbuf;                             /* scr_w*scr_h offscreen composite (alloc once) */
    s32 last_e0,last_n0,last_e1,last_n1;      /* last-composed view bounds (recompose gate) */
    u32 drawing;                              /* tiles placed by the IN-PROGRESS compose */
    u32 drew;                                 /* tiles from the LAST COMPLETED compose (present gate) */
    /* Teardown asked the 6_3_2 hook to UN-REVEAL key3 (restore the opaque fill band). A small
     * countdown, not a latch: set at teardown, decremented per fills-branch composite, and
     * ZEROED by chartset_load on every activation -- so it cannot survive into a live session.
     * The branch that consumes it lives inside `if(!c->active)`, so it is structurally
     * unreachable while we are filtering; a stale value can never undo a live reveal. */
    u32 unreveal_pending;
    /* SWP spinlock guarding the CHARTSET STRUCTURES (zdir / blocks / presence bitmaps) against
     * a cross-thread free. Needed from Phase 2 on: build_mask made the PAINT thread a reader of
     * those structures for the first time -- every earlier reveal only walked key3 -- while
     * chartset_teardown frees them from the RENDER thread. Same bounded-SWP idiom as hbuddy's ring lock;
     * ARMv4T has no ldrex, and an unbounded spin inside the compositor is not acceptable. */
    u32 mask_lock;
    u8 thread_started; void* thread_tcb;      /* background render thread (spawned once) */
    cslot_t cache[CACHE_SLOTS];
    /* RE-ENTRANCY GUARD ON draw_window_L3 -- the pd whose backbuffer rect is being rewritten right
     * now, 0 = none. Not a nested re-entry: the two entries are on DIFFERENT THREADS, which is why
     * the ordinary "one thread, one call" reasoning never flagged it. It guards the same thing a
     * re-entrancy bit would -- a blit at the wrong time.
     *
     * THERE ARE TWO backbuffer->L3 blitters, both calling draw_window_L3, and only one was
     * interlocked. compose_win (render thread) writes the buffer then blits it; aerial_draw_L3
     * (paint thread) blits it whenever `s->drew` is nonzero -- and drew is the tile count of the
     * LAST COMPLETED compose, never cleared when a new one starts. So for the whole duration of a
     * compose -- long by design, RM_THREADSLEEP(1) between every tile -- a paint pass could copy
     * out a half-built buffer: green fill wherever the tiler had not yet reached.
     *
     * compose_win's s->dirty check does NOT cover this. It guarantees VIEW coherency (never commit
     * a frame built for a view that has since moved); it says nothing about BUFFER coherency
     * against a concurrent reader, because it only governs the render thread's own commit.
     *
     * ONE word suffices: a single render thread composes one window at a time. Storing the pd
     * rather than a bit keeps it per-window -- a paint on the OTHER window touches a disjoint rect
     * of the same buffer and is never declined. */
    u32 blit_guard_pd;
    u32 pad_b[6];
    /* per-window state. Host reaches this via abi.x_win_slots (stride = sizeof(wslot_t)). */
    wslot_t win[RC_SLOTS];
    u8 evgrp[EVGRP_SZ];          /* the RayLib AUTO-RESET wake group (0x2c bytes) */
    u8 ev_ok;                    /* group created OK -> the thread may block on it */
    u32 poller_tcb;              /* card/AO poller thread TCB ptr (runtime scratch, not an export) */
    /* CORAL FENCE + MASK_Z -- FEATURE knobs, not instrumentation (they were misfiled among the
     * old tr_ ring fields). The host reaches them through the published pointer abi.x_knobs
     * (= &fence_max); keep the four contiguous and in this order.
     *
     * THE FENCE: before the key3 remap we wait for the graphics engine to go idle, because the
     * chart render into key3 is still in flight and a remap that races it loses the leading rows
     * (the top-band defect). fence_max is the MAXIMUM poll iterations; the bound is not optional --
     * the firmware ships a "Coral Command List Timeout Exceed" string, i.e. the vendor's own driver
     * expects this engine to hang, and we must never spin forever inside the compositor. BAKED to
     * FENCE_DEFAULT at init; poke it to 0 to reproduce the defect on demand.
     *
     * MASK_Z: the zoom at which the reveal contour is cut -- LOWER = coarser/blockier/cheaper,
     * HIGHER = finer. Baked to MASK_Z at init, poke-able via `aerial_abi.pl maskz N`; build_mask
     * clamps it to the card's zmin..zmax and every window's mask self-invalidates on a change
     * (wslot.mask_built_z), so a poke takes effect on the next composite with no reboot. */
    u32 fence_max;              /* max CTR poll iterations before the reveal (0 = off) -- x_knobs+0  */
    u32 fence_waits;            /* iterations the last fence actually consumed         -- x_knobs+4  */
    u32 fence_ctr_in;           /* CTR as the last fence found it (pre-wait)           -- x_knobs+8  */
    u32 mask_z;                 /* reveal-contour zoom level (poke-able)               -- x_knobs+12 */
    /* ---- THE FUSED CHARTSET. Every .RCT on the card is merged into the ONE pyramid at
     * c->zdir / c->zmin..c->zmax above; regions no longer exist as a runtime concept. The only
     * per-file state left is the open handle (each block remembers its own in block_t.fh) --
     * kept here purely so teardown can close them. */
    u32 nfiles;
    void* fhs[MAX_FILES];
    /* Union merc bbox over every block of every file. Not used by the tile path (draw_level
     * derives its range from the VIEW), but it is the cheap "does the view touch any coverage
     * at all" reject that the Phase 2 reveal skip needs. */
    s32 cov_e0,cov_n0,cov_e1,cov_n1;
} aerial_ctx_t;
/* the anchor moved from the shaky 0x024ec620 (CF-driver+0x8e8 padding) to a vetted
 * dead .bss word -- iface[3] of the InterNiche interface array, which prep_modules frees at
 * boot on this 1-NIC hardware (region D2 of the reclaimed dead-.bss). 12 bytes = 3 words:
 *   +0x00 CTX (the one heap-object pointer)   +0x04 aerial_flags   +0x08 reserved.
 * .bss => zero from cold boot, so `if(!CTX)` is a valid "not booted" test with no init. */
#define CTX          (*(aerial_ctx_t**)0x044bb300)   /* slot4.ctx   (word 0): the one and only ctx anchor */
#define AERIAL_FLAGS (*(volatile u32*)0x044bb304)    /* slot4.flags (word 1): byte0 = STATE (LL->LOADED; coe_init INITED->RUNNING) */
#define AERIAL_SLOT  ((coe_slot_t*)0x044bb300)       /* the 12-B contract slot = D2[4]; COMPOSITE_FLAGS is slot4.spare */
#define AF_READ_TRIED 1u                      /* set once per card-presence: gates re-boot */

/* The detour is naked asm and needs the export offsets as literal ldr displacements.
 * These _Static_asserts (expressible because the detours and this struct share one COE file) make
 * the literals un-driftable: change aerial_ctx_t above and the build FAILS here, not on the boat. */
/* Offsets into aerial_abi_t. Because that struct sits at ctx+0 these are ALSO ctx offsets, which
 * is the point: they are small, they are stable, and they can never approach the ldr imm12 ceiling
 * no matter how the COE-private tail grows. */
#define EXP_ENABLE       4   /* x_aerial_coe_start          -- host: the "enable"    */
#define EXP_DEACTIVATE   8   /* x_aerial_deactivate_region  -- host: stand down      */
#define EXP_SUPPRESS    12   /* x_aerial_suppress_native_L3 -- kind5 pre             */
#define EXP_DRAW        16   /* x_aerial_draw_L3            -- kind5 post            */
#define EXP_632         20   /* x_compositeLayers_6_3_2_hook -- the reveal           */
_Static_assert(offsetof(aerial_ctx_t, abi)                          == 0,              "aerial_abi_t must sit at ctx+0");
_Static_assert(offsetof(aerial_abi_t, abi_version)                  == 0,              "abi_version must sit at abi+0");
_Static_assert(offsetof(aerial_abi_t, x_aerial_coe_start)           == EXP_ENABLE,     "detour EXP_ENABLE drift");
_Static_assert(offsetof(aerial_abi_t, x_aerial_deactivate_region)   == EXP_DEACTIVATE, "detour EXP_DEACTIVATE drift");
_Static_assert(offsetof(aerial_abi_t, x_aerial_suppress_native_L3)  == EXP_SUPPRESS,   "detour EXP_SUPPRESS drift");
_Static_assert(offsetof(aerial_abi_t, x_aerial_draw_L3)             == EXP_DRAW,       "detour EXP_DRAW drift");
_Static_assert(offsetof(aerial_abi_t, x_compositeLayers_6_3_2_hook) == EXP_632,        "detour EXP_632 drift");
_Static_assert(sizeof(aerial_abi_t) == 192, "aerial_abi_t size drift -- bump AERIAL_ABI deliberately, never by accident");
/* HOST contract: the host reaches the fence + mask knobs through abi.x_knobs (= &fence_max);
 * keep the four contiguous. (The trace RING is HBUDDY.COE's now, read from its own DRAM region,
 * so no ring layout is asserted here -- hbuddy.h owns that.) */
#define KNB(f) (offsetof(aerial_ctx_t,f) - offsetof(aerial_ctx_t,fence_max))
_Static_assert(KNB(fence_waits)  ==  4, "knob block layout drift (fence_waits)");
_Static_assert(KNB(fence_ctr_in) ==  8, "knob block layout drift (fence_ctr_in)");
_Static_assert(KNB(mask_z)       == 12, "knob block layout drift (mask_z)");

#define STR2(x) #x
#define XSTR(x) STR2(x)                       /* -> the EXP_* literal inside the naked asm */

/* ---- THIS feature's identity ----------------------------------------------
 * The COE builder stamps MAGIC/format/code_sum into AERIAL.COE's header; the generic mod4a loader
 * (coe_load) checks magic + format + code_sum. The loader knows no feature -- it only verifies what
 * it is handed. (AERIAL_ABI is the export-table contract; the loader does NOT check it.) coe_hdr_t
 * and COE_FORMAT/COE_MAGIC now come from coe_common.h. */
#define AERIAL_MAGIC 0x31454f43u              /* 'COE1' -- the COE magic (_coe_build parses this ..._MAGIC) */
#define AERIAL_ABI   8u                       /* export-table contract. 8 = CF_TRACE retired: the drawOverlays + 4_6_1
                                               * detour exports and the trace-only hook_call_site field are gone; the only
                                               * detours now are kind5 (suppress/draw) + 6_3_2 (reveal). x_knobs/x_win_slots
                                               * shifted to +24/+28; struct held at 192. Any change INSIDE aerial_abi_t bumps this. */

#ifdef COE_BUILD
/* ======================================================================================
 * THE SELF-INSTALLED DETOURS -- part of the COE (compiled WITH -DCOE_BUILD, packed into
 * AERIAL.COE). coe_common's apply_edits installs an 8-byte `ldr pc` splice on each detour's firmware
 * site (the @hook table up top); the detour body runs in the heap-loaded COE, reads CTX from the
 * aerial anchor (0x044bb300) that coe_init publishes, and falls through its if(!CTX) stay-stock path
 * until then. The generic linking loader (coe_load, the mod4a scan) lives in mods/mod005.c.
 * ==================================================================================== */


/* @place run05 -- THE DETOUR. Spliced-to over compositeKey5_to_L3's
 * head @0x006da638 via `b` (so at entry r0=this, r1=0, r2=this+0xf0, lr=the dispatcher).
 * Calls the brain THROUGH the export table instead of `bl`-ing it, because the brain now
 * lives in the heap-loaded COE. `if(!CTX)` or an unpublished export -> native-only, which
 * is the stay-stock path. r5=CTX survives the trampoline call: compositeKey5_to_L3's own
 * prologue (e92d40f0 = stmdb {r4-r7,lr}) saves and restores r4-r7. ARMv4T: no blx. */
__attribute__((naked)) void compositeKey5_to_L3_detour(void)
{
    __asm__ volatile(
        "stmdb sp!, {r0,r1,r2,r3,r4,r5,r6,lr}\n" /* native args + scratch + lr (32B, 8-aligned) */
        "ldr r5, .L_ctx_k5\n"                    /* CTX from the aerial anchor (coe_init publishes it) */
        "ldr r5, [r5]\n"
        "cmp r5, #0\n"
        "beq 1f\n"                               /* !CTX -> native only (stay stock) */
        "ldr r6, [r5, #" XSTR(EXP_SUPPRESS) "]\n"/* r6 = c->abi.x_aerial_suppress_native_L3 */
        "cmp r6, #0\n"
        "beq 1f\n"                               /* export not published yet -> native only */
        "ldr r0, [sp]\n"                         /* r0 = this */
        "mov lr, pc\n"
        "bx r6\n"                                /* r0 = note(this): 1 => suppress native's blit */
        "mov r4, r0\n"
        "ldmia sp, {r0,r1,r2,r3}\n"              /* restore native's args (sp not popped) */
        "tst r4, #1\n"
        "bleq compositeKey5_to_L3_trampoline\n"               /* not suppressed -> native key-5 -> L3 blit */
        "mov r4, r0\n"                           /* preserve native's return across our hook */
        "ldr r6, [r5, #" XSTR(EXP_DRAW) "]\n"    /* r6 = c->abi.x_aerial_draw_L3 */
        "cmp r6, #0\n"
        "beq 2f\n"
        "ldr r0, [sp]\n"                         /* r0 = this again (paint is per-window) */
        "mov lr, pc\n"
        "bx r6\n"                                /* APPEND our photo -- the LAST write to L3 */
        "2:\n"
        "mov r0, r4\n"                           /* r0 = native's return (dispatcher ignores it) */
        "add sp, sp, #16\n"                      /* drop saved r0-r3 */
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"                                /* back to the dispatcher */
        "1:\n"                                   /* ---- native-only path ---- */
        "ldmia sp, {r0,r1,r2,r3}\n"
        "bl compositeKey5_to_L3_trampoline\n"
        "add sp, sp, #16\n"
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"
        ".L_ctx_k5: .word 0x044bb300\n"
    );
}

/* @place run05 -- the displaced native prologue + continuation (compositeKey5_to_L3).
 * Reached by `bl` from the detour with args intact; native's epilogue pops the pushed lr
 * -> returns into the detour, which then appends. Firmware, PC-relative -- no export. */
__attribute__((naked)) void compositeKey5_to_L3_trampoline(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4,r5,r6,r7,lr}\n"       /* displaced instr 1 @0x006da638 (e92d40f0) */
        "sub sp, sp, #0x20\n"                 /* displaced instr 2 @0x006da63c (e24dd020) */
        "mov ip, #0x006d0000\n"
        "orr ip, ip, #0xa600\n"
        "orr ip, ip, #0x40\n"                 /* ip = 0x006da640 = site+8 (COE 8-byte splice displaces 2) */
        "bx ip\n"
    );
}

/* @place 0x006da638 -- the in-place splice: the linker drops this single branch onto
 * compositeKey5_to_L3's first instruction, replacing its stmdb with `b compositeKey5_to_L3_detour`.
 * `b` (not bl) so the detour inherits the caller's lr. This is the compositeKey5 -> L3 hook site. */
__attribute__((naked)) void compositeKey5_to_L3_splice(void){ __asm__ volatile("b compositeKey5_to_L3_detour\n"); }

/* ---- base-chart composite 6_3_2 REVEAL detour (pre-blit) --------------------------------
 * Spliced onto compositeLayers_6_3_2 @0x006da2f8 (key3(+key2) -> key6). 6_3_2 is an 8bpp INDEX
 * copy (verified live: key3==key6==key4 at fills), so a fill index remapped to its blend-twin
 * propagates to L2 unchanged. The detour calls x_compositeLayers_6_3_2_hook(self, 0, flags, rect)
 * BEFORE native (the pre-blit key3 remap = the REVEAL), then runs native 6_3_2 in full. Gated by
 * CF_HOOK_6_3_2 (bit0) + CTX + published export; the pre return (r0 & 1) could suppress native but
 * the reveal never does (always 0). `if(!CTX)`/flag-off/unpublished -> native only. Displaced
 * prologue verified live: e92d44f0 stmdb {r4,r5,r6,r7,sl,lr}; continue @0x006da2fc. */
__attribute__((naked)) void compositeLayers_6_3_2_trampoline(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4,r5,r6,r7,sl,lr}\n"       /* displaced instr 1 @0x006da2f8 (e92d44f0) */
        "sub sp, sp, #0x48\n"                    /* displaced instr 2 @0x006da2fc (e24dd048) */
        "mov ip, #0x006d0000\n"
        "orr ip, ip, #0xa300\n"                  /* ip = 0x006da300 = site+8 */
        "bx ip\n"
    );
}
__attribute__((naked)) void compositeLayers_6_3_2_detour(void)
{
    /* PRE-only reveal detour. The COE filters key3 while native's key3->key6 DMA has NOT started
     * (pre-blit reveal, no race), then runs native 6_3_2 in full. r5=CTX and r6=hook survive across
     * the native call (both callee-saved + native 6_3_2 preserves r4-r7). The reveal never suppresses
     * native (r0=0 always), so the trampoline always runs and native's r0 is returned unchanged. */
    __asm__ volatile(
        "stmdb sp!, {r0,r1,r2,r3,r4,r5,r6,lr}\n" /* native args + scratch + lr (32B, 8-aligned) */
        "ldr r5, .L_ctx_632\n"
        "ldr r5, [r5]\n"                         /* r5 = CTX */
        "cmp r5, #0\n"
        "beq 1f\n"                               /* !CTX -> native only */
        "ldr r6, .L_cf_632\n"
        "ldr r6, [r6]\n"
        "tst r6, #1\n"                           /* CF_HOOK_6_3_2 (bit0) */
        "beq 1f\n"
        "ldr r6, [r5, #" XSTR(EXP_632) "]\n"     /* r6 = c->abi.x_compositeLayers_6_3_2_hook */
        "cmp r6, #0\n"
        "beq 1f\n"                               /* export not published -> native only */
        "ldr r0, [sp]\n"                         /* r0 = this        (native r0 @[sp+0]) */
        "mov r1, #0\n"                           /* phase = PRE (the only phase now) */
        "ldr r2, [sp, #12]\n"                    /* r2 = flags       (native r3 @[sp+12], param_4) */
        "ldr r3, [sp, #4]\n"                     /* r3 = updateRect  (native r1 @[sp+4], param_2) */
        "mov lr, pc\n"
        "bx r6\n"                                /* hook(self,0,flags,rect) -> r0 = skip flag (always 0) */
        "mov r4, r0\n"                           /* r4 = pre-skip flag */
        "ldmia sp, {r0,r1,r2,r3}\n"              /* restore native args (sp not popped) */
        "tst r4, #1\n"
        "bleq compositeLayers_6_3_2_trampoline\n"/* run native 6_3_2 (never suppressed) -> r0 = native return */
        "add sp, sp, #16\n"                      /* drop saved r0-r3; native's r0 stays in r0 */
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"                                /* return native's r0 to the caller */
        "1:\n"                                   /* ---- native-only path ---- */
        "ldmia sp, {r0,r1,r2,r3}\n"              /* restore native args (sp not popped) */
        "bl compositeLayers_6_3_2_trampoline\n"  /* run native 6_3_2 IN FULL */
        "add sp, sp, #16\n"                      /* drop saved r0-r3 */
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"                                /* return native's r0 to the caller */
        ".L_ctx_632: .word 0x044bb300\n"
        ".L_cf_632:  .word 0x044bb308\n"
    );
}
/* @place 0x006da2f8 -- the in-place splice (overwrites 6_3_2's first instruction = the stmdb the
 * trampoline displaces). `b` (not bl) so the detour inherits lr. */
__attribute__((naked)) void compositeLayers_6_3_2_splice(void){ __asm__ volatile("b compositeLayers_6_3_2_detour\n"); }


#endif /* COE_BUILD -- end the self-installed detours */

#ifdef COE_BUILD
/* ======================================================================================
 * THE AERIAL BRAIN -- also part of the COE (compiled WITH -DCOE_BUILD, packed into AERIAL.COE):
 * coe_init (at the bottom) + the entire aerial brain. Loaded into heap by the mod4a loader
 * (coe_load), relocated, run. The block stays open through end-of-file (closed after coe_init).
 * ==================================================================================== */

/* decode_blob(blob,len,dst,stride) -- one JPEG blob -> RGB555 into dst[stride]. Hand-written
 * asm (recovered from the pkg#4 recipe; assembles byte-identical to the proven primitive) that
 * drives the firmware CJpeg decoder -- create/init/source/headers/prepare/start, then a scanline
 * loop packing R8G8B8 -> X1R5G5B5 -- via ABSOLUTE pointer calls (ldr ip,<pool>; bx ip), so it is
 * position-independent and runs correctly at any COE base. */
__attribute__((naked)) int decode_blob(const void* blob, u32 len, void* dst, u32 stride){
    __asm__ volatile(
        "push {r4, r5, r6, r7, r8, r9, sl, lr}\n"
        "mov r4, r2\n"                              /* r4 = dst */
        "mov r5, r3\n"                              /* r5 = dst stride (bytes) */
        "mov r6, r0\n"                              /* r6 = blob */
        "mov r7, r1\n"                              /* r7 = len */
        "sub sp, sp, #608\n"                        /* srcdesc(0x28) + arena(0x84) + object(0x1ac) + rowbuf slot */
        "add r9, sp, #172\n"                        /* r9 = decoder object base */
        "add r0, sp, #40\n"                         /* arena (132 B) */
        "ldr ip, .L_create_decoder\n"               /* create decoder */
        "mov lr, pc\n"
        "bx ip\n"
        "str r0, [r9]\n"                            /* dec[0] = sub-object */
        "mov r0, r9\n"
        "mov r1, #62\n"
        "mov r2, #428\n"
        "ldr ip, .L_init\n"                         /* init */
        "mov lr, pc\n"
        "bx ip\n"
        "str r6, [sp, #28]\n"
        "str r7, [sp, #36]\n"
        "mov r0, r9\n"
        "mov r1, sp\n"                              /* &srcdesc */
        "ldr ip, .L_Xh\n"                           /* set in-memory source */
        "mov lr, pc\n"
        "bx ip\n"
        "mov r0, r9\n"
        "mov r1, #1\n"
        "ldr ip, .L_decode_headers\n"
        "mov lr, pc\n"
        "bx ip\n"
        "cmp r0, #0\n"
        "beq .db_fail\n"
        "mov r0, r9\n"
        "ldr ip, .L_prepare_output\n"               /* prepare output (fills W/H/comps) */
        "mov lr, pc\n"
        "bx ip\n"
        "mov r0, r9\n"
        "ldr ip, .L_start_decompress\n"             /* start decompress */
        "mov lr, pc\n"
        "bx ip\n"
        "ldr sl, [r9, #92]\n"                       /* r10 = output width */
        "ldr r0, [r9, #104]\n"                      /* comps (bytes/px, 3 for RGB) */
        "mul r0, sl, r0\n"                          /* row bytes */
        "ldr ip, .L_rm_malloc\n"                    /* rm_malloc */
        "mov lr, pc\n"
        "bx ip\n"
        "movs r8, r0\n"                             /* r8 = rowbuf */
        "beq .db_fail\n"
        "str r8, [sp, #600]\n"                      /* rowbuf-ptr slot for FUN_00b293e4(&rowbuf) */
        ".db_row:\n"
        "ldr r0, [r9, #120]\n"                      /* current row */
        "ldr r1, [r9, #96]\n"                       /* height */
        "cmp r0, r1\n"
        "bge .db_done\n"
        "mov r0, r9\n"
        "add r1, sp, #600\n"                        /* &rowbuf */
        "mov r2, #1\n"
        "ldr ip, .L_decode_1_row\n"                 /* decode 1 scanline into *rowbuf */
        "mov lr, pc\n"
        "bx ip\n"
        "cmp r0, #0\n"                              /* rows emitted;  0 -> stop (guard vs stall) */
        "beq .db_done\n"
        "ldr r0, [r9, #120]\n"
        "sub r0, r0, #1\n"                          /* y (row just produced) */
        "mul r1, r0, r5\n"                          /* y * stride */
        "add r1, r4, r1\n"                          /* dst row ptr */
        "mov r0, r8\n"                              /* src = rowbuf */
        "mov r2, sl\n"                              /* pixel count = W */
        ".db_pack:\n"
        "ldrb r3, [r0], #1\n"                       /* R */
        "ldrb ip, [r0], #1\n"                       /* G */
        "ldrb lr, [r0], #1\n"                       /* B */
        "lsr r3, r3, #3\n"
        "lsl r3, r3, #10\n"                         /* R5 << 10 */
        "lsr ip, ip, #3\n"
        "orr r3, r3, ip, lsl #5\n"                  /* | G5 << 5 */
        "orr r3, r3, lr, lsr #3\n"                  /* | B5 */
        "strh r3, [r1], #2\n"                       /* store X1R5G5B5 */
        "subs r2, r2, #1\n"
        "bne .db_pack\n"
        "b .db_row\n"
        ".db_done:\n"
        "mov r0, r8\n"
        "ldr ip, .L_rm_free\n"                      /* rm_free(rowbuf) */
        "mov lr, pc\n"
        "bx ip\n"
        "mov r0, r9\n"
        "ldr ip, .L_finish\n"                       /* finish */
        "mov lr, pc\n"
        "bx ip\n"
        "mov r0, r9\n"
        "ldr ip, .L_destroy_decoder\n"              /* destroy decoder */
        "mov lr, pc\n"
        "bx ip\n"
        "mov r0, #1\n"
        "add sp, sp, #608\n"
        "pop {r4, r5, r6, r7, r8, r9, sl, pc}\n"
        ".db_fail:\n"
        "mov r0, r9\n"
        "ldr ip, .L_destroy_decoder\n"              /* destroy decoder */
        "mov lr, pc\n"
        "bx ip\n"
        "mov r0, #0\n"
        "add sp, sp, #608\n"
        "pop {r4, r5, r6, r7, r8, r9, sl, pc}\n"
        ".L_create_decoder: .word 0x00b2d040\n"     /* jpeg: create decoder */
        ".L_init: .word 0x00b28efc\n"               /* jpeg: init */
        ".L_Xh: .word 0x00b06858\n"                 /* "Xh.." */
        ".L_decode_headers: .word 0x00b28f9c\n"     /* jpeg: decode headers */
        ".L_prepare_output: .word 0x00b2ad24\n"     /* jpeg: prepare output */
        ".L_start_decompress: .word 0x00b29268\n"   /* jpeg: start decompress */
        ".L_rm_malloc: .word 0x002a9434\n"          /* rm_malloc */
        ".L_decode_1_row: .word 0x00b293e4\n"       /* jpeg: decode 1 row */
        ".L_rm_free: .word 0x001794e4\n"            /* rm_free */
        ".L_finish: .word 0x00b291ac\n"             /* jpeg: finish */
        ".L_destroy_decoder: .word 0x00b28f98\n"    /* jpeg: destroy decoder */

    );
}

/* --- signed 32-bit divide by restoring long division (no `/`, so gcc emits no
 * recursive __aeabi_idiv call). Truncating; /0 -> 0. ------------- */
int __aeabi_idiv(int a,int b){
    if(b==0) return 0;
    int neg = (a<0) ^ (b<0);
    u32 n = (a<0)?(u32)(-a):(u32)a, d = (b<0)?(u32)(-b):(u32)b;
    u32 q=0, r=0;
    for(int i=31;i>=0;i--){ r=(r<<1)|((n>>i)&1u); if(r>=d){ r-=d; q|=(1u<<i); } }
    return neg ? -(int)q : (int)q; }

/* --- small helpers (no libc on this target) ------------------------- */
static void mzero(void* p,u32 n){ u8* d=p; while(n--)*d++=0; }
static s32 imin(s32 a,s32 b){ return a<b?a:b; }
static s32 imax(s32 a,s32 b){ return a>b?a:b; }
static s32 clampi(s32 v,s32 lo,s32 hi){ return v<lo?lo:v>hi?hi:v; }

/* --- tile coverage (resident block descriptors + presence bitmaps) --- */
/* Does THIS block actually hold tile (x,y)? Range + presence in one test.
 * Bitmap bit SET = ABSENT, so resident = bit clear. */
static int block_has(block_t* b,s32 x,s32 y){
    if(x<b->x_min||x>b->x_max||y<b->y_min||y>b->y_max) return 0;
    u32 p=(u32)((y-b->y_min)*(s32)b->grid_w+(x-b->x_min));
    return (b->bitmap[p>>3]&(1u<<(p&7)))?0:1; }
/* THE FUSION CRUX: the lookup is by PRESENCE, not by index-range containment.
 * chartMaker gives adjacent regions IDENTICAL coarse parents at z10..z14, so once the files are
 * merged their blocks OVERLAP in tile-index range but DIFFER in presence -- each file's bitmap
 * marks only the parents of its OWN z15 cells. A first-block-wins lookup would report a tile
 * ABSENT because file A lacks it while file B is holding it, and overzoom would climb straight
 * past a tile we have -- dropping imagery exactly at a seam. Folding the bitmap test INTO the
 * scan makes duplicates don't-care (any copy serves; they are the same tile by construction)
 * and makes partial coverage compose correctly. */
static block_t* block_for(aerial_ctx_t* c,u32 z,s32 x,s32 y){
    if(z<c->zmin||z>c->zmax) return 0;
    zoomdir_t* zd=&c->zdir[z-c->zmin];
    for(u32 i=0;i<zd->nblk;i++){ block_t* b=&zd->blk[i]; if(block_has(b,x,y)) return b; }
    return 0; }
/* 1 = tile resident somewhere in the fused set, 0 = nobody has it. */
static int resident(aerial_ctx_t* c,u32 z,s32 x,s32 y){ return block_for(c,z,x,y)?1:0; }
/* climb to the nearest resident ancestor of (z,x,y): levels climbed k via the
 * az/ax/ay out-pointers (0 = present here), -1 if absent all the way to zmin. */
static int overzoom(aerial_ctx_t* c,u32 z,s32 x,s32 y,u32* az,s32* ax,s32* ay){
    u32 zz=z; s32 xx=x,yy=y; int k=0;
    for(;;){
        if(resident(c,zz,xx,yy)){ *az=zz; *ax=xx; *ay=yy; return k; }
        if(zz==c->zmin) return -1;
        zz--; xx>>=1; yy>>=1; k++; } }

/* Read one tile's JPEG blob into c->blob via the on-disk dense index. */
static u32 tile_read(aerial_ctx_t* c,block_t* b,s32 x,s32 y,u32* len){
    u32 slot=(u32)((y-b->y_min)*(s32)b->grid_w+(x-b->x_min)), ent[2], got;
    if(FX_SEEK(b->fh,b->index_off+slot*8)) return 0;              /* b->fh: the file THIS block came from */
    if(FX_READ(b->fh,ent,8,&got)||got!=8||ent[0]==0) return 0;    /* {offset,length} */
    if(FX_SEEK(b->fh,ent[0])) return 0;
    if(FX_READ(b->fh,c->blob,ent[1],&got)||got!=ent[1]) return 0;
    *len=ent[1]; return 1; }

/* --- decoded-tile cache (fixed slots, LRU by c->tick) --------------- */
static cslot_t* cache_find(aerial_ctx_t* c,u32 z,s32 x,s32 y){
    for(u32 i=0;i<CACHE_SLOTS;i++){ cslot_t* s=&c->cache[i];
        if(s->used&&s->z==z&&s->x==x&&s->y==y){ s->lru=++c->tick; return s; } }
    return 0; }
static cslot_t* cache_take(aerial_ctx_t* c){
    cslot_t* best=&c->cache[0];
    for(u32 i=1;i<CACHE_SLOTS;i++){ if(!c->cache[i].used) return &c->cache[i];
        if(c->cache[i].lru<best->lru) best=&c->cache[i]; }
    return best; }
static cslot_t* tile_get(aerial_ctx_t* c,block_t* b,u32 z,s32 x,s32 y){
    cslot_t* s=cache_find(c,z,x,y); if(s) return s;
    u32 len; if(!tile_read(c,b,x,y,&len)) return 0;
    s=cache_take(c);
    if(decode_blob(c->blob,len,s->px,TILE_PX*2)!=1){ s->used=0; return 0; }
    s->used=1; s->z=(u8)z; s->x=x; s->y=y; s->lru=++c->tick; return s; }

/* --- rasteriser: decoded tile -> geo-placed pixels in a dest buffer -- */
/* NN-scale a source sub-square into dest rect (dx,dy,dw,dh), clipped to the window
 * rect, writing to dst[stride]. FIXED-POINT source stepping: two divides per tile
 * (stepx/stepy) instead of one per pixel -- the hot inner loop is add+shift+copy, no
 * division and no per-pixel clip branch (was the ~4s compose bottleneck). */
static void blit(u16* dst,u32 stride,window_t* w,cslot_t* s,
                 s32 dx,s32 dy,s32 dw,s32 dh,s32 sx,s32 sy,s32 swh){
    if(dw<=0||dh<=0) return;
    s32 cx0=w->sx, cx1=w->sx+w->sw, cy0=w->sy, cy1=w->sy+w->sh;   /* clip dest to window, once */
    s32 px0=dx<cx0?cx0:dx, px1=(dx+dw)>cx1?cx1:(dx+dw);
    s32 py0=dy<cy0?cy0:dy, py1=(dy+dh)>cy1?cy1:(dy+dh);
    if(px0>=px1||py0>=py1) return;
    s32 stepx=(swh<<16)/dw, stepy=(swh<<16)/dh;                   /* 16.16 src step per dest px */
    s32 sxf0=(sx<<16)+(px0-dx)*stepx;
    for(s32 py=py0;py<py1;py++){
        const u16* sr=s->px+(u32)(sy+(((py-dy)*stepy)>>16))*TILE_PX;
        u16* dr=dst+(u32)py*stride; s32 sxf=sxf0;
        for(s32 px=px0;px<px1;px++){ dr[px]=sr[sxf>>16]; sxf+=stepx; } } }
/* Map a geo coordinate to a screen pixel by DIVIDING by semicircles-per-px (w->inv_*, Q MAP_MUL).
 * The old form multiplied by pixels-per-semicircle (scale_x = sw<<16 / span), which at coarse zoom
 * truncates to a single-digit integer -- a ~28% scale error at 48nm (~10 mi of misregistration).
 * inv_* is a LARGE integer (span dominates), so its truncation is negligible at every scale. */
static s32 map_x(window_t* w,s32 e){ return w->sx+((e-w->org_e)*MAP_MUL)/w->inv_e; }
static s32 map_y(window_t* w,s32 n){ return w->sy+((n-w->org_n)*MAP_MUL)/w->inv_n; }

/* Place tile (z,x,y): overzoom to a present ancestor, map that tile's block-exact
 * merc corners to the window, blit the sub-square into the backbuffer. */
static void place(aerial_ctx_t* c,window_t* w,u32 z,s32 x,s32 y){
    u32 az; s32 ax,ay; int k=overzoom(c,z,x,y,&az,&ax,&ay); if(k<0) return;
    block_t* b=block_for(c,az,ax,ay); cslot_t* s=tile_get(c,b,az,ax,ay); if(!s) return;
    s32 m=(1<<k)-1, swh=TILE_PX>>k;
    /* Geo corners of the REQUESTED tile (z,x,y) = its (x&m,y&m) sub-cell of the RESIDENT ancestor
     * tile (ax,ay). The bug was computing them with the ancestor's step + the requested index; that
     * over-magnifies an overzoom to 2^(2k). Using the ancestor tile's own extent + the ancestor step
     * DIVIDED by 2^k makes it the correct 2^k oversample. (k=0 reduces to the old exact placement.)
     * NB the requested-zoom block does NOT exist where the pyramid is sparse (no z17 block at Crawl
     * Cay), so we must derive the corners from the ancestor, never block_for(z,...). */
    s32 a_ew=b->merc_e_w+(ax-b->x_min)*b->step_e, se=b->step_e>>k;   /* ancestor west ; sub-tile e-step */
    s32 a_nn=b->merc_n_n+(ay-b->y_min)*b->step_n, sn=b->step_n>>k;   /* ancestor north; sub-tile n-step */
    s32 ew=a_ew+(x&m)*se, ee=ew+se;
    s32 nn=a_nn+(y&m)*sn, ns=nn+sn;
    s32 dx=map_x(w,ew), dy=map_y(w,nn), dw=map_x(w,ee)-dx, dh=map_y(w,ns)-dy;
    blit(c->backbuf,c->scr_w,w,s,dx,dy,dw,dh,(x&m)*swh,(y&m)*swh,swh);
    c->drawing++; }

/* THIS window's live view bounds {e0,n0,e1,n1} (semicircles), from ITS OWN controller.
 * rc+0x9c = the geometry provider; obj = prov-4; bounds obj+0x2b4. */
static s32* rc_bounds(u8* rc){
    if(!rc) return 0;
    void* prov=*(void**)(rc+0x9c); if(!prov) return 0;
    return (s32*)((u8*)prov-4+0x2b4); }

/* Pair a ChartingAppPD `this` to its PhotoOverlayRC by scanning the live registry for the
 * slot whose +0x7c points into it (PD = *(RC+0x7c) - 0x0c). Returns 0 if `pd` is not a
 * live chart window -- which is the page-change guard: nothing cached, nothing to go stale. */
static u8* rc_for_pd(u32 pd){
    for(u32 i=0;i<RC_SLOTS;i++){
        u8* rc=RC_REG[i]; if(!rc) continue;
        u32 p=*(u32*)(rc+0x7c);
        if(p && p-0x0c==pd) return rc; }
    return 0; }

/* THIS window's screen rect, straight off the PD: pd+0xf0 = {sx,sy,ex,ey} where ex,ey are
 * INCLUSIVE (maxx/maxy, the last pixel) -- so width = ex-sx+1 (628 not 627), height = ey-sy+1
 * (348 not 347); matches the key-buffer size exactly. The call site itself
 * passes pd+0xf0 as compositeKey5_to_L3's 3rd arg, so this is native's own notion of the
 * window. Replaces the old L3-descriptor read, which was ONE GLOBAL holding whichever
 * window last bound target 3 (measured: it held the RIGHT window's rect while the hook was
 * entered on the LEFT window's PD) and a hardcoded 628x348 fallback. */
static int pd_rect(u32 pd,window_t* w){
    s32* r=(s32*)(pd+0xf0);
    s32 ww=r[2]-r[0]+1, hh=r[3]-r[1]+1;   /* +1: ex,ey are inclusive maxx/maxy, not one-past */
    if(ww<=0||hh<=0) return 0;
    w->sx=r[0]; w->sy=r[1]; w->sw=ww; w->sh=hh; return 1; }

/* Derive the window's geo->screen affine from the SNAPSHOT view bounds (passed in, not re-read from
 * the live RC). The window rect (sx,sy,sw,sh) is already in w. */
static int view_affine(window_t* w,s32 e0,s32 n0,s32 e1,s32 n1){
    if(e1==e0||n1==n0) return 0;
    w->org_e=e0; w->org_n=n0;
    w->span_e=e1-e0; w->span_n=n1-n0;
    w->scale_x=(w->sw<<AFFS)/w->span_e; w->scale_y=(w->sh<<AFFS)/w->span_n;  /* pick_zoom magnitude only */
    w->inv_e=(w->span_e*MAP_MUL)/w->sw; w->inv_n=(w->span_n*MAP_MUL)/w->sh;  /* precise geo->screen inverse */
    return 1; }

/* Does any block at zoom z INTERSECT the view rect? A block spans east
 * [merc_e_w, merc_e_w+grid_w*step_e] and north [merc_n_n+grid_h*step_n, merc_n_n]
 * (step_n<0, so south=merc_n_n+grid_h*step_n is the smaller). imin/imax makes the range
 * check sign-agnostic.
 *
 * A RECT test, not a point test. Testing the view CENTRE asked "what resolution is available
 * where the middle of the screen happens to be", which decides the level by where the boat sits
 * rather than by what the card holds for the view -- so a hi-res block reaching into the view
 * was ignored whenever the centre lay outside it. */
static int level_intersects_view(aerial_ctx_t* c,u32 z,s32 vew,s32 vee,s32 vns,s32 vnn){
    if(z<c->zmin||z>c->zmax) return 0;
    zoomdir_t* zd=&c->zdir[z-c->zmin];
    for(u32 i=0;i<zd->nblk;i++){ block_t* b=&zd->blk[i];
        if(!b->step_e||!b->step_n) continue;
        s32 e_e=b->merc_e_w+(s32)b->grid_w*b->step_e;   /* opposite east edge */
        s32 n_s=b->merc_n_n+(s32)b->grid_h*b->step_n;   /* opposite (south) edge */
        s32 ew=imin(b->merc_e_w,e_e), ee=imax(b->merc_e_w,e_e);
        s32 ns=imin(b->merc_n_n,n_s), nn=imax(b->merc_n_n,n_s);
        if(!(ee<vew||ew>vee||nn<vns||ns>vnn)) return 1; }
    return 0; }

/* Pick the pyramid zoom whose 256px tile lands nearest 256px on screen. */
static u32 pick_zoom(aerial_ctx_t* c,window_t* w){
    s32 sx=w->scale_x<0?-w->scale_x:w->scale_x;
    u32 z=c->zmin; s32 best=0x7fffffff;
    for(u32 zz=c->zmin;zz<=c->zmax;zz++){
        s32 tpx=(zz<16)?(sx<<(16-zz)):(sx>>(zz-16));
        s32 d=tpx>256?tpx-256:256-tpx;
        if(d<best){best=d;z=zz;} }
    /* THE LEVEL IS min(scale-ideal, best level with data ANYWHERE in the view). The pyramid is
     * sparse -- z17/z18 exist only at popa00 -- so the scale-ideal level may hold nothing here;
     * clamp DOWN to the highest level <= ideal that intersects the view.
     *
     * Both halves earn their place. The CEILING matters because finer than scale-ideal is
     * invisible: at ideal a source tile lands ~256 px, so z18 data in a 12 nm view would be
     * hundreds of tiles thrown away by the downscale. The CLAMP matters because gridding at a
     * level with no data here would make every cell overzoom to the same ancestor -- correct,
     * but several blits of one tile instead of one blit of it.
     *
     * Absent INDIVIDUAL tiles inside the chosen level are handled by overzoom in place(). */
    s32 pe0=w->org_e, pe1=pe0+w->span_e, pn0=w->org_n, pn1=pn0+w->span_n;
    s32 vew=imin(pe0,pe1), vee=imax(pe0,pe1), vns=imin(pn0,pn1), vnn=imax(pn0,pn1);
    while(z>c->zmin && !level_intersects_view(c,z,vew,vee,vns,vnn)) z--;
    return z; }

/* Draw the VIEW at one zoom level into the backbuffer window rect.
 *
 * ITERATE THE SCREEN, NOT THE DATA. The loop walks the view's own tile range once and asks
 * place() -- hence overzoom() -- to resolve each cell. It does NOT walk the blocks asking which
 * of their tiles land on screen.
 *
 * That inversion is the whole fix. Clamping the view range to each block's index range meant a
 * cell outside every block at this level was never iterated, so place() was never called for it
 * and overzoom never got the chance to backfill it from a coarser ancestor -- even where that
 * ancestor plainly existed and covered the ground. The overhang past a block edge stayed
 * whatever the compose pre-filled, which is the green band across the top or bottom of a window
 * (the clamp is per-axis, which is why the artifact is always a band and never a corner).
 *
 * It also does LESS work, not more, on a fused card. chartMaker gives adjacent regions IDENTICAL
 * coarse parents, so at coarse levels several blocks overlap in index range and the per-block
 * loop drew the same tile once per block. The view range draws each cell exactly once.
 *
 * COORDINATES. X is global: the tile column follows from the merc easting by a shift, no block
 * needed. Y needs an anchor (origin + step), so it is taken from any block at this level -- tile
 * indices are global AT a level, which is precisely the property the fused presence lookup and
 * overzoom's x>>=1,y>>=1 climb already depend on. Deriving Y from a reference block keeps the
 * proven block-relative arithmetic rather than inventing a global formula for it.
 *
 * The +-1 slop stays: it covers the truncation in that divide and the partial tiles at the view
 * edges. Cost is bounded by the SCREEN, not by the data -- pick_zoom scale-matches to ~256 px per
 * tile, so the window is ~3-4 tiles across at whatever level is chosen. A cell with no ancestor
 * anywhere is skipped by place(); the reveal mask keeps the chart opaque over that ground. */
static void draw_level(aerial_ctx_t* c,window_t* w,u32 z,wslot_t* s){
    s32 e0=w->org_e, e1=e0+w->span_e;   /* EXACT view span -- reconstructing e1 from the truncated */
    s32 n0=w->org_n, n1=n0+w->span_n;   /* scale_x/scale_y undershot the extent at coarse zoom */
    s32 e_w=imin(e0,e1), e_e=imax(e0,e1), n_s=imin(n0,n1), n_n=imax(n0,n1);
    u32 sh=32-z;
    s32 tx0=(s32)((u32)(e_w+0x80000000u)>>sh)-1, tx1=(s32)((u32)(e_e+0x80000000u)>>sh)+1;
    zoomdir_t* zd=&c->zdir[z-c->zmin];
    block_t* r=0;                                          /* Y coordinate reference (any block) */
    for(u32 bi=0;bi<zd->nblk;bi++) if(zd->blk[bi].step_n){ r=&zd->blk[bi]; break; }
    if(!r) return;                                         /* no usable block at this level */
    s32 ty0=r->y_min+(n_n-r->merc_n_n)/r->step_n-1;        /* view -> tile rows (step_n<0) */
    s32 ty1=r->y_min+(n_s-r->merc_n_n)/r->step_n+1;
    for(s32 ty=ty0;ty<=ty1;ty++) for(s32 tx=tx0;tx<=tx1;tx++){
        if(s->dirty) return;                               /* INTERRUPT: a paint hook set this window's
                                                            * s->dirty (the view moved) -> bail out of
                                                            * tiling now; compose_win drops the partial. */
        place(c,w,z,tx,ty); RM_THREADSLEEP(1); } }         /* yield the core between tiles (UI stays live) */

/* Top-down composite into the backbuffer: coarse base (full coverage, no edge
 * gaps) then the detail level on top where present.
 * c->drawing is SCRATCH for one compose -- safe because the single render thread composes
 * one window at a time -- and is PUBLISHED to the window's own slot->drew by compose_win(). */
static void compose(aerial_ctx_t* c,window_t* w,s32 e0,s32 n0,s32 e1,s32 n1,wslot_t* s){
    if(!view_affine(w,e0,n0,e1,n1)) return;
    c->drawing=0;
    /* GREEN tiler diagnostic (CF_GREEN, bit28 -- ON in CF_DEFAULT deliberately): pre-fill THIS
     * window's backbuffer rect with green (0x03e0 = RGB555 pure green) BEFORE tiling, so any area the
     * tiler doesn't cover shows green in the L3 photo. With the aperture bounded to authored ground
     * and the backbuffer guarded against a mid-write blit, green now means exactly one thing --
     * the tiler failed to cover ground the mask says is covered. Full-window write => perf cost. */
    if(COMPOSITE_FLAGS & CF_GREEN){
        for(s32 ry=0;ry<w->sh;ry++){ s32 y=w->sy+ry; if(y<0||(u32)y>=c->scr_h) continue;
            u16* d=c->backbuf+(u32)y*c->scr_w+w->sx;
            for(s32 rx=0;rx<w->sw;rx++){ s32 x=w->sx+rx; if(x<0||(u32)x>=c->scr_w) continue; d[rx]=0x03e0; } } }
    /* ONE flat tile set, ONE chooser, ONE level. Every block carries its own file handle, so a
     * single pick over the fused pyramid is both correct and seam-free by construction -- no
     * per-region loop, and nothing about the level depends on which file a tile came from. */
    u32 pick=pick_zoom(c,w); w->zoom=(u8)pick;
    /* One level. Per-tile overzoom backfills from the nearest present ancestor, so a separate
     * coarse prefill pass adds nothing. */
    draw_level(c,w,pick,s);
}

/* Copy the composited window rect from the backbuffer into the live L3 buffer. */
static void draw_window_L3(aerial_ctx_t* c,window_t* w){
    u16* pl=L3_BASE(); if(!pl) return;
    for(s32 ry=0;ry<w->sh;ry++){ s32 y=w->sy+ry; if(y<0||(u32)y>=c->scr_h) continue;
        u16* d=pl+(u32)y*c->scr_w+w->sx; const u16* s=c->backbuf+(u32)y*c->scr_w+w->sx;
        for(s32 rx=0;rx<w->sw;rx++) d[rx]=s[rx]; } }

/* PHASE 2 step 1 -- THE BBOX REJECT.
 * Does this window's view touch ANY loaded coverage? c->cov_* is the union merc bbox over every
 * block of every .RCT, computed once at chartset_load, and nothing else reads it. When the answer
 * is no there is nothing to reveal, so the whole key3 walk (~307k pixels) is skipped outright --
 * and, more importantly, the chart stays OPAQUE instead of exposing an empty backbuffer.
 *
 * Deliberately NOT the RCT header bounds (0x18/0x20/0x28/0x30): those are WGS84 doubles, while
 * cov_* is integer merc directly comparable to the view. No floating point, no conversion.
 *
 * The union bbox is loose for a multi-region card spanning open water -- that is fine here, it is
 * a cheap conservative reject; the tile mask refines it. */
static int view_has_coverage(aerial_ctx_t* c,u8* rc){
    if(!c->nfiles) return 0;
    s32* bn=rc_bounds(rc); if(!bn) return 0;
    s32 vew=imin(bn[0],bn[2]), vee=imax(bn[0],bn[2]);
    s32 vns=imin(bn[1],bn[3]), vnn=imax(bn[1],bn[3]);
    return !(c->cov_e1<vew || c->cov_e0>vee || c->cov_n1<vns || c->cov_n0>vnn); }

/* Bounded SWP lock over the chartset structures. Returns 1 if acquired. A mask build holds it for
 * only the visible-cell scan (tens of microseconds), so the render thread's teardown wins the spin
 * in practice; the bound exists so neither side can ever wedge the compositor. */
static int mask_lock_take(aerial_ctx_t* c){
    u32 got=1;
    for(u32 t=0;t<4000u && got;t++)
        __asm__ volatile("swp %0,%1,[%2]" : "=&r"(got) : "r"(1u), "r"(&c->mask_lock) : "memory");
    return !got; }
static void mask_lock_drop(aerial_ctx_t* c){ c->mask_lock=0; }

/* Build (or reuse) THIS window's reveal mask: the screen rects that have authored imagery under
 * them, in KEY-BUFFER coordinates (key3 row 0 == window top, so the window origin is subtracted).
 *
 * Cheap enough to live on the composite thread, which is the point: it needs only the view affine
 * and the resident presence bitmaps -- NO decode, NO card I/O. That is what lets the same routine
 * serve both the render thread and the paint hook, and it is why the mask is derived here rather
 * than published from compose_win (compose is slow, can bail, and 6_3_2 may not fire again after
 * it finishes -- a commit-then-consume model can leave the aperture never opening).
 *
 * Row-run merged so the rects come out DISJOINT and the list stays short (bounded by cell rows).
 * The remap is idempotent, so overlap would be correct but wasted. */
static void build_mask(aerial_ctx_t* c,wslot_t* s,u32 pd,u8* rc){
    s32* bn=rc_bounds(rc); if(!bn) return;
    u32 z=c->mask_z ? c->mask_z : MASK_Z;                /* live knob; 0 = never initialised */
    if(c->zauthor && z>c->zauthor) z=c->zauthor;         /* THE CARD CLAMPS THE KNOB: never cut the
                                                          * contour finer than the level the producer
                                                          * actually quantized the polygon at -- past
                                                          * it the bitmaps describe tile population,
                                                          * not shape. 0 = nothing declared -> MASK_Z */
    if(z>c->zmax) z=c->zmax;                             /* clamp to what this card actually has */
    if(z<c->zmin) z=c->zmin;
    if(s->mask_ok && s->mask_gen==c->card_gen && s->mask_built_z==z &&
       s->mask_e0==bn[0] && s->mask_n0==bn[1] && s->mask_e1==bn[2] && s->mask_n1==bn[3]) return;
    s->mask_ok=1; s->mask_gen=c->card_gen; s->mask_built_z=z; s->mask_full=0; s->nmrects=0;
    s->mask_e0=bn[0]; s->mask_n0=bn[1]; s->mask_e1=bn[2]; s->mask_n1=bn[3];
    window_t w;
    if(!pd_rect(pd,&w) || !view_affine(&w,bn[0],bn[1],bn[2],bn[3])){ s->mask_full=1; return; }
    /* From here we read the CHARTSET (zdir / blocks / bitmaps), which the render thread may be
     * freeing. Take the lock, then RE-VALIDATE under it -- `active` was checked by the caller
     * before this call and can have changed since. The zdir/zmax>=zmin test is the guard that was
     * briefly lost when the mask_z knob went in: with a torn-down or failed-load ctx the clamps
     * leave z==zmin and c->zdir[0] would be dereferenced through a null pointer. */
    if(!mask_lock_take(c)){ s->mask_full=1; return; }   /* contended -> safe full-plane fallback */
    if(!c->active || !c->zdir || c->zmax<c->zmin || z<c->zmin || z>c->zmax){
        s->mask_full=1; mask_lock_drop(c); return; }
    /* visible tile range at the authored level -- same derivation draw_level uses */
    s32 e0=w.org_e, e1=e0+w.span_e, n0=w.org_n, n1=n0+w.span_n;
    s32 e_w=imin(e0,e1), e_e=imax(e0,e1), n_s=imin(n0,n1), n_n=imax(n0,n1);
    u32 sh=32-z;
    s32 gx0=(s32)((u32)(e_w+0x80000000u)>>sh)-1, gx1=(s32)((u32)(e_e+0x80000000u)>>sh)+1;
    /* BLOCKS-OUTER, CELLS-INNER. Deliberately NOT a block_for() per cell: that would rescan every
     * block at this zoom for every cell, and the build could then cost as much as the pixel loop
     * it exists to shrink. Iterating blocks on the outside makes each cell exactly one bounds
     * check plus one bitmap bit-test, via block_has() on a block we already hold. Total work is
     * ~the number of VISIBLE authored cells (a few hundred to ~1400 near the range cutoff, which
     * is where key3 stops being mapped anyway) -- around 1% of the pixel loop.
     * Runs are closed at block edges as well as at absent cells; adjacent blocks therefore yield
     * separate rects. Harmless: they stay disjoint, and the remap is idempotent regardless. */
    zoomdir_t* zd=&c->zdir[z-c->zmin];
    for(u32 bi=0;bi<zd->nblk;bi++){ block_t* b=&zd->blk[bi];
        if(!b->step_n||!b->step_e) continue;
        if(gx1<b->x_min||gx0>b->x_max) continue;             /* block off-view in X */
        s32 ry0=b->y_min+(n_n-b->merc_n_n)/b->step_n-1;      /* view -> this block's tile rows */
        s32 ry1=b->y_min+(n_s-b->merc_n_n)/b->step_n+1;
        if(ry1<b->y_min||ry0>b->y_max) continue;             /* block off-view in Y */
        s32 bx0=clampi(gx0,b->x_min,b->x_max), bx1=clampi(gx1,b->x_min,b->x_max);
        s32 by0=clampi(ry0,b->y_min,b->y_max), by1=clampi(ry1,b->y_min,b->y_max);
        for(s32 ty=by0;ty<=by1;ty++){
            s32 run0=0; int inrun=0;
            for(s32 tx=bx0;tx<=bx1+1;tx++){
                int present = (tx<=bx1) ? block_has(b,tx,ty) : 0;   /* DIRECT bitmap test */
                if(present && !inrun){ run0=tx; inrun=1; continue; }
                if(present || !inrun) continue;
                /* run [run0..tx-1] closed -> one rect, mapped through the view affine */
                s32 ew=b->merc_e_w+(run0-b->x_min)*b->step_e;
                s32 ee=ew+(tx-run0)*b->step_e;
                s32 nn=b->merc_n_n+(ty-b->y_min)*b->step_n;
                s32 ns=nn+b->step_n;
                s32 x0=map_x(&w,ew)-w.sx, x1=map_x(&w,ee)-w.sx;
                s32 y0=map_y(&w,nn)-w.sy, y1=map_y(&w,ns)-w.sy;
                if(x0>x1){ s32 t=x0; x0=x1; x1=t; }
                if(y0>y1){ s32 t=y0; y0=y1; y1=t; }
                if(x0<0)x0=0; if(y0<0)y0=0;
                if(x1>w.sw-1)x1=w.sw-1; if(y1>w.sh-1)y1=w.sh-1;
                if(x0<=x1 && y0<=y1){
                    if(s->nmrects>=MASK_MAX_RECTS){ s->mask_full=1; goto done; }  /* too fragmented */
                    mrect_t* r=&s->mrects[s->nmrects++];
                    r->x0=(s16)x0; r->y0=(s16)y0; r->x1=(s16)x1; r->y1=(s16)y1; }
                inrun=0; } } }
done:
    mask_lock_drop(c); }

/* Recompose gate for ONE window: has ITS view moved since ITS last completed compose?
 * READ-ONLY -- the bounds are committed by compose_win() only when the compose finishes,
 * so an aborted/failed pass re-composes next time instead of silently going clean. */
static int slot_changed(wslot_t* s,u8* rc){
    s32* bn=rc_bounds(rc); if(!bn) return 0;
    return (bn[0]!=s->last_e0||bn[1]!=s->last_n0||bn[2]!=s->last_e1||bn[3]!=s->last_n1); }

/* Find (or claim) the slot for a ChartingAppPD. Re-pairs against the LIVE registry every
 * call: an unknown/dead pd returns 0 and the caller stands down (page-change safe).
 *
 * REAP FIRST. The render loop only reaps a dead slot if it is BOTH used AND dirty (it composes
 * only dirty slots and the liveness check sits behind that gate), so a window that dies while
 * CLEAN -- the normal case: it composed, settled to dirty=0, then the page changed -- is never
 * revisited and its slot leaks forever. After RC_SLOTS distinct windows have lived and died (a
 * couple of page changes, since each page-show mints fresh PDs) every slot is a corpse, no free
 * slot is left, this returns 0, and every new window is starved of aerial until reboot. So retire
 * any slot whose PD is no longer a live RC HERE, where the pressure to reuse it is felt -- this is
 * also the only reap path that runs when the render thread is parked with nothing dirty to wake it. */
static wslot_t* slot_for_pd(aerial_ctx_t* c,u32 pd,u8** rc_out){
    u8* rc=rc_for_pd(pd); if(!rc) return 0;
    if(rc_out) *rc_out=rc;
    for(u32 i=0;i<RC_SLOTS;i++){ wslot_t* s=&c->win[i];
        if(s->used && !rc_for_pd(s->pd)) s->used=0; }   /* reap dead-clean corpses */
    wslot_t* fr=0;
    for(u32 i=0;i<RC_SLOTS;i++){
        wslot_t* s=&c->win[i];
        if(s->used && s->pd==pd) return s;
        if(!s->used && !fr) fr=s; }
    if(!fr) return 0;
    mzero(fr,sizeof(*fr));
    fr->used=1; fr->pd=pd; fr->dirty=1;        /* new window -> compose it once */
    return fr; }

/* KEY-5 PROBE. Record THIS window's own key-5 surface so the host can read it.
 * Answers the questions that gate the hardware-blit fast path -- is key-5 per-window, what
 * are its dims, and is it VRAM-backed (desc+0 & 0x20)? -- from real data, and proves the
 * accessor the fast path will need. Read-only; never fills or frees anything. */
static void k5_probe(wslot_t* s,u32 pd){
    if(s->k5_surf) return;                     /* once per window */
    u32 key=5;
    u32 node=LAYER_LOOKUP(pd+0x60,&key); if(!node) return;
    u32 layer=*(u32*)(node+4); if(!layer) return;
    u32 surf=LAYER_SURF(layer,1); if(!surf) return;
    s->k5_surf=surf;
    s->k5_d0=*(u32*)(surf+0x00);               /* flags|bpp|w  (flags 0x20 = VRAM-backed) */
    s->k5_d1=*(u32*)(surf+0x04);               /* h|mask */
    s->k5_base=*(u32*)(surf+0x0c); }           /* VRAM base */

/* --- CRASH-PERSISTENT DIAGNOSTICS live in HBUDDY.COE now --------------------------------
 * The DRAM-survives primitive (formerly heapbuddy_arm) and the stage bitmask (formerly the
 * COE_CRUMB block) are gone from aerial: they are HBUDDY.COE's job. aerial reaches them
 * through the guarded wrappers in hbuddy.h -- hbuddy_arm() / hbuddy_stage(bit) / hbuddy_log()
 * -- each a no-op when HBUDDY.COE is absent (renamed *.off) or not yet RUNNING. So a stage
 * crumb below is now `hbuddy_stage(bit)`: it writes hbuddy's crash-persistent DRAM when the
 * library is loaded, and costs a slot-state compare + predicted branch when it is not. That
 * present/absent equivalence is exactly the drop-in test HBUDDY.COE exists to prove. */


/* Compose ONE window from ITS SNAPSHOT and publish the result. The render thread runs here and
 * NEVER dereferences a PD: rect + geo bounds come from the slot's snapshot (captured earlier by the
 * kind5 hook on the coherent PD), copied to locals so a slot reuse mid-compose cannot corrupt the
 * in-flight geometry. The PD is an IDENTITY TOKEN only. Commit is guarded: publish has_frame / bounds
 * only if this is still OUR slot (re-resolved by token through the RC registry -- no deref) and the
 * view did not move (kind5 re-set dirty) since we cleared it. Otherwise discard: a page change or a
 * pan invalidated the frame. */
static void compose_win(aerial_ctx_t* c,wslot_t* s){
    u32 pd_tok=s->pd;                          /* identity only -- never dereferenced here */
    window_t w;
    w.sx=s->snap_sx; w.sy=s->snap_sy; w.sw=s->snap_sw; w.sh=s->snap_sh;   /* COPY rect from snapshot */
    if(w.sw<=0||w.sh<=0) return;               /* no snapshot captured yet -> nothing to draw */
    s32 e0=s->snap_e0,n0=s->snap_n0,e1=s->snap_e1,n1=s->snap_n1;          /* COPY bounds from snapshot */
    if(e1==e0||n1==n0) return;
    c->blit_guard_pd=pd_tok;                   /* GUARD CLOSED (token, not a pointer we deref) */
    compose(c,&w,e0,n0,e1,n1,s);               /* draws the backbuffer from the copied snapshot */
    /* WRITE-BACK GUARD -- ALL READS, no slot mutation. rc_for_pd only scans the RC registry and
     * s->pd is an atomic word, so this never races the paint thread's slot_for_pd (which reaps/claims
     * win[]). Window dead OR slot reused for another PD -> it is not ours: do NOT touch it. (ABA on a
     * recycled PD address self-corrects via the dirty check below / slot_changed next paint.) */
    if(!rc_for_pd(pd_tok) || s->pd!=pd_tok){ c->blit_guard_pd=0; return; }
    /* Still ours, but the view moved (kind5 re-set dirty) -> invalidate + recompose next pass. */
    if(s->dirty){ s->drew=0; c->blit_guard_pd=0; return; }
    s->last_e0=e0; s->last_n0=n0; s->last_e1=e1; s->last_n1=n1;
    s->drew=c->drawing;                        /* PUBLISH last */
    draw_window_L3(c,&w);
    c->blit_guard_pd=0;                        /* GUARD OPEN: buffer and L3 hold one complete frame */
    s->has_frame=1;
    hbuddy_stage(0x40);                                /* hbuddy liveness: a frame was composed + committed */
    /* ARM the reveal re-fire for THIS fresh frame: it is a new view (we only compose on dirty), so the
     * photo is not up yet -> clear `revealed` and refill the retry budget. post_reveal + the poller
     * will post 0x67 until the 6_3_2 hook sets `revealed` (or the budget runs out). */
    s->revealed=0; s->reveal_tries=REVEAL_TRIES;
}

/* post_reveal: re-fire the reveal, the SAFE way -- POST native's own UI redraw message (UI_MSG_REDRAW =
 * 0x67) to THIS window's RC. Native's UI thread then runs a full drawOverlays(flags&0x10) paint ->
 * compositeLayers_6_3_2 -> our 6_3_2 hook -> reveal, all in native's OWN coherent context on its OWN
 * thread. The render/poller thread stays PD-FREE (the crash invariant): rc_for_pd is a registry SCAN
 * (no PD deref), rc+0x20 is the RC's message target, not the PD. Async post, ~1ms.
 *
 * RETRY not one-shot: gated on `!revealed && reveal_tries`. compose arms these for each fresh frame; the
 * 6_3_2 hook sets `revealed` when a post actually lands as a full paint, which STOPS the retry. A single
 * post at settle usually lands too early (native still finishing its pan paints -> absorbed into an
 * optimized paint, no reveal), so the poller re-drives this every ~150ms until it takes. reveal_tries
 * bounds a no-coverage view (0x67 never reveals there) to a fixed number of posts instead of forever. */
static void post_reveal(aerial_ctx_t* c,wslot_t* s){
    (void)c;
    if(s->revealed || !s->reveal_tries) return;                      /* shown, or budget spent -> done */
    u8* rc=rc_for_pd(s->pd);                                         /* registry scan -- NO PD deref */
    if(!rc) return;                                                  /* window gone -> stand down */
    POST_UI_MSG((void*)(rc+RC_MSG_TARGET), UI_MSG_REDRAW, 0);        /* async -> native reveals coherently */
    s->reveal_tries--;
}

/* check_trigger_6_3_2: for a window with a fresh committed frame at a SETTLED view (!dirty -- the view
 * did not move during the compose), drive a reveal post. The !dirty gate is what keeps us from posting
 * on every step of an ACTIVE pan (which would force a full repaint per frame): during a pan, dirty keeps
 * re-setting, so we post ONLY when settled. Called by BOTH the render thread (fast path, right after a
 * compose) and the poller (the ~150ms retry). Reads only our own slot state. */
static void check_trigger_6_3_2(aerial_ctx_t* c,wslot_t* s){
    if(s->used && s->has_frame && !s->dirty) post_reveal(c,s);
}

/* --- object alloc (card-independent; sets the one .bss word) --------- */
static aerial_ctx_t* ctx_alloc(void){
    if(CTX) return CTX;
    aerial_ctx_t* c=RM_MALLOC(sizeof(aerial_ctx_t)); if(!c) return 0;
    mzero(c,sizeof(aerial_ctx_t)); CTX=c; return c; }

/* --- THE FUSED CHARTSET: scan \RASTER for *.RCT, merge them all into ONE pyramid ---------
 * THE FILESYSTEM DEFINES THE SET. The workflow is "drop .RCT files on the card" -- a FILESYSTEM
 * act -- so the set of regions IS the set of files present, and any subset is a valid set.
 * There is nothing to keep in sync and nothing that needs keeping: every geographic bound a
 * side table could carry is derived from the files' own blocks anyway (cov_* in pass C).
 *
 * The files on a card are a SET, not independents. zoom_min and zoom_author are properties of
 * the set carried redundantly by each member -- which is precisely what lets the set be defined
 * by which files are present, and lets pass A CHECK their agreement rather than trust a
 * declaration. A file authored for a different set is detectable; a missing list entry is not.
 *
 * The big buffers (backbuf, cache px, blob) are owned by enable/disable, NOT here. */

static void free_chartset(aerial_ctx_t* c){
    if(c->zdir){ u32 nz=c->zmax-c->zmin+1;
        for(u32 zi=0;zi<nz;zi++){ zoomdir_t* zd=&c->zdir[zi];
            if(zd->blk){ for(u32 bi=0;bi<zd->nblk;bi++)
                    if(zd->blk[bi].bitmap) RM_FREE(zd->blk[bi].bitmap);
                RM_FREE(zd->blk); zd->blk=0; } }
        RM_FREE(c->zdir); c->zdir=0; }
    for(u32 i=0;i<c->nfiles;i++)
        if(c->fhs[i]){ FX_CLOSE(c->fhs[i]); RM_FREE(c->fhs[i]); c->fhs[i]=0; }
    c->nfiles=0; c->zmin=0; c->zmax=0; c->zauthor=0; c->zauthor_split=0;
    for(u32 i=0;i<CACHE_SLOTS;i++) c->cache[i].used=0;   /* invalidate, keep px buffers */
    c->active=0; }

/* Enumerate \RASTER and open every *.RCT into c->fhs[]. Uses the raw FileX directory API:
 *   fx_directory_search(media,"\\RASTER",dent,0,0)      -- ABSOLUTE path, so it touches NO
 *                                                          thread-local or media default path
 *   fx_directory_entry_read(media,dent,&idx,oent)       -- walks that directory's cluster chain
 * Both are stateless w.r.t. shared filesystem state, which is why this is safe to run from our
 * own thread while the rest of the system uses the filesystem. Entry layout: name at +0 (byte0
 * 0 = end of directory, 0xE5 = deleted slot), FAT attribute at +0x104 (0x10 = subdirectory). */
static int scan_rct_files(aerial_ctx_t* c){
    u8* dent=RM_MALLOC(FX_DIRENT_SZ); if(!dent) return 0;
    u8* oent=RM_MALLOC(FX_DIRENT_SZ); if(!oent){ RM_FREE(dent); return 0; }
    c->nfiles=0;
    if(FX_DIRSEARCH(FX_MEDIA(),"\\RASTER",dent,0,0)) goto done;
    for(int idx=0; c->nfiles<MAX_FILES && idx<FX_DIRENT_MAX; idx++){
        if(FX_DIRREAD(FX_MEDIA(),dent,&idx,oent)) break;
        if(oent[0]==0) break;                              /* end of directory */
        if(oent[0]==0xE5) continue;                        /* deleted slot */
        if(oent[0x104]&0x10) continue;                     /* subdirectory ('.', '..', ...) */
        /* accept only *.RCT (the name the reader upper-cases for us) */
        u32 n=0; while(n<64 && oent[n]) n++;
        if(n<5) continue;
        if(oent[n-4]!='.'||oent[n-3]!='R'||oent[n-2]!='C'||oent[n-1]!='T') continue;
        char path[80]; const char* pre="\\RASTER\\"; u32 j=0;
        while(pre[j]){ path[j]=pre[j]; j++; }
        for(u32 k=0;k<n;k++) path[j++]=(char)oent[k];
        path[j]=0;
        void* fh=RM_MALLOC(0x180); if(!fh) break;          /* FX_FILE control block */
        if(FX_OPEN(FX_MEDIA(),fh,path,0)){ RM_FREE(fh); continue; }
        c->fhs[c->nfiles++]=fh; }
done:
    RM_FREE(oent); RM_FREE(dent);
    return (int)c->nfiles; }

/* Read one file's 128-byte header -> its zmin/zmax/zauthor. 0 on failure.
 *
 * THE MAGIC IS CHECKED. scan_rct_files() selects on the ".RCT" filename ALONE, so without this
 * the zoom-range test below is a heuristic applied to whatever bytes the file happens to start
 * with -- a truncated copy, a rename, or anything else dropped in \RASTER passes it by accident
 * often enough to matter, and the blocks parsed from it are then garbage offsets we seek to.
 *
 * zoom_author (hdr+0x0a) is the level at which the producer quantized the coverage polygon.
 * 0 = NOT DECLARED (the byte was reserved-zero before the field existed), and the caller
 * substitutes MASK_Z -- that fallback is what keeps already-built cards working. */
static int rct_hdr_range(void* fh,u32* zmin,u32* zmax,u32* zauth){
    u32 got; u8 hdr[128];
    if(FX_SEEK(fh,0)) return 0;
    if(FX_READ(fh,hdr,128,&got)||got!=128) return 0;
    if(hdr[0]!='R'||hdr[1]!='C'||hdr[2]!='T'||hdr[3]!='1') return 0;   /* not one of ours */
    *zmin=hdr[0x0c]; *zmax=hdr[0x0d]; *zauth=hdr[0x0a];
    return (*zmax>=*zmin && *zmax<32) ? 1 : 0; }

/* Card-mount: build the ONE fused pyramid from every .RCT on the card.
 * Three passes over the (small) headers and zoom tables, because the merged per-zoom block
 * arrays have to be sized before they can be filled:
 *   A  union zmin..zmax across all files
 *   B  total block count per zoom level  -> allocate each level's array
 *   C  read the blocks + presence bitmaps, stamping each block with its owning file handle */
static int chartset_load(aerial_ctx_t* c){
    if(c->active) return 1;
    if(!scan_rct_files(c)) return 0;
    u32 got;
    /* --- pass A: the union zoom range + the SET's authored level --- */
    u32 lo=0xffffffff, hi=0, au=0, au_split=0;
    for(u32 f=0;f<c->nfiles;f++){ u32 a,b,v;
        if(!rct_hdr_range(c->fhs[f],&a,&b,&v)) continue;
        if(a<lo) lo=a; if(b>hi) hi=b;
        /* MIN over the declared ones; files that declare nothing abstain rather than force 0. */
        if(v){ if(!au) au=v; else if(v!=au){ au_split=1; if(v<au) au=v; } } }
    if(lo>hi) goto fail;
    c->zmin=lo; c->zmax=hi; c->zauthor=au; c->zauthor_split=au_split;
    u32 nz=hi-lo+1;
    c->zdir=RM_MALLOC(nz*sizeof(zoomdir_t)); if(!c->zdir) goto fail;
    mzero(c->zdir,nz*sizeof(zoomdir_t));
    for(u32 zi=0;zi<nz;zi++) c->zdir[zi].zoom=(u8)(lo+zi);
    /* --- pass B: per-zoom block counts across ALL files --- */
    for(u32 f=0;f<c->nfiles;f++){ u32 a,b,v;
        if(!rct_hdr_range(c->fhs[f],&a,&b,&v)) continue;
        for(u32 zi=0;zi<=b-a;zi++){ u32 ze[8];
            if(FX_SEEK(c->fhs[f],128+zi*32)) goto fail;
            if(FX_READ(c->fhs[f],ze,32,&got)||got!=32) goto fail;
            if(ze[0]<lo||ze[0]>hi) continue;
            c->zdir[ze[0]-lo].nblk+=ze[1]; } }
    for(u32 zi=0;zi<nz;zi++){ zoomdir_t* zd=&c->zdir[zi];
        if(!zd->nblk) continue;
        zd->blk=RM_MALLOC(zd->nblk*sizeof(block_t)); if(!zd->blk) goto fail;
        mzero(zd->blk,zd->nblk*sizeof(block_t));
        zd->nblk=0; }                                    /* refilled as a cursor in pass C */
    /* --- pass C: merge the blocks --- */
    s32 e0=0x7fffffff, e1=(s32)0x80000000, n0=0x7fffffff, n1=(s32)0x80000000;
    for(u32 f=0;f<c->nfiles;f++){ u32 a,b,v; void* fh=c->fhs[f];
        if(!rct_hdr_range(fh,&a,&b,&v)) continue;
        for(u32 zi=0;zi<=b-a;zi++){ u32 ze[8];
            if(FX_SEEK(fh,128+zi*32)) goto fail;
            if(FX_READ(fh,ze,32,&got)||got!=32) goto fail;
            if(ze[0]<lo||ze[0]>hi) continue;
            zoomdir_t* zd=&c->zdir[ze[0]-lo];
            for(u32 bi=0;bi<ze[1];bi++){ u32 be[12];
                if(FX_SEEK(fh,ze[2]+bi*48)) goto fail;
                if(FX_READ(fh,be,48,&got)||got!=48) goto fail;
                block_t* bl=&zd->blk[zd->nblk];
                bl->x_min=be[0]; bl->x_max=be[1]; bl->y_min=be[2]; bl->y_max=be[3];
                bl->grid_w=be[4]; bl->grid_h=be[5]; bl->index_off=be[6];
                bl->merc_e_w=(s32)be[8]; bl->merc_n_n=(s32)be[10];
                if(!bl->grid_w||!bl->grid_h) continue;    /* degenerate -> skip, keep the cursor */
                bl->step_e=((s32)be[9]-(s32)be[8])/(s32)bl->grid_w;
                bl->step_n=((s32)be[11]-(s32)be[10])/(s32)bl->grid_h;
                u32 bm=(bl->grid_w*bl->grid_h+7)>>3;
                bl->bitmap=RM_MALLOC(bm); if(!bl->bitmap) goto fail;
                if(FX_SEEK(fh,be[7])) goto fail;
                if(FX_READ(fh,bl->bitmap,bm,&got)||got!=bm) goto fail;
                bl->fh=fh;                               /* THE FUSION KEY */
                zd->nblk++;
                s32 bee=bl->merc_e_w+(s32)bl->grid_w*bl->step_e;
                s32 bns=bl->merc_n_n+(s32)bl->grid_h*bl->step_n;
                s32 lo_e=imin(bl->merc_e_w,bee), hi_e=imax(bl->merc_e_w,bee);
                s32 lo_n=imin(bl->merc_n_n,bns), hi_n=imax(bl->merc_n_n,bns);
                if(lo_e<e0)e0=lo_e; if(hi_e>e1)e1=hi_e;
                if(lo_n<n0)n0=lo_n; if(hi_n>n1)n1=hi_n; } } }
    c->cov_e0=e0; c->cov_e1=e1; c->cov_n0=n0; c->cov_n1=n1;
    c->unreveal_pending=0;      /* going live: drop any un-reveal the last teardown left armed,
                                 * so it can never fire against the filter we are about to apply */
    /* hbuddy liveness: stamp the fused chartset {zmin,zmax,nfiles} into HBUDDY.COE's ring on every
     * activation (no-op when HBUDDY.COE is absent). This is the one deliberate ring write the release
     * build keeps -- it exercises the inter-COE log path and reads back as "aerial fused this card". */
    { u32 w[5]={c->zmin, c->zmax, c->nfiles, c->zauthor, c->zauthor_split};
      hbuddy_log(0x0AE1u, w, 5); }
    c->active=1; return 1;
fail:
    free_chartset(c); return 0; }
/* Tear the chartset down under the mask lock: the paint thread reads zdir/blocks/bitmaps inside
 * build_mask and this frees them. If the bounded spin fails we free ANYWAY -- the card is gone and
 * refusing to tear down is worse -- and we do NOT drop a lock we never took. That leaves a
 * microscopic residual window rather than an airtight one; stated plainly rather than papered over. */
static void chartset_teardown(aerial_ctx_t* c){
    int got=mask_lock_take(c);
    free_chartset(c);
    if(got) mask_lock_drop(c); }

/* Read the chart-window screen rect from the live L3 bitmap descriptor (desc+8 =
 * {l,t,r,b}, databar/frames excluded). this-independent so both the render thread
 * and the paint hook use it. Falls back to the E80 full-page chart window if insane. */
/* ====================================================================
 * The hook handler + feature control.
 * ==================================================================== */

/* PAINT-PASS APPEND, for the window whose PD the detour was entered on. Presents THAT
 * window's already-composed backbuffer rect; returns 1 if we painted. Fast by contract --
 * a window blit, no decode, no card I/O -- because this runs in the paint path, where the
 * recorded landmine says heavy CF/VRAM work watchdog-resets the unit.
 *
 * aerial_suppress_native_L3 has already paired pd -> slot and done the dirty/signal work; this only
 * paints. Splitting "decide" from "paint" is deliberate: the key-5 fast path INVERTS the
 * decision (fill native's key-5 and let ITS blit run, rather than suppress and present), so
 * the two must stay separately gated or that future is a rewrite instead of a policy change. */
int aerial_draw_L3(u32 self){
    aerial_ctx_t* c=CTX;
    if(!c) return 0;
    if(!c->enabled||!c->active) return 0;
    u8* rc; wslot_t* s=slot_for_pd(c,self,&rc);
    if(!s||!s->drew) return 0;                    /* this window has no finished frame -> native's */
    if(c->blit_guard_pd==self){                   /* THE GUARD: the render thread is rewriting THIS
                                                   * window's backbuffer rect right now, so presenting
                                                   * it would blit a half-built frame. Decline: L3 still
                                                   * holds the last COMPLETE frame and has_frame keeps
                                                   * native's key-5 blit suppressed, so the glass simply
                                                   * keeps the previous photo for this pass. */
        return 0; }
    window_t w;
    if(!pd_rect(self,&w)) return 0;               /* THIS window's rect, off its own PD */
    draw_window_L3(c,&w);
    return 1;
}

/* ---- shared research-hook helpers -------------------------------------------------------------
 * layer_px: resolve an 8bpp layer's CPU VRAM base + dims + row pitch for a window's PD. Surface
 * descriptor: +0x02 w | +0x04 h | +0x0c base; 8bpp pitch = w rounded up to 8. Returns 0 on any
 * missing hop (page change / not up yet). */
static u8* layer_px(u32 self, u32 key, u32* w_out, u32* h_out, u32* pitch_out){
    u32 k=key;
    u32 node=LAYER_LOOKUP(self+0x60,&k); if(!node) return 0;
    u32 layer=*(u32*)(node+4); if(!layer) return 0;
    u32 surf=LAYER_SURF(layer,1); if(!surf) return 0;
    u8* px=(u8*)(*(u32*)(surf+0x0c)); if(!px) return 0;
    u32 w=*(u16*)(surf+0x02), h=*(u16*)(surf+0x04);
    if(w_out)*w_out=w; if(h_out)*h_out=h; if(pitch_out)*pitch_out=(w+7u)&~7u;
    return px;
}
/* REVEAL: remap key3's OPAQUE-FILL band 0x21-0x2f -> its BLEND TWIN 0x01-0x0f (v-0x20) over the
 * whole buffer. Stock CLUT makes 0x01-0x0f blend, so chart FILLS reveal L3 while symbology (indices
 * outside the fill band) stays opaque. Idempotent. 6_3_2-pre does it pre-blit (no key3->key6 DMA
 * race). */
static void reveal_key3(u32 self){
    u32 w,h,pitch; u8* px=layer_px(self,3,&w,&h,&pitch); if(!px) return;
    for(u32 y=0;y<h;y++){ u8* r=px+y*pitch;
        for(u32 x=0;x<w;x++){ u8 v=r[x]; if((u8)(v-0x21) < 0x0fu) r[x]=(u8)(v-0x20); } }
}
/* The exact INVERSE: blend twins 0x01-0x0f -> opaque fills 0x21-0x2f.
 *
 * WHY THIS EXISTS: nothing in the native chain restores key3's opaque fills. Proven on the
 * bench -- after a teardown, key3 was still ENTIRELY our blend twins (0x02/0x03/0x0b/0x0e at
 * every row sampled), so the photo kept showing through a torn-down aerial. Posting native's own
 * UI-redraw message 0x67 changed nothing (it is a "render complete, present it" notification,
 * not a redraw command), and MARK_AERIAL_DIRTY produces a real redraw but faithfully propagates
 * whatever key3 already holds. So the restore has to be ours.
 *
 * WHERE IT MAY RUN: only from the 6_3_2 PRE hook, before the key3->key6 blit -- the single point
 * at which key3 is ours to touch. Never from the render or poller thread: an out-of-band write
 * races the compositor, which is the same class of defect as the top-band itself.
 *
 * Idempotent -- a second pass sees 0x21-0x2f and matches nothing. Safe because 0x01-0x0f is
 * exclusively ours on a raster card: stock content reads 0x21-0x2f and the blend bank only ever
 * appears after we remap it. */
static void unreveal_key3(u32 self){
    u32 w,h,pitch; u8* px=layer_px(self,3,&w,&h,&pitch); if(!px) return;
    for(u32 y=0;y<h;y++){ u8* r=px+y*pitch;
        for(u32 x=0;x<w;x++){ u8 v=r[x]; if((u8)(v-0x01) < 0x0fu) r[x]=(u8)(v+0x20); } }
}
/* THE MASKED REVEAL. Walks ONLY the mask rects: the loop bounds ARE the mask, so there is no
 * per-pixel position test anywhere -- the only per-pixel work left is the irreducible value test,
 * and the cost tracks REVEALED AREA rather than plane area. mask_full (too fragmented to describe
 * in MASK_MAX_RECTS) falls back to reveal_key3, i.e. exactly the pre-Phase-2 behaviour, so the
 * degenerate case can never be worse than what shipped. */
static void reveal_masked(u32 self,wslot_t* s){
    if(s->mask_full){ reveal_key3(self); return; }
    u32 w,h,pitch; u8* px=layer_px(self,3,&w,&h,&pitch); if(!px) return;
    for(u32 i=0;i<s->nmrects;i++){ mrect_t* q=&s->mrects[i];
        for(s32 y=q->y0;y<=q->y1;y++){ if(y<0||(u32)y>=(s32)h) continue;
            u8* r=px+(u32)y*pitch;
            for(s32 x=q->x0;x<=q->x1;x++){ if(x<0||(u32)x>=(s32)w) continue;
                u8 v=r[x]; if((u8)(v-0x21)<0x0fu) r[x]=(u8)(v-0x20); } } } }
/* --- Fujitsu Coral-PA graphics engine (MB86296S) ---------------------------------------------
 * Chip base 0xd6000000 (== our VRAM aperture). Fixed sub-apertures per the Specification Manual
 * Table 3-4, LIVE-VERIFIED by deriving DisplayBase from our own known CRTC/CLUT addresses:
 *   +0x01FC0000 host iface  +0x01FD0000 DISPLAY (0xd7fd0000: CRTC, CLUT at +0x1000)
 *   +0x01FD8000 capture     +0x01FE0000 texture
 *   +0x01FF0000 DRAW (0xd7ff0000)       +0x01FF8000 geometry (0xd7ff8000)
 * CTR = DrawBase + 0x400. Read-only status, confirmed live reading 0x000e9000 at idle -- every
 * field matching the manual's documented initial value (FCNT=0b011101, FE=1, PS/DS/SS=0). */
#define FENCE_DEFAULT 100000u   /* baked cap. Measured need ~25k polls; 4x headroom. If fence_waits
                                 * ever EQUALS this the fence timed out and the band can return. */
#define CTR_ENGINES 0x00000333u   /* PS bits1:0 | DS bits5:4 | SS bits9:8 -- any set = busy */
#define CTR_FE      0x00001000u   /* display list FIFO empty (1 = drained)                  */
#define CORAL_IDLE(v) ((((v) & CTR_ENGINES) == 0) && ((v) & CTR_FE))
/* Wait for the engine to go idle, bounded. Returns iterations consumed; stashes what it FOUND. */
static u32 coral_fence(aerial_ctx_t* c,u32 max){
    u32 v=CORAL_CTR; c->fence_ctr_in=v;
    u32 n=0;
    while(n<max && !CORAL_IDLE(v)){ n++; v=CORAL_CTR; }
    c->fence_waits=n;
    return n; }


/* 6_3_2 reveal hook -- called PRE-blit (phase always 0): pan-follow wake + REVEAL (the key3 fills
 * remap). Returns 0 (the reveal never suppresses native). */
int compositeLayers_6_3_2_hook(u32 self, u32 phase, u32 flags, u32 update_rect){
    aerial_ctx_t* c=CTX; if(!c) return 0;
    (void)phase;                                       /* detour passes 0; the POST/trace phase is retired */
    if(!c->enabled) return 0;
    /* Pair FIRST, for the same reason as the kind5 hook: the slot registry has to know which chart
     * windows EXIST even while we are stood down, or a later activation has nothing to mark dirty
     * (that was the boot-with-AO-off -> AO-on dead window). */
    u8* rc; wslot_t* s=slot_for_pd(c,self,&rc);
    if(!s) return 0;                                   /* aerial window only -- never a plain chart */
    /* TORN DOWN (card-out / AO-off): key3 still holds OUR blend twins and nothing native will
     * restore them, so the photo would keep showing through. Undo it HERE -- this hook, pre-blit,
     * is the one place key3 is ours. Bounded by unreveal_pending, which chartset_load zeroes on
     * every activation; and because this branch sits under !c->active it can never fire against a
     * live filter, however stale the counter might get. */
    if(!c->active){
        if(c->unreveal_pending && !(flags & 0x10)){        /* fills branch only, same gate as reveal */
            unreveal_key3(self);
            s->revealed=0;                                 /* key3 no longer carries our remap */
            c->unreveal_pending--; }
        return 0; }
    /* PAN-FOLLOW: 6_3_2 fires on a view change (both branches), but on the optimized-pan path native
     * does NOT serve the aerial on its own -- so the reveal is lost at pan-settle. On any view change we
     * wake the render thread; it recomposes and, once SETTLED, posts native's own UI redraw message
     * (post_reveal -> POST_UI_MSG 0x67) so native re-runs THIS hook on its own thread and the reveal
     * re-applies. The render thread never touches a PD to do this -- a markAerialDirty/serve re-apply
     * from the render thread crashes the unit. */
    if(slot_changed(s,rc)){ s->dirty=1; if(c->ev_ok) RL_EVSET(c->evgrp); }
    if(flags & 0x10) return 0;                         /* only the fills branch blits key3 */
    /* Nothing composed for this window yet -> DON'T open the aperture. The chart stays opaque
     * until there is a frame behind it, so the user never sees native's key-5 (yellow) nor an
     * uninitialised L3 (black/garbage) through our own hole. */
    if(!s->has_frame) return 0;
    /* BBOX REJECT. No coverage under this view -> reveal nothing, so the chart stays opaque
     * instead of showing our empty backbuffer (the green fill, or native's key-5 yellow once
     * drew==0 lets its blit through). On the covered->uncovered EDGE we must actively UNDO the
     * last remap: key3 persists, so ceasing to reveal is not the same as un-revealing -- the
     * same lesson the AO-off case taught. Cheap: one rect test per composite. */
    if(!view_has_coverage(c,rc)){
        if(s->revealed){ unreveal_key3(self); s->revealed=0; }
        return 0; }
    /* THE FENCE. The chart render into key3 is still in flight here; remapping without waiting
     * loses the leading rows to it and 6_3_2 publishes that loss into key6. Baked on; poke
     * fence_max to 0 to reproduce the defect. */
    build_mask(c,s,self,rc);                           /* cached: rebuilds only on a view/card change */
    if(c->fence_max) coral_fence(c,c->fence_max);
    reveal_masked(self,s);
    s->revealed=1;                                     /* key3 now carries our remap for this window */
    hbuddy_stage(0x80);                                /* hbuddy liveness: reveal ran (key3 remap applied) */
    return 0;
}

/* AO (Aerial Overlay softkey) on/off, read live from the IAppPDControlPhotoOverlay object:
 * registry 0x044c66e0 -> [+4] = controller[0] (= RC_REG[0]) -> [+0xa0] = the object -> byte
 * +0x511 (1 = on, mirror of +0xb06). Null-checks every hop; returns 1 = on, 0 = off, -1 =
 * unknown (chain not up yet). Poll-cheap (all reads). The address CHURNS per boot/window so it
 * is resolved through the chain every call, never cached. */
static int ao_state(void){
    u8* ctrl = RC_REG[0];                     /* registry+4 = controller[0] (heap; churns) */
    if(!ctrl) return -1;
    u8* obj  = *(u8**)(ctrl + 0xa0);          /* the IAppPDControlPhotoOverlay singleton */
    if(!obj) return -1;
    return obj[0x511] ? 1 : 0;                /* AERIAL OVERLAY on/off */
}

/* Card/AO poller: a card pull or an AO-off fires NO repaint, so nothing would wake the
 * event-driven renderer to tear the photo down. This tiny thread polls presence + AO every
 * ~150 ms and, on a change, signals the render group so the renderer reconciles at once. It
 * does no heavy work and touches no compose state -- purely a notifier. */
void card_poll_thread(void){
    u32 last_card=0xffffffff; int last_ao=-2;                   /* != any real value -> first pass signals */
    for(;;){
        RM_THREADSLEEP(150);
        aerial_ctx_t* c=CTX; if(!c || !c->ev_ok) continue;
        u32 card = FS_READY() ? 1u : 0u; int ao = ao_state();   /* `card` now == FS-READY (MEDI), not +0xa0 */
        int sig = (card!=last_card || ao!=last_ao);             /* EDGE: an input changed */
        /* LEVEL re-check: the inputs say we should be UP but we are not -> wake the render thread to
         * (re)load. NO backoff count: the gate is now MEDI (fx_media_id), which fx_media_open sets
         * only AFTER the boot-sector parse + FAT reads, so FS_READY() true GUARANTEES chartset_load
         * succeeds -- there is no "true a beat before the FAT" race to retry through (verified from
         * the firmware). So this fires once, active clears, and it stops -- not a spin. It still
         * covers the self-latching-stall case (active=0 with nothing to wake us) that the old retry
         * also guarded. */
        if(c->enabled && card && ao!=0 && !c->active) sig=1;
        /* STUCK-DIRTY SWEEP. The render loop clears win[].dirty BEFORE composing, so a compose
         * that bails leaves the window dirty with its bounds uncommitted -- and then the loop goes
         * straight back to blocking on the wake group. If the view happened to stop moving at that
         * instant, NOTHING is left to wake us: the paint hooks only signal when they fire, and a
         * static chart stops compositing. That is the native machinery going quiet on us, not our
         * thread failing, and it is the same shape as the card-mount wake wart.
         * It matters more now than it used to: before has_frame that stall showed as yellow, which
         * self-corrected on the next nudge; now it would show as a SILENTLY frozen photo. Re-drive
         * any still-dirty window so a stale frame can only ever last about one poller tick. */
        if(!sig && c->active)
            for(u32 i=0;i<RC_SLOTS;i++)
                if(c->win[i].used && c->win[i].dirty){ sig=1; break; }
        /* REVEAL RETRY. The render thread posts 0x67 the instant a compose settles, but that first post
         * often lands too early -- native is still finishing its own optimized-pan paints, so it gets
         * absorbed into an optimized (not full) paint and the reveal never runs. Re-drive it here every
         * ~150ms: check_trigger_6_3_2 re-posts 0x67 for any settled fresh-frame window until the 6_3_2
         * hook confirms the reveal (revealed=1 -> no-op) or the per-frame retry budget runs out. Same
         * PD-free path as the render thread; posting is idempotent, so a redundant post is harmless. */
        /* STARTUP KICK: on a mid-run COE load the chart is static, so no paint ever fired the
         * kind5 hook -> no win[] slot is `used` -> the per-slot kick below has nothing to drive.
         * Bootstrap it: post 0x67 to every LIVE chart RC (firmware RC_REG, not our slots) so native
         * repaints -> kind5 fires -> a slot is claimed -> snapshot -> compose -> reveal. Self-
         * terminating (skipped once any window composes). PD-free: RC_REG scan + async post only. */
        if(c->active){
            int any_used=0;
            for(u32 i=0;i<RC_SLOTS;i++) if(c->win[i].used){ any_used=1; break; }
            if(!any_used)
                for(u32 i=0;i<RC_SLOTS;i++){ u8* rc=RC_REG[i]; if(rc) POST_UI_MSG((void*)(rc+RC_MSG_TARGET),UI_MSG_REDRAW,0); }
        }
        if(c->active)
            for(u32 i=0;i<RC_SLOTS;i++){
                wslot_t* s=&c->win[i];
                if(!s->used) continue;
                if(!s->has_frame){
                    /* PAIRED BUT NEVER COMPOSED. A window can be claimed (used=1) with NO valid
                     * snapshot: on a page change with a STATIC view (e.g. single->dual, boat stopped)
                     * a hook pairs+dirties the window before its geometry is ready, so the kind5
                     * snapshot captures nothing (snap_*=0) and compose_win bails -> has_frame stays 0,
                     * dirty gets cleared. Then nothing re-paints it (no motion), so the kind5 hook
                     * never re-fires to capture the snapshot -- it is stuck. Neither the stuck-dirty
                     * sweep (needs dirty) nor the reveal-retry (needs has_frame) covers this.
                     * KICK a native repaint (0x67) so the kind5 hook re-fires with geometry now up,
                     * captures the snapshot, sets dirty, and the render thread composes -> has_frame ->
                     * the reveal-retry below takes over. Self-terminating (stops once has_frame set);
                     * rc gone -> skip, the render thread reaps the slot. */
                    u8* rc=rc_for_pd(s->pd);
                    if(rc) POST_UI_MSG((void*)(rc+RC_MSG_TARGET), UI_MSG_REDRAW, 0);
                } else check_trigger_6_3_2(c,s);   /* framed -> reveal-retry (post until revealed) */
            }
        last_card=card; last_ao=ao;
        if(sig) RL_EVSET(c->evgrp);
    }
}

/* Background render thread: BLOCKS on the wake group (event-driven), so a view-change
 * recomposes and repaints IMMEDIATELY -- what keeps the aerial clean through a scroll/zoom.
 * (A pure poll let native's empty-key-5 yellow show for a tick after the view settled, before
 * we repainted.) It wakes on two signals: the paint hook, on a view-change (RL_EVSET in
 * note_kind5); and the card/AO poller, on a card or AO change (neither fires a repaint). On
 * each wake it reconciles -- booted -> big buffers (lazy, ONCE, off the paint path); card &&
 * AO-on -> region active; card-out or AO-off -> tear down (hides L3 at the next scan-out);
 * dirty window -> compose. Lowest ThreadX priority, so the UI always preempts our compose. */
void render_thread(void){
    for(;;){
        aerial_ctx_t* c=CTX;
        if(!c || !c->ev_ok){ RM_THREADSLEEP(150); continue; }        /* group not up -> slow park */
        if(RL_EVWAIT(c->evgrp)!=0){ RM_THREADSLEEP(150); continue; } /* block until a signal; 0x308=deleted */
        c=CTX; if(!c || !c->enabled) continue;
        if(!c->backbuf){                                       /* lazy big-buffer alloc, ONCE */
            c->scr_w=SCR_W(); c->scr_h=SCR_H();
            c->backbuf=RM_MALLOC(c->scr_w*c->scr_h*2);
            c->blob=RM_MALLOC(0x40000);
            for(u32 i=0;i<CACHE_SLOTS;i++) if(!c->cache[i].px) c->cache[i].px=RM_MALLOC(TILE_555);
            if(!c->backbuf||!c->blob){ c->enabled=0; continue; }        /* alloc fail -> stand down */
            for(u32 i=0;i<CACHE_SLOTS;i++) if(!c->cache[i].px){ c->enabled=0; break; }
            if(!c->enabled) continue;
        }
        int want = FS_READY() && (ao_state()!=0);              /* MEDI ready = up; AO off(0) stands down; unknown(-1)=on.
                                                                * Teardown keys on MEDI-clear: a dialog close clears it
                                                                * promptly; a physical yank clears it when the ~200ms
                                                                * monitor closes the media (this test proves +0xa0 out). */
        if(!want){
            /* Card-out or AO-off. Tear the set down AND DRIVE A REPAINT. Changing state alone
             * changes NOTHING on the glass: key3 still holds our last reveal remap and L3 still
             * holds the last composed frame, and neither is undone until something repaints. That
             * is why AO-off used to leave the photo up until the user happened to zoom, and why
             * card-removal only took effect once the modal dialog was dismissed. */
            if(c->active){
                chartset_teardown(c);
                /* Ask the 6_3_2 hook to restore key3's opaque fills. A repaint ALONE is not
                 * enough -- MARK_AERIAL_DIRTY drives a real redraw but propagates whatever key3
                 * holds, which is still our blend twins (bench-proven). Arm the un-reveal FIRST,
                 * then drive the redraw, so the hook has something to undo when it fires. */
                c->unreveal_pending=8;                         /* a few composites' worth */
                for(u32 i=0;i<RC_SLOTS;i++){ wslot_t* s=&c->win[i];
                    if(!s->used) continue;
                    s->drew=0; s->dirty=0; s->has_frame=0;     /* nothing of ours is valid now --
                                                                * closes the aperture AND releases
                                                                * L3 back to native */
                    if(rc_for_pd(s->pd)) MARK_AERIAL_DIRTY(s->pd); } }
            continue; }
        if(!c->active||FS_READY()!=c->card_gen){               /* (re)activate per card (card_gen tracks MEDI, 0/1) */
            if(c->active) chartset_teardown(c);
            c->card_gen=FS_READY();
            chartset_load(c);                                  /* fuse EVERY .RCT on the card */
            for(u32 i=0;i<RC_SLOTS;i++) c->win[i].dirty=1;     /* new card -> everything restales */
        }
        if(!c->active) continue;
        for(u32 i=0;i<RC_SLOTS;i++){                            /* compose ONLY what is dirty */
            wslot_t* s=&c->win[i];
            if(!s->used || !s->dirty) continue;
            if(!rc_for_pd(s->pd)){ s->used=0; continue; }       /* window died (page change) -- registry
                                                                * read only, no PD deref; reap the slot */
            s->dirty=0;                                        /* clear BEFORE composing: a move
                                                                * during the pass re-dirties us */
            compose_win(c,s);                                  /* composes from the snapshot; the render
                                                                * thread never dereferences the PD */
            /* SETTLE -> re-fire the reveal. This REPLACES the old render-thread MARK_AERIAL_DIRTY(s->pd)
             * (the crash): it POSTS native's own UI redraw message (0x67) to the RC -- async, PD-free --
             * so native repaints on its own thread and our 6_3_2 hook re-applies the reveal. Closes the
             * optimized-scroll-settle gap AND the initial-appearance gap (the post fires after the first
             * compose, so the photo shows without a user pan). */
            check_trigger_6_3_2(c,s);
        }
    }
}

/* compositeKey5_to_L3_detour / _trampoline / _splice are in the self-installed detours section above
 * (same COE, #ifdef COE_BUILD). That detour calls x_aerial_suppress_native_L3 (kind5 PRE) and
 * x_aerial_draw_L3 (kind5 POST) THROUGH the export table; the two functions below are the brain side
 * of that handshake.
 *
 * Capture + gate for the single hook.
 *
 * THE SITE: ChartingAppPD_drawLayerByKind @0x006d9a18 (vtable entry #4) walks the map at
 * this+0x64 and dispatches kind 0x100 -> compositeKey5_to_L3, the aerial's key-5 -> L3 blit.
 * That blit is the yellow: on an NV2/RASTER card key-5 holds nothing but its no-data background
 * colour (0x7f2b), because the Navionics engine only fills key-5 from Platinum aerial data. So
 * native copies a colour meaning "I have nothing" over our photo, and suppressing it discards
 * nothing native had. RASTER and Platinum cards are mutually exclusive, so `active && drew` is
 * exactly the condition under which that holds -- with a Platinum card `active` is 0 and
 * native's blit runs untouched.
 *
 * Returns 1 to SKIP the native blit. */
int aerial_suppress_native_L3(u32 self){
    aerial_ctx_t* c=CTX; if(!c) return 0;
    if(!c->enabled) return 0;
    /* PAIR THE WINDOW EVEN WHILE STOOD DOWN. The slot registry must reflect which chart windows
     * EXIST, independently of whether we are currently drawing into them. Both hooks used to
     * return on !active BEFORE pairing, so booting with AO off left every win[] slot unclaimed
     * -- and when AO was later switched on, activation set win[i].dirty=1 on slots whose
     * used==0, the compose loop skipped them all, and no photo appeared until a zoom happened
     * to fire a hook that finally claimed one. Pairing is cheap (an O(4) re-pair against the
     * live registry) and carries no side effect while inactive. */
    /* THE PRODUCER. This hook fires once per repaint OF THIS WINDOW (measured:
     * 18 entries on the left PD for a left scroll, 9 on the right PD for a right scroll)
     * -- so it IS the per-window dirty signal, and a
     * card-independent one. Native's own wake (PhotoOverlayRC ctrl+0xf28) would also work,
     * but is native's to consume; ours costs a compare. */
    u8* rc; wslot_t* s=slot_for_pd(c,self,&rc);
    if(!s) return 0;                                  /* not a live chart window -> native's paint */
    if(!c->active) return 0;                          /* stood down: window is paired, native blits */
    k5_probe(s,self);                                 /* key-5 surface (once/window); coherent self here */
    /* SNAPSHOT + WAKE. On a view change, capture THIS window's rect + geo bounds off the coherent PD
     * into the slot, THEN mark dirty + wake -- so a dirty slot always has a fresh snapshot behind it
     * and the render thread never has to touch the PD. Gate the wake on a successful capture. */
    if(slot_changed(s,rc)){
        window_t w; s32* bn=rc_bounds(rc);
        if(bn && pd_rect(self,&w)){
            s->snap_sx=w.sx; s->snap_sy=w.sy; s->snap_sw=w.sw; s->snap_sh=w.sh;
            s->snap_e0=bn[0]; s->snap_n0=bn[1]; s->snap_e1=bn[2]; s->snap_n1=bn[3];
            s->dirty=1; if(c->ev_ok) RL_EVSET(c->evgrp);
        }
    }
    /* The reveal re-fire is NOT in this hook. LANDMINE: a synchronous renderOverlayToSurface from here
     * corrupts the ctx -- it lives on the render thread instead as an async POST_UI_MSG(0x67) after a
     * settled compose (post_reveal), so native repaints on its own thread and re-enters THIS hook
     * coherently to do the reveal. This hook does only snapshot + wake + suppress. */
    /* PER-WINDOW gate, on EVER-COMPOSED rather than on the last compose succeeding.
     * `s->drew` meant "did the LAST compose commit" -- so an interrupted compose handed L3 back to
     * native, which painted its empty key-5 over a frame that was still perfectly good. That is
     * the yellow flash: not a failure to produce imagery, but giving away imagery we already had.
     * has_frame keeps the original protection (a window we never composed still stands down, so we
     * never suppress into an empty L3) while never surrendering a frame once we own one. */
    return s->has_frame ? 1 : 0; }

/* Turn the feature on: allocate the fixed big buffers ONCE (kept for the session),
 * derive screen size, arm the flag. Fail-safe: if the buffers don't fit, stay off
 * and let native run. The first paint happens on the next native aerial event. */
/* Turn the feature on (LIGHT -- paint-path safe, so coe_init can call it during self-boot).
 * Creates the wake group and spawns the two background threads ONCE: the render thread
 * (event-driven; does the heavy lazy alloc + reconcile + compose) and the card/AO poller
 * (wakes the renderer on a card/AO change). Host-callable too (x_aerial_coe_start) for A/B toggling. */
void aerial_coe_start(void){
    aerial_ctx_t* c=ctx_alloc(); if(!c) return;
    for(u32 i=0;i<RC_SLOTS;i++) c->win[i].used=0;                  /* windows re-pair on first paint */
    if(!c->ev_ok){                                                 /* the wake group, once (auto-reset) */
        if(RL_EVCREATE(c->evgrp,THREAD_NAME,0x211)==0) c->ev_ok=1; }
    c->enabled=1;                                                 /* arm; the threads alloc + reconcile */
    if(!c->thread_started){                                        /* spawn both background threads once */
        c->thread_started=1;
        /* prio arg 0 -> ThreadX priority 31 (LOWEST): the UI preempts our compose so we never
         * block it. Native's renderThread is prio arg 3 -> TX 10; we do NOT ride it. */
        c->thread_tcb=RM_MALLOC(0x104);
        RM_THREADCREATE(render_thread,0,0x4000,0,c->thread_tcb,THREAD_NAME,0x210);
        c->poller_tcb=(u32)RM_MALLOC(0x104);                      /* card/AO poller tcb (dedicated field) */
        RM_THREADCREATE(card_poll_thread,0,0x1000,0,(void*)c->poller_tcb,THREAD_NAME,0x212); }
    if(c->ev_ok) RL_EVSET(c->evgrp); }                            /* kick: reconcile now */

/* Turn the feature off: native aerial resumes on the next paint. Buffers KEPT
 * (anti-fragmentation); a card teardown drops only card-specific state. */
void aerial_deactivate_region(void){ aerial_ctx_t* c=CTX; if(!c) return;
    c->enabled=0; if(c->active) chartset_teardown(c); }

/* ---- THE COE ENTRY (packer default symbol; the header's entry_off points here) --------
 * Called once by coe_common's coe_entry, right after the mod4a loader (coe_load) relocates the
 * overlay into heap. Allocates the ctx, PUBLISHES the export table (each &fn is an R_ARM_ABS32 the
 * loader has already rebased to its heap address), BAKES the self-start default flags, and publishes
 * CTX. SELF-START: it writes COMPOSITE_FLAGS = CF_DEFAULT (0x10000001 = GREEN|HOOK_6_3_2) and spawns
 * the render + poller threads BEFORE arming, so the first region setup comes up with the reveal armed
 * -- no host poke, no bounce. (The COE composes as soon as it is loaded and signaled; the firmware
 * LL is responsible for only loading it once the system is painting, so the compose is safe.) Returns
 * (int)CTX so the loader can hand the host a live anchor. */
int coe_init(void){                                     /* the COE entry: the LL applies the edits, then calls this */
    aerial_ctx_t* c=ctx_alloc(); if(!c) return 0;
    COE_SET_STATE(AERIAL_SLOT, COE_INITED);             /* 1 (LOADED, set by the LL) -> 2 (starting) */
    c->abi.x_aerial_suppress_native_L3   = (u32)(void*)&aerial_suppress_native_L3;
    c->abi.x_aerial_draw_L3              = (u32)(void*)&aerial_draw_L3;
    c->abi.x_aerial_coe_start            = (u32)(void*)&aerial_coe_start;
    c->abi.x_aerial_deactivate_region    = (u32)(void*)&aerial_deactivate_region;
    c->abi.x_compositeLayers_6_3_2_hook  = (u32)(void*)&compositeLayers_6_3_2_hook;
    /* Published INTERIOR POINTERS -- the host reads these instead of hardcoding ctx offsets. */
    c->abi.x_knobs                       = (u32)(void*)&c->fence_max;   /* fence + mask_z knob block */
    c->abi.x_win_slots                   = (u32)(void*)&c->win[0];
    /* abi_version LAST of the contract fields: a host that sees a nonzero version knows the rest
     * of the table is already populated, so there is no partially-published window to read. */
    c->abi.abi_version                   = AERIAL_ABI;
    hbuddy_stage(0x08);                                /* hbuddy liveness: coe_init done, CTX published */
    c->fence_max = FENCE_DEFAULT;                        /* the Coral fence is FEATURE, not a knob */
    c->mask_z   = MASK_Z;                                /* reveal-contour level; poke to sweep it */
    COMPOSITE_FLAGS = CF_DEFAULT;                        /* SELF-START: arm the proven reveal at boot */
    aerial_coe_start();                                  /* auto-arm + spawn the render thread
                                                          * (light; heavy alloc is lazy in the thread)
                                                          * -> functional from boot, no host call */
    COE_SET_STATE(AERIAL_SLOT, COE_RUNNING);             /* 2 (starting) -> 3 (RUNNING): guarded callers may fire */
    return (int)(u32)c;
}
#endif /* COE_BUILD -- end the aerial brain */
