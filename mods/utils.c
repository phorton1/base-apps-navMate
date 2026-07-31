/* This code is licensed under the MIT License -- see LICENSE.TXT in this directory. */
/* ============================================================================
 * utils.c -- UTILS.COE: an on-glass output surface, as a HOOKLESS library COE.
 * AUTHORING SOURCE ONLY. _coe_build.pl packs this file into UTILS.COE; the mod005 LL
 * finds it on the CF root, loads + relocates it, sets its slot STATE=LOADED, and calls
 * coe_init. This file is never flashed.
 *
 * *** A PURE LIBRARY COE (no firmware detours) ***
 * utils installs ZERO edits into firmware .text. Like HBUDDY.COE it only PUBLISHES a
 * contract (utils.h) for other COEs to call. What it adds over hbuddy is a resource:
 * it takes one spare hardware display plane and lends it out as a place to put text
 * and rectangles on the screen.
 *
 * THE SURFACE. One plane (L5), taken ONCE at init, full-screen, 16bpp, cleared to a
 * color key so the whole thing is transparent, floated to the front and enabled -- and
 * then left alone for the life of the unit. Content appears because a client writes
 * pixels and disappears because something writes the key back. No resize, no re-enable,
 * no free. That is a safety property, not a convenience: the dangerous registers
 * (z-order, layer enable, enable shadow) are written once and never again, so there is
 * no teardown path to get wrong and no visibility toggle to fall out of step with the
 * hardware. e569.h section 11 records both traps in full.
 *
 * FAILURE IS SILENT AND TOTAL. If the plane cannot be taken, this COE never reaches
 * RUNNING, every client's guarded wrapper stays a no-op, and the host runs exactly as if
 * UTILS.COE were not on the card. A broken output surface cannot take the display down.
 *
 * WHAT IT DOES NOT DO. It knows nothing about its clients, lays nothing out (callers
 * pass rectangles and strings), reads no input, and arbitrates nothing between clients.
 * Overlapping rectangles are last-writer-wins, exactly as any shared framebuffer.
 *
 * NO LOCKS. The plane is ours: nothing in the firmware reads or writes this buffer, so
 * a client draws synchronously at call time with no mutex, no retarget of the firmware's
 * draw target, and no coordination with the UI. That is the whole reason we rasterize
 * our own glyphs instead of calling the firmware's font stack, which is PEG-thread-affine
 * and would drag the UI's lock onto every caller.
 *
 * TARGET: ARM920T (ARMv4T), ARM state, LE. No libc, no Thumb, no blx, no division.
 * ============================================================================ */
// @coe_name UTILS                  // -> UTILS.COE (the card file the mod005 LL loads)
// @base mod005                     // required by the builder; utils hashes nothing (zero @hook)
// @coe_version 2                   // COE build stamp -> header +0x1c
// @slot 2                          // utils' 12-B .bss contract slot = D2[2] @0x044bb2e8
#include <stdint.h>
#define UTILS_BUILD                  /* we IMPLEMENT the exports -> skip utils.h's consumer wrappers */
#include "coe_common.h"              /* coe_slot_t, STATE enum, COE_SET_STATE; brings u8/u32 */
#include "utils.h"                   /* the export-table shape + the color/font/flag contract */
#include "utils_fonts.h"             /* GENERATED: UF_TABLE[] + the ufont_t descriptor */
#include "e569.h"                    /* RM_MALLOC, threads, PEG_SCREEN, the plane primitives */

typedef uint16_t u16;  typedef int32_t s32;

#define UTILS_MAGIC 0x31454f43u      /* 'COE1' -- the COE file magic (_coe_build reads this *_MAGIC) */
#define UTILS_ABI   1u               /* export-table contract version (the LL does NOT gate on it) */

#ifdef COE_BUILD

#define UTILS_LAYER   5u             /* the spare hardware plane we own (see codespace.md) */
#define UT_TICK_MS    150u           /* thread period -- also the dwell quantum */
#define UT_PEND       8u             /* pending timed erases; full -> erase immediately */
#define UT_ENABLE_BIT (1u << (16u + UTILS_LAYER))   /* [emp] GDC2 enable reg: layer N = bit 16+N */

/* The one heap object. utils_export_t MUST sit at +0 -- a client's guarded wrapper casts
 * slot->ctx straight to it. Everything after is COE-private. */
typedef struct {
    utils_export_t xp;               /* +0 -- THE PUBLISHED CONTRACT */
    void* screen;                    /* the PegCoralScreen singleton */
    u16*  buf;                       /* our plane's VRAM bitmap (CPU-addressable) */
    u32   pitch;                     /* row pitch in PIXELS (>= w; bindLayerBitmap rounds up) */
    s32   w, h;                      /* surface size = panel size */
    u32   up;                        /* 1 = the plane is live and buf/pitch are valid */
    void* tcb;                        /* our low-rate thread's control block */
    struct { s32 x,y,w,h; u32 ms; u32 used; } pend[UT_PEND];
} utils_ctx_t;

#define USLOT ((volatile coe_slot_t*)UTILS_SLOT_ADDR)
#define UCTX  (*(utils_ctx_t* volatile*)UTILS_SLOT_ADDR)   /* slot.ctx == the ctx anchor */

static void mzero(void* p,u32 n){ u8* d=p; while(n--)*d++=0; }

/* ====================================================================
 * The surface -- clipped raw writes into a buffer nothing else touches.
 * ==================================================================== */

/* Fill a rectangle, clipped to the surface. The ONE place clipping happens for
 * rectangles, so an out-of-range request from any client is harmless rather than a
 * write into whatever VRAM follows ours. */
static void ufill(utils_ctx_t* c,s32 x,s32 y,s32 w,s32 h,u16 col){
    if(!c->up || w<=0 || h<=0) return;
    if(x<0){ w+=x; x=0; }
    if(y<0){ h+=y; y=0; }
    if(x>=c->w || y>=c->h) return;
    if(x+w > c->w) w = c->w - x;
    if(y+h > c->h) h = c->h - y;
    if(w<=0 || h<=0) return;
    for(s32 r=0;r<h;r++){
        u16* p = c->buf + (u32)(y+r)*c->pitch + (u32)x;
        for(s32 i=0;i<w;i++) p[i]=col; } }

/* One pixel, clipped. Per-pixel clipping (rather than clipping the glyph box once) is
 * what makes a partially off-screen string draw its visible part instead of vanishing. */
static void upix(utils_ctx_t* c,s32 x,s32 y,u16 col){
    if(x<0||y<0||x>=c->w||y>=c->h) return;
    c->buf[(u32)y*c->pitch+(u32)x]=col; }

/* ====================================================================
 * The glyph decoder -- ILI9341_t3 packed bitmap format, version 1.
 * The format is documented at the head of the generated utils_fonts.h.
 * All bitstreams are MSB-first.
 * ==================================================================== */

static u32 fetchbit(const u8* p,u32 i){ return (u32)((p[i>>3] >> (7u-(i&7u))) & 1u); }

static u32 fetchbits_u(const u8* p,u32 idx,u32 req){
    u32 val=0;
    while(req){
        u32 b = p[idx>>3];
        u32 avail = 8u - (idx & 7u);
        if(avail <= req){ val = (val<<avail) | (b & ((1u<<avail)-1u)); idx += avail; req -= avail; }
        else            { b >>= (avail-req); val = (val<<req) | (b & ((1u<<req)-1u)); break; } }
    return val; }

static s32 fetchbits_s(const u8* p,u32 idx,u32 req){
    u32 v = fetchbits_u(p,idx,req);
    return (v & (1u<<(req-1u))) ? (s32)v - (s32)(1u<<req) : (s32)v; }

/* Decode one character. `plot` 0 = MEASURE ONLY (used by utils_extent, so measurement
 * and drawing can never disagree -- they are the same code path). Returns the advance.
 *
 * (cx,cy) is the top-left of the CAP BOX, not a baseline: the caller thinks in terms of
 * "put this line here", and the per-glyph yoffset then places each glyph within it. */
static int uf_draw(utils_ctx_t* c,const ufont_t* f,u8 ch,s32 cx,s32 cy,u16 col,int plot){
    if(ch < f->index1_first || ch > f->index1_last) return 0;
    u32 bo   = (u32)(ch - f->index1_first) * f->bits_index;
    u32 goff = fetchbits_u(f->index, bo, f->bits_index);
    const u8* d = f->data + goff;
    u32 bi = 0;
    if(fetchbits_u(d,bi,3) != 0) return 0;              /* encoding != 0 -> not a v1 glyph */
    bi = 3;
    u32 gw = fetchbits_u(d,bi,f->bits_width);    bi += f->bits_width;
    u32 gh = fetchbits_u(d,bi,f->bits_height);   bi += f->bits_height;
    s32 xo = fetchbits_s(d,bi,f->bits_xoffset);  bi += f->bits_xoffset;
    s32 yo = fetchbits_s(d,bi,f->bits_yoffset);  bi += f->bits_yoffset;
    u32 dl = fetchbits_u(d,bi,f->bits_delta);    bi += f->bits_delta;
    if(!plot) return (int)dl;                           /* measuring: the advance is all we need */
    s32 ox = cx + xo;
    s32 oy = cy + (s32)f->cap_height - (s32)gh - yo;
    u32 y = 0;
    while(y < gh){
        u32 rep = 1u;                                   /* row-repeat run: 1 bit, then 3 bits + 2 */
        if(fetchbit(d,bi++)){ rep = fetchbits_u(d,bi,3) + 2u; bi += 3u; }
        u32 x = 0;
        while(x < gw){
            u32 xs = gw - x; if(xs > 32u) xs = 32u;
            u32 bits = fetchbits_u(d,bi,xs); bi += xs;
            for(u32 k=0;k<xs;k++){
                if(!((bits >> (xs-1u-k)) & 1u)) continue;   /* MSB = leftmost pixel */
                for(u32 r=0;r<rep;r++) upix(c, ox+(s32)(x+k), oy+(s32)(y+r), col); }
            x += xs; }
        y += rep; }
    return (int)dl; }

/* ====================================================================
 * THE EXPORTS -- what utils.h's guarded wrappers reach.
 * Every one re-reads the ctx from the slot and tolerates a null: a client's guard has
 * already checked RUNNING, but these are function pointers a host can also poke.
 * ==================================================================== */

static int ut_extent(u8 font,const char* s){
    utils_ctx_t* c=UCTX; if(!c || font>=UF_NFONTS || !s) return 0;
    const ufont_t* f=&UF_TABLE[font];
    int w=0; while(*s) w += uf_draw(c,f,(u8)*s++,0,0,0,0);
    return w; }

static int ut_line_space(u8 font){
    if(font>=UF_NFONTS) return 0;
    return (int)UF_TABLE[font].line_space; }

static int ut_text(int x,int y,u8 font,u16 color,const char* s){
    utils_ctx_t* c=UCTX; if(!c || !c->up || font>=UF_NFONTS || !s) return 0;
    if(USLOT->flags & UTILS_F_MUTE) return 0;
    const ufont_t* f=&UF_TABLE[font];
    s32 cx=(s32)x; int adv=0;
    while(*s){ int a = uf_draw(c,f,(u8)*s++,cx,(s32)y,color,1); cx += a; adv += a; }
    return adv; }

static void ut_fill(int x,int y,int w,int h,u16 color){
    utils_ctx_t* c=UCTX; if(!c) return;
    if(USLOT->flags & UTILS_F_MUTE) return;
    ufill(c,(s32)x,(s32)y,(s32)w,(s32)h,color); }

/* Erase back to the key. ms == 0 does it now; otherwise the rectangle is handed to our
 * thread with a dwell CLAMPED to the library's hard maximum, because no client may
 * strand pixels on a navigation display. If every pending slot is taken we erase
 * IMMEDIATELY rather than drop the request -- failing toward a clean plane. Note this
 * ignores UTILS_F_MUTE by design: muting must never be able to leave content up. */
static void ut_erase(int x,int y,int w,int h,u32 ms){
    utils_ctx_t* c=UCTX; if(!c) return;
    if(ms){
        if(ms > UTILS_MAX_DWELL_MS) ms = UTILS_MAX_DWELL_MS;
        for(u32 i=0;i<UT_PEND;i++)
            if(!c->pend[i].used){
                c->pend[i].x=(s32)x; c->pend[i].y=(s32)y;
                c->pend[i].w=(s32)w; c->pend[i].h=(s32)h;
                c->pend[i].ms=ms; c->pend[i].used=1; return; } }
    ufill(c,(s32)x,(s32)y,(s32)w,(s32)h,UTILS_TRANSPARENT); }

/* ====================================================================
 * Taking the plane.
 * ==================================================================== */

/* Program L5 through the FIRMWARE'S OWN path and make it ours. Returns 1 on success.
 *
 * bindLayerBitmap is not optional: poking the plane registers instead leaves the
 * geometry unlatched and the plane scans horizontally rotated with a stray line across
 * the top -- with byte-identical register values, so only the FIFO latch differs. That
 * is invisible with a symmetric test pattern and glaring with text (e569.h section 11).
 *
 * Order matters: clear the fresh VRAM to the key and arm the key BEFORE enabling the
 * plane, so nothing whatever appears on the glass between "allocated" and "transparent".
 * A newly allocated block holds whatever its last owner left in it. */
static int plane_up(utils_ctx_t* c){
    void* scr = PEG_SCREEN();
    if(!scr) return 0;
    s32 w=(s32)SCR_W(), h=(s32)SCR_H();
    if(w<64 || w>2048 || h<64 || h>2048) return 0;              /* CRTC not up / insane -> retry */
    if(!BIND_LAYER_BITMAP(scr,UTILS_LAYER,(u32)w,(u32)h,0,0,16,UTILS_TRANSPARENT)) return 0;
    u8* d = LAYER_DESC(scr,UTILS_LAYER);
    u16* buf  = *(u16* volatile*)(d + LDESC_BITMAP);
    u32  pitch = *(volatile u32*)(d + LDESC_PITCH);
    /* Refuse rather than write somewhere random: the bitmap must be in the VRAM aperture
     * and the pitch must actually cover a row. A bad descriptor is the one failure that
     * would otherwise scribble over another plane's buffer. */
    if(!buf || (u32)buf < 0xd6000000u || (u32)buf >= 0xda000000u || pitch < (u32)w) return 0;
    c->screen=scr; c->buf=buf; c->pitch=pitch; c->w=w; c->h=h; c->up=1;
    ufill(c,0,0,w,h,UTILS_TRANSPARENT);                          /* the whole plane -> transparent */
    /* The key colour ALONE -- bit31 stays CLEAR. Keying works without it (measured: the key
     * colour goes transparent either way); what bit31 adds is BLACK as a second transparent
     * value, which silently discards black TEXT while leaving fills untouched. It is the one
     * bit that can make a correct buffer render as corruption. See e569.h section 11. */
    GDC2_COLORKEY_REG(UTILS_LAYER) = UTILS_TRANSPARENT;
    GDC2_ZORDER_REG = GDC2_ZORDER_L5_TOP;                        /* single-writer: this sticks */
    SET_LAYER_VISIBLE(scr,UTILS_LAYER,1);
    return 1; }

/* Self-heal the plane's enable if a display reconfigure cleared it. setLayerVisible is
 * EDGE-TRIGGERED on the descriptor's own shadow, so it silently no-ops exactly when the
 * descriptor and the hardware have fallen out of step -- clear the shadow first to re-arm
 * the edge, then call it, so the RAM enable shadow the firmware rebuilds from stays
 * correct too. */
static void plane_reassert(utils_ctx_t* c){
    if(GDC2_ENABLE_REG & UT_ENABLE_BIT) return;
    u8* d = LAYER_DESC(c->screen,UTILS_LAYER);
    *(volatile u32*)(d + LDESC_VISIBLE) = 0;
    SET_LAYER_VISIBLE(c->screen,UTILS_LAYER,1);
    if(GDC2_ZORDER_REG != GDC2_ZORDER_L5_TOP) GDC2_ZORDER_REG = GDC2_ZORDER_L5_TOP; }

/* ====================================================================
 * The resident thread -- low rate, and deliberately dumb.
 * It NEVER renders: clients draw synchronously at call time, so a caller pays no
 * latency for this thread to exist. It exists so that "transient content always comes
 * back down" is a property of the library rather than a promise borrowed from whoever
 * called it, and so a panic clear is reachable without a reboot.
 * ==================================================================== */
void utils_thread(void){
    for(;;){
        RM_THREADSLEEP(UT_TICK_MS);
        utils_ctx_t* c=UCTX; if(!c) continue;
        if(!c->up){
            /* The plane was not available at init. Keep trying: we only reach RUNNING --
             * and clients' guards only open -- once there is somewhere to draw. */
            if(plane_up(c)) COE_SET_STATE((coe_slot_t*)UTILS_SLOT_ADDR, COE_RUNNING);
            continue; }
        if(USLOT->flags & UTILS_F_PANIC){
            /* The escape hatch. L5 floats above L0, which carries the databar, the soft
             * keys AND the alarm and MOB dialogs, so a client that sits on top of an
             * alarm has to be clearable from the host without a reboot. */
            for(u32 i=0;i<UT_PEND;i++) c->pend[i].used=0;
            ufill(c,0,0,c->w,c->h,UTILS_TRANSPARENT);
            USLOT->flags &= ~UTILS_F_PANIC; }
        for(u32 i=0;i<UT_PEND;i++){
            if(!c->pend[i].used) continue;
            if(c->pend[i].ms > UT_TICK_MS){ c->pend[i].ms -= UT_TICK_MS; continue; }
            ufill(c,c->pend[i].x,c->pend[i].y,c->pend[i].w,c->pend[i].h,UTILS_TRANSPARENT);
            c->pend[i].used=0; }
        plane_reassert(c); } }

/* ---- THE COE ENTRY (the header's entry_off points here; the LL calls it after applying
 * this COE's edit table, which is empty). Allocates the ctx, takes the plane, fills the
 * export vtable (each &fn is an R_ARM_ABS32 the LL rebased to heap), spawns the resident
 * thread, publishes the ctx pointer, and -- ONLY if the plane is actually ours -- drives
 * STATE to RUNNING so clients' guards open. If the plane could not be taken we still
 * publish and spawn, leaving the thread to retry; the COE simply stays below RUNNING and
 * every client keeps no-opping in the meantime. */
int coe_init(void){
    utils_ctx_t* c = RM_MALLOC(sizeof(utils_ctx_t));
    if(!c) return 0;
    mzero(c,sizeof(utils_ctx_t));                       /* no libc */
    COE_SET_STATE((coe_slot_t*)UTILS_SLOT_ADDR, COE_INITED);    /* 1 (LOADED) -> 2 (starting) */
    int ok = plane_up(c);
    c->xp.vt[UT_VT_EXTENT]     = (u32)(void*)&ut_extent;
    c->xp.vt[UT_VT_LINE_SPACE] = (u32)(void*)&ut_line_space;
    c->xp.vt[UT_VT_TEXT]       = (u32)(void*)&ut_text;
    c->xp.vt[UT_VT_FILL]       = (u32)(void*)&ut_fill;
    c->xp.vt[UT_VT_ERASE]      = (u32)(void*)&ut_erase;
    c->xp.abi_version          = UTILS_ABI;             /* published last (table now complete) */
    c->tcb = RM_MALLOC(0x104);                          /* TX_THREAD control block */
    if(c->tcb)                                          /* prio arg 0 -> ThreadX 31, the LOWEST:
                                                         * expiring a dwell must never preempt the UI */
        RM_THREADCREATE((void*)utils_thread,0,0x1000,0,c->tcb,THREAD_NAME,0x220);
    UCTX = c;                                           /* publish ctx BEFORE RUNNING */
    if(ok) COE_SET_STATE((coe_slot_t*)UTILS_SLOT_ADDR, COE_RUNNING);  /* guarded callers fire */
    return (int)(u32)c; }

#endif /* COE_BUILD */
