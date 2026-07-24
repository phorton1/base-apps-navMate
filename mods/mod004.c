/* ====================================================================
 * mod004.c -- E80/E120 custom raster-aerial overlay.
 * AUTHORING SOURCE ONLY (see mods/e80_mod004.txt + mods/AERIAL.COV).
 *
 * *** ONE .c, COMPILED TWICE (the COV split) ***
 * This single file is the whole mod. Compiled WITHOUT -DCOV_BUILD it is the
 * FIRMWARE half (flashed): the linking loader `cov_load`, the diag-callable
 * bootstrap `aerial_cov_boot`, the `compositeKey5_to_L3_splice`/`compositeKey5_to_L3_detour`/`compositeKey5_to_L3_trampoline`
 * hook, and the `\AERIAL.COV` path string. Compiled WITH -DCOV_BUILD it is the
 * CODE OVERLAY (card file AERIAL.COV): `aerial_cov_init` + the entire aerial brain.
 *
 * The two halves share ONE `aerial_ctx_t` (below) whose tail is the EXPORT TABLE = the
 * ABI. aerial_cov_init (COV) fills the table with the overlay's own function addresses
 * (relocated into heap by the loader); the firmware detour calls
 * `x_note_kind5`/`x_overlay_hook` THROUGH it (`ldr r12,[c,#EXP_*]; bx r12`), and
 * the host calls `x_aerial_cov_start`/`x_aerial_deactivate_region` by peeking CTX then the slot. Because one
 * file holds both halves, `_Static_assert(offsetof(...)==EXP_*)` makes the
 * detour's literal offsets un-driftable. The firmware never bl's into the brain;
 * `if(!CTX) native-only` is the stay-stock path.
 *
 * The mechanism prose below (the L3 painter, the single splice site, the fix) is
 * unchanged from /14 -- only the PACKAGING changed: the brain left NOR for
 * the card, handing ~6KB of reclaimed codespace back.
 *
 * MODEL: event-driven, tail-append, ** ONE FIRMWARE SITE **. We splice
 * ChartingAppPD_compositeKey5_to_L3 @0x006da638 -- the key-5 -> L3 blit, and the
 * actual last write to L3. The detour lets native run IN FULL (trampoline =
 * displaced prologue + continue at +4) then appends our composed tiles, so our
 * photo is simply last. No race to lose, no second painter behind us.
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
 * MEMORY: a 12-byte dead-.bss anchor (CTX/aerial_flags/reserved @0x044bb2d0) -> one heap
 * object. The big
 * buffers (backbuffer + tile cache + JPEG scratch) are fixed-size + card-
 * independent: allocated ONCE at feature-enable and KEPT (no per-card churn ->
 * no heap fragmentation). Only card-specific state (zoom dir, presence bitmaps,
 * file handle) is (re)built per card.
 *
 * TARGET: ARM920T (ARMv4T), ARM state, LE. No libc, no Thumb, no blx.
 * ==================================================================== */
// @mod 004
// @pkg 22
// @base modified/e80_mod003.bin
// @version 573->574
// @cov_version 274               // COV overlay build stamp -> AERIAL.COV header +0x1c
// @cov_name AERIAL                  // COV card file name -> mods/AERIAL.COV / card \AERIAL.COV
// @carry_tail 0x0059fec0
//
// --- firmware placement (build_cmod generates the firmware .ld from these) ---
// The COV half links flat (ORIGIN 0) and needs no @place; only the FIRMWARE half is
// placed into reclaimed runs. @run declares a region; @place assigns a symbol to it
// (an absolute 0xADDR target is an in-place splice, not a run).
// @run   run02 0x00291964 720
// @run   run10 0x00293b58 500
// @run   run12 0x002944d0 436
// @run   run18 0x002a495c 100
// @run   run19 0x002a4cb0 236
// @place run02      cov_load
// @place run12      aerial_cov_boot
// @place run12      compositeKey5_to_L3_detour
// @place run12      compositeKey5_to_L3_trampoline
// @place run12      aerial_cov_selfboot
// @place run18      aerial_cov_path
// @place 0x006da638 compositeKey5_to_L3_splice
// --- AERIAL composite splices. Three sites, each a pre+post detour calling ONE phase-aware COV
// export (phase = 0 pre / 1 post), forwarding this + the native composite args + the caller lr
// (stashed in aerial_abi_t.hook_call_site). The firmware stays dumb; the COV decides via CF bits and
// phase. Only 6_3_2 carries behaviour: the drawOverlays export is null and 4_6_1 is trace-only. ---
// 6_3_2 @0x006da2f8 (key6 <- key3|key2). Pre = REVEAL (key3 fill->blend remap, pre-blit); post =
// TRACE (native 6_3_2's EXIT state). Prologue e92d44f0, continue @0x006da2fc.
// @place run10      compositeLayers_6_3_2_detour
// @place run10      compositeLayers_6_3_2_trampoline
// @place 0x006da2f8 compositeLayers_6_3_2_splice
// drawOverlays @0x006d9b5c (runs the chart-engine key3 render). Pre = TRACE; post = REVEAL (the
// deterministic last-writer key3 remap). Prologue e92d44f0, continue @0x006d9b60.
// @place run10      drawOverlays_detour
// @place run10      drawOverlays_trampoline
// @place 0x006d9b5c drawOverlays_splice
// 4_6_1 @0x006d9f88 (key4 <- key6+key1 -> L2). Pre = TRACE; post = TRACE. Prologue e92d4cf0
// (stmdb {r4,r5,r6,r7,r10,r11,lr}), continue @0x006d9f8c. Placed in run19 (spread off run10).
// @place run19      compositeLayers_4_6_1_detour
// @place run19      compositeLayers_4_6_1_trampoline
// @place 0x006d9f88 compositeLayers_4_6_1_splice
#include <stdint.h>
#include <stddef.h>                           /* offsetof -- for the export-table asserts */
typedef uint8_t  u8;  typedef uint16_t u16;
typedef uint32_t u32; typedef int32_t  s32; typedef int16_t s16;

/* --- firmware bindings (verified) ----------------------------------- */
#define RM_MALLOC   ((void*(*)(u32))0x002a9434)
#define RM_FREE     ((void(*)(void*))0x001794e4)
#define FX_MEDIA()  ((void*)(*(volatile u32*)0x005d9a40 + 0xa4))
#define FX_OPEN     ((int(*)(void* media,void* fcb,const char* name,u32 type))0x002664e0)
#define FX_READ     ((int(*)(void* fcb,void* buf,u32 n,u32* act))0x00266900)
#define FX_SEEK     ((int(*)(void* fcb,u32 off))0x00266c24)
#define FX_CLOSE    ((int(*)(void* fcb))0x002660a0)
/* FileX DIRECTORY enumeration -- pinned in Ghidra and bench-verified on E80-4 against \RASTER
 * (returned '.', '..', BOCAS.RCT 70520592, INDEX.RCI 64; sizes matched the FILESYS listing exactly).
 * fx_directory_search takes an ABSOLUTE path (leading '\\'), which makes it skip the thread-local
 * path and the media default path entirely -- so this pair touches no shared filesystem state and
 * needs no fx_directory_default_set. fx_directory_entry_read walks the cluster chain of whatever
 * directory entry it is handed, so the entry returned for "\\RASTER" enumerates \RASTER. */
#define FX_DIRSEARCH ((int(*)(void* media,const char* path,void* dent,void* parent,void* lastname))0x00265d5c)
#define FX_DIRREAD   ((int(*)(void* media,void* dent,int* idx,void* oent))0x00267e88)
#define FX_DIRENT_SZ  0x120u   /* FX_DIR_ENTRY: name@+0, attr@+0x104, cluster@+0x110, size@+0x114 */
#define FX_DIRENT_MAX 512      /* our own belt: never spin the enumerator unbounded */
/* background render thread. NB the prio arg is MAPPED (FUN_0016f73c): 0->ThreadX prio 31
 * (LOWEST), 1->30, 2->12, 5->8, 7->4, 8->prio 2 (near-HIGHEST). The old "prio>=8 -> bg 20"
 * note CONFLATED priority with timeslice (20 was the timeslice) -- arg 8 made our
 * "background" thread preempt the UI. Pass 0. sleep arg = MILLISECONDS. */
#define RM_THREADCREATE ((int(*)(void* entry,void* input,u32 stk,u32 prio,void* tcb,void* nm,u32 id))0x0016e288)
#define RM_THREADSLEEP  ((void(*)(u32 ms))0x0016f594)
#define THREAD_NAME ((void*)0x010c26d4)
/* the proven firmware-JPEG->RGB555 primitive (bytes @import'd from mods/decode_blob.bin;
 * address resolved by the linker script) */
/* firmware geo inverse: ellipsoidal-merc semicircles -> geodetic lat/lon (1e-7 deg) */
#define MERC_TO_LATLON ((void(*)(s32 north,s32 east,s32* out_lat,s32* out_lon))0x005a8650)
/* ChartingAppPD_layerMapLookup(map = this+0x60, &key) -> layer node (red-black map;
 * key = node+0x0c, layer = node+0x14, NIL marker = node+0x5d; +0x28 = the layer's
 * background COLOUR). The map is PER-ChartingAppPD -- verified live on a
 * 2-window page: two distinct map heads, 7 entries each => EACH WINDOW OWNS ITS OWN KEY-5. */
#define LAYER_LOOKUP ((u32(*)(u32 map,u32* key))0x006d8b70)
/* ChartingAppPD_layerGetSurface(node+4, 1) -> the 16-byte Coral surface descriptor:
 *   +0x00 flags (0x20 = VRAM-backed) | +0x01 bpp | +0x02 w | +0x04 h | +0x08 mask | +0x0c base
 * PROBES this per window and records it for the host. The key-5 / hardware-blit fast
 * path needs exactly this accessor, and the open question that gates it ("is key-5 really
 * per-window, and what are its dims/base/flags?") is answered by the probe -- built now,
 * cheaply, rather than added cold later into runs with no free space. */
#define LAYER_SURF ((u32(*)(u32 layer,u32 which))0x006d9064)
/* ChartingAppPD_markAerialDirty(this) @0x006daef0 -- marks the aerial layer dirty and (if +0x158!=0)
 * fires renderOverlayToSurface. Used ONLY on the TEARDOWN path now (card-out / AO-off, from the render
 * thread, on a window rc_for_pd says is still live) to drive a repaint that lets the un-reveal take
 * effect. The pan-follow re-apply that used to call this from the render thread was the crash (it drove
 * renderOverlayToSurface into a window native was tearing down); the reveal re-fire now goes through
 * POST_UI_MSG below -- an async message, never a synchronous serve. */
#define MARK_AERIAL_DIRTY ((void(*)(u32 self))0x006daef0)
/* UI-message POST: FUN_008b64c0(target, msg, arg) -> (*(*(*target+0x14)+0x9c))(target,msg,arg), which
 * ENQUEUES an async message to the UI/display thread and returns immediately (measured ~1ms). Native's
 * own PhotoOverlayRC_renderThread posts UI_MSG_REDRAW (rc+0x20, 0x67, 0) on every render completion --
 * "I finished, redraw the UI". That redraw is a full drawOverlays(flags&0x10) paint -> compositeLayers_6_3_2
 * -> OUR 6_3_2 reveal hook. So posting 0x67 OURSELVES after a settled compose re-fires the reveal with NO
 * synchronous serve, NO re-entrancy, NO PD deref: the message lands on the UI thread, native paints
 * coherently on its own thread. This is the SAFE reveal re-fire -- bench-verified 2026-07-23 (revealed
 * 0->1 on a settled non-reveal view, twice, photo confirmed on screen). Replaces the whole synchronous
 * renderOverlayToSurface-from-the-kind5-hook approach, which corrupted the ctx (see history). */
#define POST_UI_MSG   ((void(*)(void* target, u32 msg, u32 arg))0x008b64c0)
#define UI_MSG_REDRAW 0x67u    /* native's own "render complete, redraw UI" message id */
#define RC_MSG_TARGET 0x20u    /* rc+0x20 = the RC's UI message target (native posts UI_MSG_REDRAW here) */
/* RayLib event flags. VERIFIED (decompile + live: native's render TCB reads
 * state = 7 = TX_EVENT_FLAG, i.e. blocked in RL_evWait on its own group):
 *   RL_evCreate(grp,nm,id) : memset(grp,0,0x2c); grp+0x24 = 0 -> AUTO-RESET (TX_OR_CLEAR);
 *                            grp+0x28 = 0; tx_event_flags_create(grp,name).  0 = ok.
 *   RL_evWait(grp)         : tx_event_flags_get(grp,1,TX_OR_CLEAR,&act,TX_WAIT_FOREVER)
 *                            -> BLOCKS on bit 0 and CONSUMES it.  0 = ok, 0x308 = deleted.
 *   RL_evSet(grp)          : tx_event_flags_set(grp,1,TX_OR).  0 = ok.
 * The object is 0x2c bytes and lives INSIDE our ctx (heap) -- no separate alloc, no code
 * region. We create our OWN group rather than blocking on native's ctrl+0xf28: that group
 * is AUTO-RESET, so one set wakes EXACTLY ONE waiter -- a second waiter would steal
 * native's wakes at random and break both sides -- and there is one group PER RC, so a
 * single thread could only ever block on one window's group. (Manual-reset twin: 0x0016e8bc.) */
#define RL_EVCREATE ((int(*)(void* grp,void* nm,u32 id))0x0016e8cc)
#define RL_EVWAIT   ((int(*)(void* grp))0x0016ea0c)
#define RL_EVSET    ((int(*)(void* grp))0x0016e964)
#define EVGRP_SZ 0x2c

/* --- runtime signals + hardware (no baked geometry) ----------------- */
#define CARD_READY  (*(volatile u32*)0x024ebdd8)
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
#define L3_BASE()   ((u16*)(0xd6000000u + *(volatile u32*)0xd7fd005c))
/* GDC2 CRTC panel geometry (same source as e80ScreenGrab::_screenSize) */
#define SCR_W()  (( *(volatile u32*)0xd7fd0008        & 0xffff) + 1)   /* 640 / 800 */
#define SCR_H()  (((*(volatile u32*)0xd7fd0014 >> 16) & 0xffff) + 1)   /* 480 / 600 (h inferred) */
/* AERIAL: composite-hook flag word -- the third .bss anchor word (0x044bb2d0=CTX,
 * +4=AERIAL_FLAGS, +8=here). Poke-able at runtime; aerial_cov_init BAKES the low byte 0x07 at boot
 * (self-start). Split into two maturity halves:
 *   LOW BYTE (baked as the self-start default):
 *     bit0 CF_HOOK_6_3_2   0x00000001  firmware: arm the 6_3_2 pre+post detour -> COV hook.
 *     bits 1-2             unused (the key3 reveal is now UNCONDITIONAL -- see reveal_masked; it
 *                          remaps key3's opaque-fill band 0x21-0x2f -> blend twin 0x01-0x0f so
 *                          chart fills reveal L3 while symbology stays opaque).
 *   HIGH BYTE = diagnostics, default 0:
 *     bit24 CF_HOOK_4_6_1  0x01000000  firmware: arm the 4_6_1 pre+post detour -> COV hook.
 *     bit25 CF_TRACE       0x02000000  COV: arm the TRACE recorder. The 0->1 edge RESETS the ring;
 *                          the ring freezes itself TRACE_POST events after the band appears.
 *     bit28 CF_GREEN       0x10000000  COV: fill the window with green before tiling, so any area
 *                          the tiler does not cover shows through the reveal.
 *   bits 1-23, 26, 27, 29-31 unused.
 * The COV never pokes the CLUT (stock CLUT: 0x21-0x2f opaque, 0x01-0x0f blend); the reveal is
 * entirely the key3 index remap. */
#define COMPOSITE_FLAGS (*(volatile u32*)0x044bb2d8)
#define CF_DEFAULT      0x10000001u  /* baked by aerial_cov_init: GREEN | HOOK_6_3_2 */
#define CF_HOOK_6_3_2   0x00000001u
#define CF_HOOK_4_6_1   0x01000000u
#define CF_TRACE        0x02000000u
#define CF_GREEN        0x10000000u

/* TRACE recorder geometry. The ring is COV heap (10 KB), not a run -> zero run cost. */
#define TRACE_N    128u   /* ring depth in events (~1.7 s of composite history at ~10 Hz) */
#define TRACE_W    20u    /* u32 words per event -- see the tr_ev layout on aerial_ctx_t   */
#define TRACE_POST 24u    /* events still recorded AFTER the trigger before the ring freezes */

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
/* ==== THE FLASHED CONTRACT -- the only part of the ctx anything outside the COV may touch ====
 * Lives at the HEAD of aerial_ctx_t, deliberately. The flashed detour reads these with
 * `ldr rX,[rY,#imm12]`, whose displacement range is 0..4095; at the TAIL of a ~12KB struct those
 * literals drift toward that ceiling every time something is inserted ahead of them. At the head
 * they are permanently immune however large the COV-private half grows.
 *
 * abi_version is FIRST because it is the key that makes every other offset trustworthy: a host tool
 * peeks CTX+0, learns which ABI it is talking to, and only then knows where anything else lives. It
 * also gives a free "not booted" test -- the ctx is mzero'd at alloc, so 0 means nothing published yet.
 *
 * THE RULE: any change INSIDE this struct bumps AERIAL_ABI. Anything below it is COV-private and
 * changes freely, because nothing outside the COV addresses it -- the host reaches the volatile
 * interior through the published pointers below (x_trace_block, x_win_slots), never by offset.
 * Skew is caught at LOAD, not at call: cov_load compares the COV header's abi_version against the
 * flashed AERIAL_ABI, so a stale AERIAL.COV is REFUSED and the null-export path keeps the unit stock. */
typedef struct {
    u32 abi_version;                  /* +0    == AERIAL_ABI. Read this before trusting any offset. */
    /* ---- exports: published BY the COV, called by the flashed detour and by the host ---- */
    u32 x_aerial_cov_start;           /* +4    void(*)(void)     -- host: buffers + threads (the "enable") */
    u32 x_aerial_deactivate_region;   /* +8    void(*)(void)     -- host: stand down                      */
    u32 x_aerial_suppress_native_L3;  /* +12   int (*)(u32 self) -- kind5 PRE: 1 = suppress native blit   */
    u32 x_aerial_draw_L3;             /* +16   int (*)(u32 self) -- kind5 POST: draw our tiles to L3      */
    u32 x_compositeLayers_6_3_2_hook; /* +20   int (*)(self,phase,flags,rect) -- pre(REVEAL)/post         */
    u32 x_drawOverlays_hook;          /* +24   int (*)(self,phase,...)        -- retired; published null  */
    u32 x_compositeLayers_4_6_1_hook; /* +28   int (*)(self,phase,flags,rect) -- TRACE-only site          */
    /* ---- published INTERIOR POINTERS: how the host reaches COV-private state without knowing
     * a single interior offset. Add to these rather than teaching a script a new displacement. ---- */
    u32 x_trace_block;                /* +32   &tr_lock   -- scripts/_aerial_trace.pl reads the ring here */
    u32 x_win_slots;                  /* +36   &win[0]    -- per-window state; stride = sizeof(wslot_t)   */
    u32 x_reserved[22];               /* +40..+127  future exports without a re-layout                    */
    /* ---- firmware -> COV: written by the FLASHED detour, read by us ---- */
    u32 hook_call_site;               /* +128  the lr the detour stashed = the NATIVE call site + 4, i.e.
                                       *       WHICH of several callers entered the hooked function this
                                       *       time. Not the splice site (that is one fixed address we
                                       *       already know). Six flashed store sites use this offset. */
    u32 fw_reserved[15];              /* +132..+191  further detour->COV fields without a re-layout       */
} aerial_abi_t;                       /* 192 bytes */

typedef struct {
    aerial_abi_t abi;                         /* +0 -- THE FLASHED CONTRACT (see above). */
    /* ================= everything below here is COV-PRIVATE and freely re-arrangeable ================= */
    u8 inited, enabled, active;               /* enabled = feature flag (aerial_cov_start) */
    u32 card_gen, tick;
    u32 scr_w, scr_h;                         /* derived once from the CRTC */
    /* THE FUSED PYRAMID: every .RCT on the card merged into one zdir over the union zmin..zmax.
     * Each block carries its own file handle, so nothing here is per-region scratch any more. */
    zoomdir_t* zdir; u32 zmin,zmax; void* blob;
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
     * chartset_teardown frees them from the RENDER thread. Same bounded-SWP idiom as tr_lock;
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
    /* ---- TRACE recorder (CF_TRACE). COV heap, NOT a run -> zero run cost. A contiguous all-u32
     * block that scripts/_aerial_trace.pl peeks whole -- it finds the block by reading the
     * PUBLISHED POINTER abi.x_trace_block (= &tr_lock), never by a hardcoded ctx offset, so this
     * whole region may be re-arranged without touching the host.
     *
     * WHY A RING AND NOT COUNTERS: the band writer has to be caught in a MULTI-ENTRY function, so
     * a per-hook "last value" destroys the very sequence that identifies it. This records a TRACE
     * -- every hook entry and exit, plus every write of our own -- in global SWP-ticket order, and
     * FREEZES the ring once the band appears so a (slow) UDP read can retrieve the moment intact.
     * The ticket IS the ordering, so the trace stays correct however many threads append to it and
     * we need no clock. Each event samples BOTH key3 and key6 at a band row and a control row: if
     * key6 goes opaque while key3 stays blended there is a key6 writer, and if key3 goes opaque too
     * then the chart engine re-rendered key3 after our filter and there is no key6 writer at all.
     *
     * The caller lr the events record is abi.hook_call_site, written by the FLASHED detour at six
     * sites; it lives in aerial_abi_t now, not here.
     *
     * EVENT LAYOUT (TRACE_W = 16 u32, slot = seq % TRACE_N):
     *   0 seq        global SWP ticket == total order across threads
     *   1 site       0=6_3_2 1=drawOverlays 2=4_6_1 3=kind5 4=our reveal 5=our scrub 6=our L3 blit
     *   2 phase      0 = pre / before native, 1 = post / after native (0 for our own writes)
     *   3 lr         caller lr the detour stashed (= native call site + 4); 0 for our own writes
     *   4 flags      native composite flags (6_3_2 / 4_6_1 only; drawOverlays' detour omits it)
     *   5 sp         current stack pointer -- thread identity WITHOUT knowing ThreadX internals
     *   6 k3_band    key3 probe, band row      } packed: low 16 = opaque mask, high 16 = blend mask,
     *   7 k3_ctl     key3 probe, control row   } bit i = probe point i of PROBE_N across the row.
     *   8 k6_band    key6 probe, band row      } 0 = layer not mapped (a fact worth seeing).
     *   9 k6_ctl     key6 probe, control row   }
     *  10 rect       the native update-rect POINTER (0 when the hook is not passed one)
     *  11..14        rect[0..3] when rect != 0 -- answers "is there a PARTIAL composite" directly
     *  15 aux        c->drawing (tiles placed in the current compose)
     *  16 self       the PD this hook ran on -- says whether two call-site groups share a buffer
     *  17 ctr        Coral CTR (0xd7ff0400) sampled LIVE at this event: engine state chain-wide
     *  18 waits      poll iterations the last CTR fence consumed (0 = fence off or already idle)
     *  19 ctr_in     CTR as the last fence FOUND it, before waiting -- the falsifier: if this
     *                reads idle on the frames the band appears, the drawing engine is NOT the
     *                writer and a fence cannot fix it. */
    /* TRACE BLOCK START -- abi.x_trace_block points here. Keep these contiguous and in this
     * order; the host unpacks them as a run from that pointer. */
    u32 tr_lock;                /* SWP spinlock over tr_seq; bounded spin, drop on contention */
    u32 tr_seq;                 /* monotonic ticket == global event order                     */
    u32 tr_armed;               /* shadow of CF_TRACE; the 0->1 edge resets the ring          */
    u32 tr_frozen;              /* 1 = stop appending (trigger fired, post-depth spent)       */
    u32 tr_band;                /* last key6 band-row state (1 = any opaque probe point)      */
    u32 tr_post;                /* post-trigger events still to record before freezing        */
    u32 tr_trig;                /* seq+1 at which the trigger fired (0 = not yet)             */
    u32 tr_drop;                /* events dropped on lock contention (should stay 0)          */
    /* CORAL FENCE -- part of the FEATURE, not instrumentation. Before the key3 remap we wait for
     * the graphics engine to go idle, because the chart render into key3 is still in flight and a
     * remap that races it loses the leading rows (the top-band defect). tr_fence is the MAXIMUM
     * poll iterations; the bound is not optional -- the firmware ships a "Coral Command List
     * Timeout Exceed" string, i.e. the vendor's own driver expects this engine to hang, and we
     * must never spin forever inside the compositor. BAKED to FENCE_DEFAULT at init so a cold boot
     * is correct; poke it to 0 to reproduce the defect on demand. */
    u32 tr_fence;               /* max CTR poll iterations before the reveal (0 = off)        */
    u32 tr_waits;               /* iterations the last fence actually consumed                */
    u32 tr_ctr_in;              /* CTR as the last fence found it (pre-wait)                  */
    /* MASK LEVEL -- a live knob, like tr_fence above (which is likewise feature, not
     * instrumentation). The zoom at which the reveal contour is cut: LOWER = coarser = fewer,
     * bigger rects = cheaper and blockier; HIGHER = finer contour. Baked to MASK_Z at init and
     * poke-able at runtime via `aerial_abi.pl maskz N`; build_mask clamps it to the card's
     * available zmin..zmax, and every window's cached mask self-invalidates when it changes
     * (wslot.mask_built_z), so a poke takes effect on the next composite with no reboot. */
    u32 mask_z;
    u32 tr_ev[TRACE_N*TRACE_W]; /* the ring itself -- TRACE BLOCK END                         */
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
 * boot on this 1-NIC hardware (see docs/work/codespace.md, region D2). 12 bytes = 3 words:
 *   +0x00 CTX (the one heap-object pointer)   +0x04 aerial_flags   +0x08 reserved.
 * .bss => zero from cold boot, so `if(!CTX)` is a valid "not booted" test with no init. */
#define CTX          (*(aerial_ctx_t**)0x044bb2d0)   /* word 0: the one and only ctx anchor */
#define AERIAL_FLAGS (*(volatile u32*)0x044bb2d4)  /* word 1: flags (bit0 = read_tried) */
#define AF_READ_TRIED 1u                      /* set once per card-presence: gates re-boot */

/* The detour is naked asm and needs the export offsets as literal ldr displacements.
 * These _Static_asserts (expressible only because ONE .c holds both halves) make the
 * literals un-driftable: change aerial_ctx_t above and the build FAILS here, not on the boat. */
/* Offsets into aerial_abi_t. Because that struct sits at ctx+0 these are ALSO ctx offsets, which
 * is the point: they are small, they are stable, and they can never approach the ldr imm12 ceiling
 * no matter how the COV-private half grows. */
#define EXP_ENABLE       4   /* x_aerial_cov_start          -- host: the "enable"    */
#define EXP_DEACTIVATE   8   /* x_aerial_deactivate_region  -- host: stand down      */
#define EXP_SUPPRESS    12   /* x_aerial_suppress_native_L3 -- kind5 pre             */
#define EXP_DRAW        16   /* x_aerial_draw_L3            -- kind5 post            */
#define EXP_632         20   /* x_compositeLayers_6_3_2_hook                         */
#define EXP_DOV         24   /* x_drawOverlays_hook                                  */
#define EXP_461         28   /* x_compositeLayers_4_6_1_hook                         */
#define HOOK_CALL_SITE 128   /* aerial_abi_t.hook_call_site -- detour stashes the caller lr here */
_Static_assert(offsetof(aerial_ctx_t, abi)                          == 0,              "aerial_abi_t must sit at ctx+0");
_Static_assert(offsetof(aerial_abi_t, abi_version)                  == 0,              "abi_version must sit at abi+0");
_Static_assert(offsetof(aerial_abi_t, x_aerial_cov_start)           == EXP_ENABLE,     "detour EXP_ENABLE drift");
_Static_assert(offsetof(aerial_abi_t, x_aerial_deactivate_region)   == EXP_DEACTIVATE, "detour EXP_DEACTIVATE drift");
_Static_assert(offsetof(aerial_abi_t, x_aerial_suppress_native_L3)  == EXP_SUPPRESS,   "detour EXP_SUPPRESS drift");
_Static_assert(offsetof(aerial_abi_t, x_aerial_draw_L3)             == EXP_DRAW,       "detour EXP_DRAW drift");
_Static_assert(offsetof(aerial_abi_t, x_compositeLayers_6_3_2_hook) == EXP_632,        "detour EXP_632 drift");
_Static_assert(offsetof(aerial_abi_t, x_drawOverlays_hook)          == EXP_DOV,        "detour EXP_DOV drift");
_Static_assert(offsetof(aerial_abi_t, x_compositeLayers_4_6_1_hook) == EXP_461,        "detour EXP_461 drift");
_Static_assert(offsetof(aerial_abi_t, hook_call_site)               == HOOK_CALL_SITE, "detour HOOK_CALL_SITE drift");
_Static_assert(sizeof(aerial_abi_t) == 192, "aerial_abi_t size drift -- bump AERIAL_ABI deliberately, never by accident");
/* The reason the contract lives at the head: every displacement the FLASHED detour encodes must fit
 * the ARM ldr immediate. This is the bound, asserted rather than remembered. */
_Static_assert(HOOK_CALL_SITE < 4096, "detour ldr imm12 range exceeded");
/* HOST contract: _aerial_trace.pl locates the block through abi.x_trace_block (= &tr_lock) and
 * unpacks it as a run from there -- so what must stay fixed is the block's INTERNAL layout, not
 * its offset within the ctx. Assert that instead, and the interior stays free to move. */
#define TRB(f) (offsetof(aerial_ctx_t,f) - offsetof(aerial_ctx_t,tr_lock))
_Static_assert(TRB(tr_seq)    ==  4, "trace block layout drift (tr_seq)");
_Static_assert(TRB(tr_fence)  == 32, "trace block layout drift (tr_fence)");
_Static_assert(TRB(tr_waits)  == 36, "trace block layout drift (tr_waits)");
_Static_assert(TRB(tr_ctr_in) == 40, "trace block layout drift (tr_ctr_in)");
_Static_assert(TRB(mask_z)    == 44, "trace block layout drift (mask_z)");
_Static_assert(TRB(tr_ev)     == 48, "trace block layout drift (tr_ev)");

/* TRACE sites. 0-3 are native hook points (phase 0 = before native, 1 = after); 4-6 are OUR OWN
 * writes, recorded so our contribution is a visible row in the trace instead of a term that has to
 * be reasoned away afterwards. Declared here (not at the recorder) because the render thread and
 * the kind5 hooks appear earlier in the file than the recorder body. */
#define TR_S_632     0u
#define TR_S_DOV     1u
#define TR_S_461     2u
#define TR_S_K5      3u
#define TR_S_REVEAL  4u
#define TR_S_SCRUB   5u
#define TR_S_L3      6u
static void trace_evt(aerial_ctx_t* c,u32 self,u32 site,u32 phase,u32 flags,u32 rect);
#define STR2(x) #x
#define XSTR(x) STR2(x)                       /* -> the EXP_* literal inside the naked asm */

/* ---- COV format + THIS feature's identity ---------------------------------
 * Shared by both halves: the firmware bootstrap passes MAGIC/ABI to cov_load, and
 * _cov_pack stamps the same values into AERIAL.COV's header, which cov_load then
 * checks. The loader itself knows no feature -- it only compares what it is handed. */
#define COV_FORMAT   1u                       /* the loader's header contract */
#define AERIAL_MAGIC 0x30413444u              /* 'M4A0' -- the FEATURE's magic (value kept from MOD004) */
#define AERIAL_ABI   6u                       /* export-table contract. 6 = aerial_abi_t moved to the HEAD of the ctx
                                               * (abi_version @+0, exports @+4, hook_call_site @+128). Any change INSIDE
                                               * aerial_abi_t bumps this; everything below it is COV-private and free. */
typedef struct {
    u32 magic, format_version, abi_version, code_len, entry_off, nreloc, code_sum, reserved;
} cov_hdr_t;                                  /* 0x20 */

#ifndef COV_BUILD
/* ======================================================================================
 * FIRMWARE HALF -- flashed into NOR (compiled WITHOUT -DCOV_BUILD). Only these functions
 * live in .text: the loader, the bootstrap, and the splice/detour/trampoline hook. The
 * brain is on the card. `if(!CTX)` / null-export is the stay-stock path.
 * ==================================================================================== */

/* @place run18 */
static const char aerial_cov_path[] = "\\AERIAL.COV";

/* @place run02 -- THE LINKING LOADER. Reads a COV off the card
 * into heap, verifies header + rotate-add checksum, applies the R_ARM_ABS32 relocations
 * (*(base+off)+=base), returns base+entry_off. Position-independent; every failure -> 0. */
void* cov_load(const char* path, u32 magic, u32 abi)
{
    cov_hdr_t h;
    void* fcb; u32* rel = 0; u8* base = 0; u32 got, i, s;
    fcb = RM_MALLOC(0x180);                        /* 0x100 CORRUPTS: open writes fcb+0x164 */
    if (!fcb) return 0;
    if (FX_OPEN(FX_MEDIA(), fcb, path, 0)) { RM_FREE(fcb); return 0; }   /* 0 = READ */
    if (FX_READ(fcb, &h, sizeof(h), &got) || got != sizeof(h)) goto fail;
    if (h.magic != magic)               goto fail; /* the FEATURE's magic, passed IN     */
    if (h.format_version != COV_FORMAT) goto fail; /* the LOADER's own header contract   */
    if (h.abi_version != abi)           goto fail; /* the FEATURE's ABI, passed IN       */
    if (!h.code_len || !h.nreloc)       goto fail;
    rel = RM_MALLOC(h.nreloc * 4);
    if (!rel) goto fail;
    if (FX_READ(fcb, rel, h.nreloc * 4, &got) || got != h.nreloc * 4) goto fail;
    base = RM_MALLOC(h.code_len);
    if (!base) goto fail;
    if (FX_READ(fcb, base, h.code_len, &got) || got != h.code_len) goto fail;
    FX_CLOSE(fcb); RM_FREE(fcb); fcb = 0;
    for (s = 0, i = 0; i < h.code_len; i++) s = (s << 1) + (s >> 31) + base[i];
    if (s != h.code_sum) goto fail;
    for (i = 0; i < h.nreloc; i++) *(u32*)(base + rel[i]) += (u32)base;
    RM_FREE(rel);
    return base + h.entry_off;
fail:
    if (fcb)  { FX_CLOSE(fcb); RM_FREE(fcb); }
    if (base) RM_FREE(base);
    if (rel)  RM_FREE(rel);
    return 0;
}

/* @place run05 -- diag-callable BOOTSTRAP (LOAD + INIT). Loads AERIAL.COV and calls its
 * entry (aerial_cov_init, resolved by the header's entry_off -- the loader is name-blind). Returns
 * aerial_cov_init's result = (int)CTX, or 0 if the card/COV is missing or bad -> stays stock. This
 * only publishes CTX + the export table; the overlay is still INERT. The host turns it on
 * afterwards: peek CTX -> peek c->abi.x_aerial_cov_start -> call it. */
int aerial_cov_boot(void)
{
    if (CTX) return (int)(u32)CTX;                 /* already booted -> idempotent: no reload,
                                                    * no 2nd 7KB blob leak, exports stay put */
    void* e = cov_load(aerial_cov_path, AERIAL_MAGIC, AERIAL_ABI);
    if (!e) return 0;
    return ((int(*)(void))e)();
}

/* @place run12 -- SELF-BOOT gate (). Called from the detour on the paint path when the
 * overlay may not be loaded yet. Boots the COV once per card-presence, CARD-FIRST so a
 * cardless boot never loads (the stay-stock recovery lever), and gated by the read_tried bit
 * so a no-COV card is not re-read every paint. `booted` latches: once CTX is set this returns
 * immediately and the COV persists in heap across card removal/reinsert. Returns (int)CTX or 0.
 * Kept in C (not the naked detour) so the compiler emits it -- the detour asm change stays a
 * two-instruction swap. aerial_cov_init (invoked by aerial_cov_boot) auto-arms + spawns the render thread,
 * so no host x_aerial_cov_start call is needed for a fully-functional-from-boot unit. */
int aerial_cov_selfboot(void)
{
    if (CTX) return (int)(u32)CTX;                          /* booted -> idempotent            */
    if (!CARD_READY) { AERIAL_FLAGS &= ~AF_READ_TRIED; return 0; } /* no card: retry on insert  */
    if (AERIAL_FLAGS & AF_READ_TRIED) return 0;            /* already tried this card-presence */
    AERIAL_FLAGS |= AF_READ_TRIED;                          /* set BEFORE the attempt          */
    return aerial_cov_boot();                                  /* load + aerial_cov_init (arms + thread)  */
}

/* @place run05 -- THE DETOUR (rewritten for ). Spliced-to over compositeKey5_to_L3's
 * head @0x006da638 via `b` (so at entry r0=this, r1=0, r2=this+0xf0, lr=the dispatcher).
 * Calls the brain THROUGH the export table instead of `bl`-ing it, because the brain now
 * lives in the heap-loaded COV. `if(!CTX)` or an unpublished export -> native-only, which
 * is the stay-stock path. r5=CTX survives the trampoline call: compositeKey5_to_L3's own
 * prologue (e92d40f0 = stmdb {r4-r7,lr}) saves and restores r4-r7. ARMv4T: no blx. */
__attribute__((naked)) void compositeKey5_to_L3_detour(void)
{
    __asm__ volatile(
        "stmdb sp!, {r0,r1,r2,r3,r4,r5,r6,lr}\n" /* native args + scratch + lr (32B, 8-aligned) */
        "bl aerial_cov_selfboot\n"                   /* r0 = CTX; self-boots the COV if a card is in
                                                  * and not yet tried (). lr saved above. */
        "movs r5, r0\n"                          /* r5 = c = CTX, set flags */
        "beq 1f\n"                               /* !c -> native only (stay stock) */
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
    );
}

/* @place run05 -- the displaced native prologue + continuation (compositeKey5_to_L3).
 * Reached by `bl` from the detour with args intact; native's epilogue pops the pushed lr
 * -> returns into the detour, which then appends. Firmware, PC-relative -- no export. */
__attribute__((naked)) void compositeKey5_to_L3_trampoline(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4,r5,r6,r7,lr}\n"       /* displaced compositeKey5_to_L3 prologue (e92d40f0) */
        "mov ip, #0x006d0000\n"
        "orr ip, ip, #0xa600\n"
        "orr ip, ip, #0x3c\n"                 /* ip = 0x006da63c = kind5+4 (sub sp,sp,#0x20) */
        "bx ip\n"
    );
}

/* @place 0x006da638 -- the in-place splice: the linker drops this single branch onto
 * compositeKey5_to_L3's first instruction, replacing its stmdb with `b compositeKey5_to_L3_detour`.
 * `b` (not bl) so the detour inherits the caller's lr. THE ONLY firmware site overwritten. */
__attribute__((naked)) void compositeKey5_to_L3_splice(void){ __asm__ volatile("b compositeKey5_to_L3_detour\n"); }

/* ---- base-chart composite 6_3_2 PRE+POST detour ----------------------------------------
 * Spliced onto compositeLayers_6_3_2 @0x006da2f8 (key3(+key2) -> key6). 6_3_2 is an 8bpp INDEX
 * copy (verified live: key3==key6==key4 at fills), so a fill index remapped to its blend-twin
 * propagates to L2 unchanged. The unified research detour calls the ONE phase-aware export
 * x_compositeLayers_6_3_2_hook(self, phase, flags, rect) BEFORE native (phase 0 = pre: REVEAL, the
 * pre-blit key3 remap) and AFTER native (phase 1 = post: TRACE the resulting key6 top strip). The
 * caller lr is stashed at aerial_abi_t.hook_call_site for the ledger's lr histogram. Gated by
 * CF_HOOK_6_3_2 (bit0) + CTX + published export; the pre return (r0 & 1) can suppress native (unused
 * by 6_3_2, always 0). `if(!CTX)`/flag-off/unpublished -> native only. Displaced prologue verified
 * live: e92d44f0 stmdb {r4,r5,r6,r7,sl,lr}; continue @0x006da2fc.   */
__attribute__((naked)) void compositeLayers_6_3_2_trampoline(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4,r5,r6,r7,sl,lr}\n"       /* displaced 6_3_2 prologue (e92d44f0) */
        "mov ip, #0x006d0000\n"
        "orr ip, ip, #0xa200\n"
        "orr ip, ip, #0xfc\n"                    /* ip = 0x006da2fc = 6_3_2 head+4 */
        "bx ip\n"
    );
}
__attribute__((naked)) void compositeLayers_6_3_2_detour(void)
{
    /* Unified pre+post research detour. PRE (phase 0): the COV filters key3 while native's key3->key6
     * DMA has NOT started (pre-blit reveal, no race). POST (phase 1): the COV traces the resulting
     * key6 top strip. r5=CTX and r6=hook survive across the native call (both callee-saved + native
     * 6_3_2 preserves r4-r7). r4 carries the pre-skip flag then native's return. */
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
        "ldr r4, [sp, #28]\n"                    /* caller lr (site+4) */
        "str r4, [r5, #" XSTR(HOOK_CALL_SITE) "]\n"  /* stash for the ledger lr histogram */
        "ldr r0, [sp]\n"                         /* r0 = this        (native r0 @[sp+0]) */
        "mov r1, #0\n"                           /* phase = PRE */
        "ldr r2, [sp, #12]\n"                    /* r2 = flags       (native r3 @[sp+12], param_4) */
        "ldr r3, [sp, #4]\n"                     /* r3 = updateRect  (native r1 @[sp+4], param_2) */
        "mov lr, pc\n"
        "bx r6\n"                                /* hook(self,0,flags,rect) -> r0 = skip flag */
        "mov r4, r0\n"                           /* r4 = pre-skip flag */
        "ldmia sp, {r0,r1,r2,r3}\n"              /* restore native args (sp not popped) */
        "tst r4, #1\n"
        "bleq compositeLayers_6_3_2_trampoline\n"/* run native 6_3_2 unless pre suppressed it */
        "mov r4, r0\n"                           /* preserve native's return */
        "ldr r6, [r5, #" XSTR(EXP_632) "]\n"     /* reload hook (trampoline clobbered r6) */
        "ldr r0, [sp, #28]\n"
        "str r0, [r5, #" XSTR(HOOK_CALL_SITE) "]\n"  /* lr for the post call (same site) */
        "ldr r0, [sp]\n"
        "mov r1, #1\n"                           /* phase = POST */
        "ldr r2, [sp, #12]\n"
        "ldr r3, [sp, #4]\n"
        "mov lr, pc\n"
        "bx r6\n"                                /* hook(self,1,flags,rect) -- TRACE */
        "mov r0, r4\n"                           /* return native's r0 to the caller */
        "add sp, sp, #16\n"                      /* drop saved r0-r3 */
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"
        "1:\n"                                   /* ---- native-only path ---- */
        "ldmia sp, {r0,r1,r2,r3}\n"              /* restore native args (sp not popped) */
        "bl compositeLayers_6_3_2_trampoline\n"  /* run native 6_3_2 IN FULL */
        "add sp, sp, #16\n"                      /* drop saved r0-r3 */
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"                                /* return native's r0 to the caller */
        ".L_ctx_632: .word 0x044bb2d0\n"
        ".L_cf_632:  .word 0x044bb2d8\n"
    );
}
/* @place 0x006da2f8 -- the in-place splice (overwrites 6_3_2's first instruction = the stmdb the
 * trampoline displaces). `b` (not bl) so the detour inherits lr. */
__attribute__((naked)) void compositeLayers_6_3_2_splice(void){ __asm__ volatile("b compositeLayers_6_3_2_detour\n"); }

/* ---- drawOverlays PRE+POST detour ------------------------------------------------------
 * Spliced onto ChartingAppPD_drawOverlays @0x006d9b5c. drawOverlays runs FUN_006d4ef8 -> the chart-
 * engine render that FILLS key3 (the base chart). The unified research detour calls the ONE phase-
 * aware export x_drawOverlays_hook(self, phase, ...) BEFORE native (phase 0 = pre: TRACE) and AFTER
 * native (phase 1 = post: REVEAL, the deterministic last-writer key3 remap -- the render lives here,
 * so remapping post catches the base render regardless of frame order, and also catches the
 * coordinate-band strip). Gated flags bit1 + CTX + published export; `this`(r0). The COV publishes
 * a NULL export for this hook, so the detour falls through to native. Pre never
 * suppresses native. Displaced prologue: e92d44f0 stmdb {r4,r5,r6,r7,sl,lr}; continue @0x006d9b60. */
__attribute__((naked)) void drawOverlays_trampoline(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4,r5,r6,r7,sl,lr}\n"       /* displaced drawOverlays prologue (e92d44f0) */
        "mov ip, #0x006d0000\n"
        "orr ip, ip, #0x9b00\n"
        "orr ip, ip, #0x60\n"                    /* ip = 0x006d9b60 = drawOverlays head+4 */
        "bx ip\n"
    );
}
__attribute__((naked)) void drawOverlays_detour(void)
{
    __asm__ volatile(
        "stmdb sp!, {r0,r1,r2,r3,r4,r5,r6,lr}\n" /* native args + scratch + lr (32B, 8-aligned) */
        "ldr r5, .L_ctx_dov\n"
        "ldr r5, [r5]\n"                         /* r5 = CTX */
        "cmp r5, #0\n"
        "beq 1f\n"                               /* !CTX -> native only */
        "ldr r6, .L_cf_dov\n"
        "ldr r6, [r6]\n"
        "tst r6, #2\n"                           /* flags bit1 (export is null -> falls through) */
        "beq 1f\n"
        "ldr r6, [r5, #" XSTR(EXP_DOV) "]\n"     /* r6 = c->abi.x_drawOverlays_hook */
        "cmp r6, #0\n"
        "beq 1f\n"                               /* export not published -> native only */
        "ldr r4, [sp, #28]\n"                    /* caller lr (site+4) */
        "str r4, [r5, #" XSTR(HOOK_CALL_SITE) "]\n"  /* stash for the ledger lr histogram */
        "ldr r0, [sp]\n"                         /* r0 = this */
        "mov r1, #0\n"                           /* phase = PRE (TRACE) */
        "ldr r2, [sp, #12]\n"
        "ldr r3, [sp, #4]\n"
        "mov lr, pc\n"
        "bx r6\n"                                /* hook(self,0,...) -> r0 = skip flag (unused) */
        "mov r4, r0\n"
        "ldmia sp, {r0,r1,r2,r3}\n"              /* restore native args (sp not popped) */
        "tst r4, #1\n"
        "bleq drawOverlays_trampoline\n"         /* run native drawOverlays IN FULL (renders key3) */
        "mov r4, r0\n"                           /* preserve native's return */
        "ldr r6, [r5, #" XSTR(EXP_DOV) "]\n"     /* reload hook (trampoline clobbered r6) */
        "ldr r0, [sp, #28]\n"
        "str r0, [r5, #" XSTR(HOOK_CALL_SITE) "]\n"  /* lr for the post call */
        "ldr r0, [sp]\n"                         /* r0 = this */
        "mov r1, #1\n"                           /* phase = POST (REVEAL) */
        "ldr r2, [sp, #12]\n"
        "ldr r3, [sp, #4]\n"
        "mov lr, pc\n"
        "bx r6\n"                                /* hook(self,1,...) -- REVEAL, right after the render */
        "mov r0, r4\n"                           /* restore native's return */
        "add sp, sp, #16\n"                      /* drop saved r0-r3 */
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"
        "1:\n"                                   /* ---- native-only path ---- */
        "ldmia sp, {r0,r1,r2,r3}\n"
        "bl drawOverlays_trampoline\n"
        "add sp, sp, #16\n"
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"
        ".L_ctx_dov: .word 0x044bb2d0\n"
        ".L_cf_dov:  .word 0x044bb2d8\n"
    );
}
/* @place 0x006d9b5c -- in-place splice (overwrites drawOverlays' first instruction = the stmdb the
 * trampoline displaces). `b` (not bl) so the detour inherits lr. */
__attribute__((naked)) void drawOverlays_splice(void){ __asm__ volatile("b drawOverlays_detour\n"); }

/* ---- NEW 4_6_1 PRE+POST detour ---------------------------------------------------------
 * Spliced onto compositeLayers_4_6_1 @0x006d9f88 (key4 <- key6 + key1 -> L2, the last stage before
 * L2). The unified research detour calls x_compositeLayers_4_6_1_hook(self, phase, flags, rect) BEFORE
 * native (phase 0 = pre: SCRUB_KEY6 the top strip + TRACE; the pre return r0&1 SUPPRESSES native
 * when the hook returns 1; the COV always returns 0) and AFTER native (phase 1 = post: TRACE).
 * scrubbing key6's top strip here, downstream of every key3 hook, clears the 0x20 opacity bit the
 * unidentified native writer re-asserts. Gated CF_HOOK_4_6_1 (bit24) + CTX + published export.
 * Displaced prologue verified: e92d4cf0 stmdb {r4,r5,r6,r7,r10,r11,lr}; continue @0x006d9f8c. */
__attribute__((naked)) void compositeLayers_4_6_1_trampoline(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4,r5,r6,r7,r10,r11,lr}\n"  /* displaced 4_6_1 prologue (e92d4cf0) */
        "mov ip, #0x006d0000\n"
        "orr ip, ip, #0x9f00\n"
        "orr ip, ip, #0x8c\n"                    /* ip = 0x006d9f8c = 4_6_1 head+4 */
        "bx ip\n"
    );
}
__attribute__((naked)) void compositeLayers_4_6_1_detour(void)
{
    __asm__ volatile(
        "stmdb sp!, {r0,r1,r2,r3,r4,r5,r6,lr}\n" /* native args + scratch + lr (32B, 8-aligned) */
        "ldr r5, .L_ctx_461\n"
        "ldr r5, [r5]\n"                         /* r5 = CTX */
        "cmp r5, #0\n"
        "beq 1f\n"                               /* !CTX -> native only */
        "ldr r6, .L_cf_461\n"
        "ldr r6, [r6]\n"
        "tst r6, #0x01000000\n"                  /* CF_HOOK_4_6_1 (bit24) */
        "beq 1f\n"
        "ldr r6, [r5, #" XSTR(EXP_461) "]\n"     /* r6 = c->abi.x_compositeLayers_4_6_1_hook */
        "cmp r6, #0\n"
        "beq 1f\n"                               /* export not published -> native only */
        "ldr r4, [sp, #28]\n"                    /* caller lr (site+4) */
        "str r4, [r5, #" XSTR(HOOK_CALL_SITE) "]\n"  /* stash for the ledger lr histogram */
        "ldr r0, [sp]\n"                         /* r0 = this */
        "mov r1, #0\n"                           /* phase = PRE (SCRUB/SKIP/TRACE) */
        "ldr r2, [sp, #12]\n"
        "ldr r3, [sp, #4]\n"
        "mov lr, pc\n"
        "bx r6\n"                                /* hook(self,0,...) -> r0 = skip flag (COV: always 0) */
        "mov r4, r0\n"                           /* r4 = pre-skip flag */
        "ldmia sp, {r0,r1,r2,r3}\n"              /* restore native args (sp not popped) */
        "tst r4, #1\n"
        "bleq compositeLayers_4_6_1_trampoline\n"/* run native 4_6_1 unless the hook returned 1 */
        "mov r4, r0\n"                           /* preserve native's return */
        "ldr r6, [r5, #" XSTR(EXP_461) "]\n"     /* reload hook (trampoline clobbered r6) */
        "ldr r0, [sp, #28]\n"
        "str r0, [r5, #" XSTR(HOOK_CALL_SITE) "]\n"  /* lr for the post call */
        "ldr r0, [sp]\n"
        "mov r1, #1\n"                           /* phase = POST (TRACE) */
        "ldr r2, [sp, #12]\n"
        "ldr r3, [sp, #4]\n"
        "mov lr, pc\n"
        "bx r6\n"                                /* hook(self,1,...) -- TRACE */
        "mov r0, r4\n"                           /* return native's r0 */
        "add sp, sp, #16\n"                      /* drop saved r0-r3 */
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"
        "1:\n"                                   /* ---- native-only path ---- */
        "ldmia sp, {r0,r1,r2,r3}\n"
        "bl compositeLayers_4_6_1_trampoline\n"
        "add sp, sp, #16\n"
        "ldmia sp!, {r4,r5,r6,lr}\n"
        "bx lr\n"
        ".L_ctx_461: .word 0x044bb2d0\n"
        ".L_cf_461:  .word 0x044bb2d8\n"
    );
}
/* @place 0x006d9f88 -- in-place splice (overwrites 4_6_1's first instruction = the stmdb the
 * trampoline displaces). `b` (not bl) so the detour inherits lr. */
__attribute__((naked)) void compositeLayers_4_6_1_splice(void){ __asm__ volatile("b compositeLayers_4_6_1_detour\n"); }
#endif /* !COV_BUILD -- end FIRMWARE HALF */

#ifdef COV_BUILD
/* ======================================================================================
 * CODE-OVERLAY HALF -- packed into mods/AERIAL.COV (compiled WITH -DCOV_BUILD). aerial_cov_init
 * (at the bottom) + the entire aerial brain. Loaded into heap by cov_load, relocated, run.
 * The block stays open through end-of-file (closed after aerial_cov_init).
 * ==================================================================================== */

/* decode_blob(blob,len,dst,stride) -- one JPEG blob -> RGB555 into dst[stride]. Hand-written
 * asm (recovered from the pkg#4 recipe; assembles byte-identical to the proven primitive) that
 * drives the firmware CJpeg decoder -- create/init/source/headers/prepare/start, then a scanline
 * loop packing R8G8B8 -> X1R5G5B5 -- via ABSOLUTE pointer calls (ldr ip,<pool>; bx ip), so it is
 * position-independent and runs correctly at any COV base. */
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

/* --- signed 32-bit divide (ported from mod004_idiv.s; restoring long division,
 * no `/` so gcc emits no recursive __aeabi_idiv call). /0 -> 0. Validated
 * against truncating division over 920 pairs (). ------------- */
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

/* KEY-5 PROBE (). Record THIS window's own key-5 surface so the host can read it.
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

/* --- HEAP BUDDY (crash-persistent DRAM probe primitive) ---------------------------------
 * A fixed high-DRAM address above the heap break that survives the HW-watchdog reset (never
 * zeroed by the heap sbrk or the bootloader). heapbuddy_arm writes a COV-authored signature
 * there; a signature still present after a crash-reboot proves the COV can write this region AND
 * that its writes survive the reset. This is the reusable PRIMITIVE only -- a future crash probe
 * writes its own words against HEAPBUDDY freshly rather than reviving a ring. Feature-neutral by
 * intent (a candidate for later promotion to firmware). ARM = a CALLED export (not a bit-poke);
 * host calls it by name via scripts/_covcall.pl, also published in x_reserved[0] for an
 * ABI-stable call (no AERIAL_ABI bump -- reserved slots exist for exactly this). */
#define HEAPBUDDY   0x07A00000u
#define CRUMB_SIG   0x48425544u                          /* 'HBUD' -- the COV-written proof-of-write */
void heapbuddy_arm(void){
    aerial_ctx_t* c=CTX; if(!c) return;                  /* booted only */
    volatile u32* hb=(volatile u32*)HEAPBUDDY;
    u32 armn=(hb[0]==CRUMB_SIG)?hb[1]+1u:1u;              /* arm-session counter */
    hb[0]=CRUMB_SIG; hb[1]=armn; }                        /* COV writes sig+arm# = proof-of-write */

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
    /* ARM the reveal re-fire for THIS fresh frame: it is a new view (we only compose on dirty), so the
     * photo is not up yet -> clear `revealed` and refill the retry budget. post_reveal + the poller
     * will post 0x67 until the 6_3_2 hook sets `revealed` (or the budget runs out). */
    s->revealed=0; s->reveal_tries=REVEAL_TRIES;
    trace_evt(c,pd_tok,TR_S_L3,0,0,0);
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
 * INDEX.RCI is retired. The workflow is "drop .RCT files on the card" -- a FILESYSTEM act -- so
 * the set must be filesystem-defined: any subset is a valid set. A manifest can only be correct
 * by discipline and fails silently both ways (present-but-unlisted is invisible;
 * listed-but-absent is skipped with no diagnostic). The RCI's bounding boxes were already dead
 * data -- every bbox is derived from the file's own blocks.
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
    c->nfiles=0; c->zmin=0; c->zmax=0;
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

/* Read one file's 128-byte header -> its zmin/zmax. 0 on failure. */
static int rct_hdr_range(void* fh,u32* zmin,u32* zmax){
    u32 got; u8 hdr[128];
    if(FX_SEEK(fh,0)) return 0;
    if(FX_READ(fh,hdr,128,&got)||got!=128) return 0;
    *zmin=hdr[0x0c]; *zmax=hdr[0x0d];
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
    /* --- pass A: the union zoom range --- */
    u32 lo=0xffffffff, hi=0;
    for(u32 f=0;f<c->nfiles;f++){ u32 a,b;
        if(!rct_hdr_range(c->fhs[f],&a,&b)) continue;
        if(a<lo) lo=a; if(b>hi) hi=b; }
    if(lo>hi) goto fail;
    c->zmin=lo; c->zmax=hi;
    u32 nz=hi-lo+1;
    c->zdir=RM_MALLOC(nz*sizeof(zoomdir_t)); if(!c->zdir) goto fail;
    mzero(c->zdir,nz*sizeof(zoomdir_t));
    for(u32 zi=0;zi<nz;zi++) c->zdir[zi].zoom=(u8)(lo+zi);
    /* --- pass B: per-zoom block counts across ALL files --- */
    for(u32 f=0;f<c->nfiles;f++){ u32 a,b;
        if(!rct_hdr_range(c->fhs[f],&a,&b)) continue;
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
    for(u32 f=0;f<c->nfiles;f++){ u32 a,b; void* fh=c->fhs[f];
        if(!rct_hdr_range(fh,&a,&b)) continue;
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
    trace_evt(c,self,TR_S_K5,1,0,0);                              /* kind5 POST = after native's blit */
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
 * race); drawOverlays-post does it on the deterministic last writer. */
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
#define FENCE_DEFAULT 100000u   /* baked cap. Measured need ~25k polls; 4x headroom. If tr_waits
                                 * ever EQUALS this the fence timed out and the band can return. */
#define CORAL_CTR   (*(volatile u32*)0xd7ff0400)
#define CTR_ENGINES 0x00000333u   /* PS bits1:0 | DS bits5:4 | SS bits9:8 -- any set = busy */
#define CTR_FE      0x00001000u   /* display list FIFO empty (1 = drained)                  */
#define CORAL_IDLE(v) ((((v) & CTR_ENGINES) == 0) && ((v) & CTR_FE))
/* Wait for the engine to go idle, bounded. Returns iterations consumed; stashes what it FOUND. */
static u32 coral_fence(aerial_ctx_t* c,u32 max){
    u32 v=CORAL_CTR; c->tr_ctr_in=v;
    u32 n=0;
    while(n<max && !CORAL_IDLE(v)){ n++; v=CORAL_CTR; }
    c->tr_waits=n;
    return n; }

/* TRACE probe: sample PROBE_N points evenly across ONE row of ONE key and pack the result as
 * (blend_mask << 16) | opaque_mask, bit i = probe point i. Deliberately a handful of loads, not a
 * scan: it rides on every hook entry and must not perturb what it measures. 0 = layer not mapped.
 * The DIFFERENCE between the band row and the control row is the signal -- either alone is noise
 * (a row that is all land or all label reads opaque legitimately). */
#define PROBE_N     16u
#define TR_BAND_ROW  2u   /* well inside the band (measured: rows 0-9 solid, row 10 transitional) */
#define TR_CTL_ROW  30u   /* well below it -- the control that says the reveal is working at all  */
static u32 probe_row(u32 self,u32 key,u32 row){
    u32 w,h,pitch; u8* px=layer_px(self,key,&w,&h,&pitch); if(!px||row>=h||!w) return 0;
    u8* r=px+row*pitch; u32 op=0,bl=0;
    for(u32 i=0;i<PROBE_N;i++){ u8 v=r[(w*i)/PROBE_N];
        if((u8)(v-0x21) < 0x0fu)      op|=1u<<i;      /* opaque fill twin */
        else if((u8)(v-0x01) < 0x0fu) bl|=1u<<i; }    /* blend fill       */
    return (bl<<16)|op;
}
/* Append one event. Cheap-exits unless CF_TRACE is armed. The CF_TRACE 0->1 edge resets the ring,
 * so arming from a band-FREE view is the whole arming protocol (arm while the band is up and the
 * trigger fires immediately on a ring with no history in it). Freezes TRACE_POST events after the
 * band first appears, and thereafter costs one load. */
static void trace_evt(aerial_ctx_t* c,u32 self,u32 site,u32 phase,u32 flags,u32 rect){
    if(!(COMPOSITE_FLAGS & CF_TRACE)){ c->tr_armed=0; return; }
    if(!c->tr_armed){                                  /* arm edge -> clean ring */
        c->tr_armed=1;
        c->tr_seq=0; c->tr_frozen=0; c->tr_band=0; c->tr_post=0; c->tr_trig=0; c->tr_drop=0;
        for(u32 i=0;i<TRACE_N*TRACE_W;i++) c->tr_ev[i]=0; }
    if(c->tr_frozen) return;
    /* sample BEFORE taking the ticket -- the lock covers tr_seq only, never the probes */
    u32 k3b=probe_row(self,3,TR_BAND_ROW), k3c=probe_row(self,3,TR_CTL_ROW);
    u32 k6b=probe_row(self,6,TR_BAND_ROW), k6c=probe_row(self,6,TR_CTL_ROW);
    u32 sp; __asm__ volatile("mov %0, sp" : "=r"(sp));
    /* BOUNDED SWP spin: ARMv4T has no ldrex, and an unbounded spin on a lock held by a preempted
     * thread would wedge the compositor. Give up after a few tries and count the drop instead. */
    u32 got=1;
    for(u32 t=0;t<64u && got;t++)
        __asm__ volatile("swp %0,%1,[%2]" : "=&r"(got) : "r"(1u), "r"(&c->tr_lock) : "memory");
    if(got){ c->tr_drop++; return; }
    u32 seq=c->tr_seq++;
    c->tr_lock=0;
    u32* e=&c->tr_ev[(seq % TRACE_N)*TRACE_W];
    e[0]=seq; e[1]=site; e[2]=phase; e[3]=c->abi.hook_call_site; e[4]=flags; e[5]=sp;
    e[6]=k3b; e[7]=k3c; e[8]=k6b; e[9]=k6c; e[10]=rect;
    if(rect){ u32* rp=(u32*)rect; e[11]=rp[0]; e[12]=rp[1]; e[13]=rp[2]; e[14]=rp[3]; }
    e[15]=c->drawing; e[16]=self; e[17]=CORAL_CTR; e[18]=c->tr_waits; e[19]=c->tr_ctr_in;
    /* TRIGGER: the key6 band row showing ANY opaque probe point when it previously showed none. */
    u32 band = (k6b & 0xffffu) ? 1u : 0u;
    if(!c->tr_trig){ if(band && !c->tr_band){ c->tr_trig=seq+1u; c->tr_post=TRACE_POST; } }
    else if(c->tr_post && --c->tr_post==0) c->tr_frozen=1;
    c->tr_band=band;
}

/* 6_3_2 phase-aware hook. func index 0. PRE (phase 0): pan-follow wake + REVEAL (key3 fills
 * remap, pre-blit). POST (phase 1): nothing structural. TRACE records both phases when armed --
 * phase 0 is native 6_3_2's ENTRY state and phase 1 its EXIT state, which is the bracket that says
 * whether the band is born inside this function. Returns 0 (6_3_2 never suppresses native). */
int compositeLayers_6_3_2_hook(u32 self, u32 phase, u32 flags, u32 update_rect){
    aerial_ctx_t* c=CTX; if(!c) return 0;
    trace_evt(c,self,TR_S_632,phase,flags,update_rect);
    if(phase!=0) return 0;                             /* REVEAL is a pre-blit op */
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
     * re-applies. The render thread never touches a PD to do this -- the old markAerialDirty/serve
     * re-apply from here was the crash. */
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
     * tr_fence to 0 to reproduce the defect. */
    build_mask(c,s,self,rc);                           /* cached: rebuilds only on a view/card change */
    if(c->tr_fence) coral_fence(c,c->tr_fence);
    reveal_masked(self,s);
    s->revealed=1;                                     /* key3 now carries our remap for this window */
    trace_evt(c,self,TR_S_REVEAL,0,flags,update_rect); /* self-account: OUR write, in the trace */
    return 0;
}

/* 4_6_1 hook: a TRACE-only site, and the only instrumented point downstream of 6_3_2 -- the far
 * end of the interval a composite investigation has to bracket. Costs one load when the recorder
 * is disarmed. Needs CF_HOOK_4_6_1 (bit24) for the detour to fire at all. */
int compositeLayers_4_6_1_hook(u32 self, u32 phase, u32 flags, u32 update_rect){
    aerial_ctx_t* c=CTX; if(!c) return 0;
    trace_evt(c,self,TR_S_461,phase,flags,update_rect);
    return 0;                                          /* never suppresses native 4_6_1 */
}

/* AO (Aerial Overlay softkey) on/off, read live from the IAppPDControlPhotoOverlay object:
 * registry 0x044c66e0 -> [+4] = controller[0] (= RC_REG[0]) -> [+0xa0] = the object -> byte
 * +0x511 (1 = on, mirror of +0xb06). Null-checks every hop; returns 1 = on, 0 = off, -1 =
 * unknown (chain not up yet). Poll-cheap (all reads). The address CHURNS per boot/window so it
 * is resolved through the chain every call, never cached. See handover-ao-state-object /
 * docs/work/soft_button_menus.md. */
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
    u32 retry=0;
    for(;;){
        RM_THREADSLEEP(150);
        aerial_ctx_t* c=CTX; if(!c || !c->ev_ok) continue;
        u32 card = CARD_READY ? 1u : 0u; int ao = ao_state();
        int sig = (card!=last_card || ao!=last_ao);             /* EDGE: an input changed */
        /* LEVEL: the inputs say we should be UP but we are not. An edge-only poller latches a
         * transient chartset_load failure forever -- CARD_READY can go true a beat before the FAT
         * is mountable, the load fails, and no further edge ever comes because last_card is
         * already 1. Meanwhile both paint hooks early-return on !active BEFORE their RL_EVSET, so
         * no view change can wake us either: active=0 becomes self-latching. Retry on a ~2s
         * backoff rather than every pass, so a card with no .RCT files does not spin the scan. */
        if(c->enabled && card && ao!=0 && !c->active){ if(++retry>=13){ retry=0; sig=1; } }
        else retry=0;
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
        int want = CARD_READY && (ao_state()!=0);              /* AO off(0) stands down; unknown(-1)=on */
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
        if(!c->active||CARD_READY!=c->card_gen){               /* (re)activate per card */
            if(c->active) chartset_teardown(c);
            c->card_gen=CARD_READY;
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

/* compositeKey5_to_L3_detour / compositeKey5_to_L3_trampoline / compositeKey5_to_L3_splice are the FIRMWARE half (see the
 * #ifndef COV_BUILD block near the top). The detour calls x_note_kind5 / x_overlay_hook
 * THROUGH the export table; the two functions below are the brain side of that handshake.
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
    trace_evt(c,self,TR_S_K5,0,0,0);                  /* kind5 PRE = before native's key5->L3 blit */
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
    /* NB the reveal re-fire is NOT here any more. It used to be a synchronous renderOverlayToSurface
     * from this hook, which corrupted the ctx (270). It now lives on the render thread as an async
     * POST_UI_MSG(0x67) after a settled compose (post_reveal) -- native repaints on its own thread and
     * re-enters THIS hook coherently to do the reveal. This hook stays what it always was: snapshot +
     * wake + suppress. */
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
/* Turn the feature on (LIGHT -- paint-path safe, so aerial_cov_init can call it during self-boot).
 * Creates the wake group and spawns the two background threads ONCE: the render thread
 * (event-driven; does the heavy lazy alloc + reconcile + compose) and the card/AO poller
 * (wakes the renderer on a card/AO change). Host-callable too (x_aerial_cov_start) for A/B toggling. */
void aerial_cov_start(void){
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

/* ---- THE COV ENTRY (packer default symbol; the header's entry_off points here) --------
 * Called once by aerial_cov_boot right after cov_load relocates the overlay into heap. Allocates
 * the ctx, PUBLISHES the export table (each &fn is an R_ARM_ABS32 the loader has already rebased to
 * its heap address), BAKES the self-start default flags, and publishes CTX. SELF-START: it
 * writes COMPOSITE_FLAGS = CF_DEFAULT (0x10000001 = GREEN|HOOK_6_3_2) BEFORE arming, so the
 * first region setup comes up with the (now unconditional) reveal armed -- no host poke, no bounce.
 * Returns (int)CTX so aerial_cov_boot can hand the host a live anchor. */
int aerial_cov_init(void){
    aerial_ctx_t* c=ctx_alloc(); if(!c) return 0;
    c->abi.x_aerial_suppress_native_L3   = (u32)(void*)&aerial_suppress_native_L3;
    c->abi.x_aerial_draw_L3              = (u32)(void*)&aerial_draw_L3;
    c->abi.x_aerial_cov_start            = (u32)(void*)&aerial_cov_start;
    c->abi.x_aerial_deactivate_region    = (u32)(void*)&aerial_deactivate_region;
    c->abi.x_compositeLayers_6_3_2_hook  = (u32)(void*)&compositeLayers_6_3_2_hook;
    c->abi.x_drawOverlays_hook           = 0;            /* null: the detour falls through to native */
    c->abi.x_compositeLayers_4_6_1_hook  = (u32)(void*)&compositeLayers_4_6_1_hook;
    /* Published INTERIOR POINTERS -- the host reads these instead of hardcoding ctx offsets. */
    c->abi.x_trace_block                 = (u32)(void*)&c->tr_lock;
    c->abi.x_win_slots                   = (u32)(void*)&c->win[0];
    c->abi.x_reserved[0]                 = (u32)(void*)&heapbuddy_arm;      /* heap-buddy arm (called) */
    /* abi_version LAST of the contract fields: a host that sees a nonzero version knows the rest
     * of the table is already populated, so there is no partially-published window to read. */
    c->abi.abi_version                   = AERIAL_ABI;
    c->tr_fence = FENCE_DEFAULT;                         /* the Coral fence is FEATURE, not a knob */
    c->mask_z   = MASK_Z;                                /* reveal-contour level; poke to sweep it */
    COMPOSITE_FLAGS = CF_DEFAULT;                        /* SELF-START: arm the proven reveal at boot */
    aerial_cov_start();                                  /* auto-arm + spawn the render thread
                                                          * (light; heavy alloc is lazy in the thread)
                                                          * -> functional from boot, no host call */
    return (int)(u32)c;
}
#endif /* COV_BUILD -- end CODE-OVERLAY HALF */
