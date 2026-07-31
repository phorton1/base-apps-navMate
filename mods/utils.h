/* This code is licensed under the MIT License -- see LICENSE.TXT in this directory. */
/* ============================================================================
 * utils.h -- UTILS.COE's contract: an on-glass output surface, as a LIBRARY COE.
 * Include it from a consumer COE (aerial) to draw text and rectangles on the
 * E-Series screen without hardcoding an address, a vtable index, or a display
 * register.
 *
 * WHAT IT IS. UTILS.COE owns one spare hardware display plane (L5), allocates it
 * full-screen ONCE at init, clears it to a color key -- which makes the whole plane
 * transparent -- and leaves it up for the life of the unit. Content appears because a
 * client WRITES pixels and disappears because something writes the key back. There is
 * no lifecycle to call: no open, no claim, no show. Public description in
 * docs/public/deployment/utils.md.
 *
 * THE GUARDED CALL. The wrappers below bake utils' fixed .bss slot address and a vtable
 * INDEX at compile time and resolve slot -> ctx -> vt[index] at RUNTIME, firing ONLY
 * when utils' slot has reached RUNNING. When UTILS.COE is absent (renamed *.cot), or
 * present but unable to take the plane, every wrapper is a cheap no-op -- so a consumer
 * builds and runs identically with or without it. That equivalence is the whole point:
 * a broken or missing output surface can never take a navigation display down with it.
 *
 * COORDINATES are screen-absolute and every draw is clipped by the library, so an
 * off-screen rectangle is harmless rather than a corruption.
 *
 * SHARING is last-writer-wins by convention. There is one plane and one buffer;
 * collisions are between overlapping RECTANGLES, and nothing arbitrates.
 *
 * TARGET: ARM920T (ARMv4T), ARM state, LE.
 * ============================================================================ */
#ifndef UTILS_H
#define UTILS_H

#include "coe_common.h"    /* coe_slot_t + the STATE enum (COE_RUNNING); brings u8/u32 */

/* --- utils' 12-byte .bss contract slot: D2[2] (LL=0, hbuddy=1, aerial=4; codespace.md) */
#define UTILS_SLOT_ADDR    0x044bb2e8u     /* D2_BASE 0x044bb2d0 + slot 2 * 12 */

/* --- FLAG BITS in slot.flags above the STATE byte. Poke-able live from the host, which
 * is the point: neither needs a rebuild, a reload, or a reboot to take effect. */
#define UTILS_F_PANIC      0x00000100u     /* thread blanks the WHOLE surface, drops every
                                            * pending erase, then clears this bit itself.
                                            * The escape hatch: L5 floats above L0, which
                                            * carries the databar, the soft keys AND the
                                            * alarm/MOB dialogs, so a buggy client must
                                            * always be clearable without a reboot. */
#define UTILS_F_MUTE       0x00000200u     /* while set, text/fill draw nothing (erase still
                                            * runs, so muting cannot strand pixels) */

/* --- color. Pixels are RGB555 (X1R5G5B5): 0RRRRRGGGGGBBBBB, bit15 unused for display.
 * Transparency is not a flag or an alpha channel -- it is ONE reserved pixel value that
 * the plane's color key compares against, and utils reserves magenta for it.
 *
 * [emp] the comparison is TIGHT on all three channels, each proven by a color differing
 * from the key in exactly one of them and staying opaque: red (0x001f), blue (0x7c00),
 * green (0x7fff / white). So every color except the key itself is safe to draw --
 * INCLUDING BLACK, which is an ordinary opaque color here. (Black is transparent only if
 * the key register's bit31 is set, which utils deliberately leaves clear; that bit and the
 * trap it sets are documented in e569.h at GDC2_COLORKEY_BLACK_TOO.)
 *
 * A caller that genuinely wants magenta can use 0x7c1e, which is indistinguishable. */
#define UTILS_TRANSPARENT  0x7c1fu                        /* magenta -- the color key */
#define UTILS_RGB(r,g,b)   ((uint16_t)((((r)&0xf8)<<7)|(((g)&0xf8)<<2)|((b)>>3)))
#define UTILS_BLACK        0x0000u
#define UTILS_WHITE        0x7fffu

/* --- font selectors. An enum, not a point size, so the mapping can be re-pointed
 * without touching a caller. Order must match UF_TABLE[] in utils_fonts.h. */
enum { UF_SMALL = 0, UF_SMALL_B,     /* Arial 8  / 8 Bold  */
       UF_NORM,      UF_NORM_B,      /* Arial 10 / 10 Bold */
       UF_BIG,       UF_BIG_B,       /* Arial 12 / 12 Bold */
       UF_MONO,      UF_MONO_B,      /* Courier 8 / 8 Bold */
       UF_NFONTS };

/* --- the library's hard ceiling on a dwell, applied to utils_erase() regardless of what
 * the caller asks for. No client may strand pixels on a navigation display. */
#define UTILS_MAX_DWELL_MS 30000u

/* --- the published export table (at utils ctx+0), indexed by the wrappers ---------- */
enum { UT_VT_EXTENT = 0, UT_VT_LINE_SPACE, UT_VT_TEXT, UT_VT_FILL, UT_VT_ERASE, UT_VT_N };
typedef struct {
    u32 abi_version;       /* +0  == UTILS_ABI; 0 until published (a free "not up" test) */
    u32 vt[UT_VT_N];       /* +4  export function pointers (relocated to heap by the LL)  */
} utils_export_t;

/* --- the guarded wrappers a consumer COE calls. Each is a no-op (or a 0) unless utils'
 * slot has reached RUNNING -- absent, still loading, or failed to take the plane all
 * reach the SAME quiet branch. `static` -> the linker drops any a consumer does not
 * call. The indirect call compiles to `mov lr,pc; bx` under -mcpu=arm920t (no blx), so
 * these are safe from ordinary C. --- */
#ifndef UTILS_BUILD    /* UTILS.COE itself defines this and IMPLEMENTS the exports instead */

#define UTILS_UP() (((((volatile coe_slot_t*)UTILS_SLOT_ADDR)->flags) & 0xffu) == COE_RUNNING \
                    && ((volatile coe_slot_t*)UTILS_SLOT_ADDR)->ctx)
#define UTILS_VT(i) ((utils_export_t*)((volatile coe_slot_t*)UTILS_SLOT_ADDR)->ctx)->vt[i]

/* Is the surface up? Only for a caller that wants to DEFER work until it is (e.g. hold a
 * one-shot banner until the plane exists). Never needed to make a call safe. */
static int utils_ready(void){ return UTILS_UP() ? 1 : 0; }

/* Width of `s` in pixels, without drawing it. 0 when utils is absent -- so a caller that
 * centers on this simply centers nothing, which is what it wanted anyway. */
static int utils_extent(u8 font,const char* s){
    if(!UTILS_UP()) return 0;
    return ((int(*)(u8,const char*))UTILS_VT(UT_VT_EXTENT))(font,s); }

/* Baseline-to-baseline pitch for `font`, in pixels -- the other half of measurement, and
 * what keeps a caller from hardcoding a metric the selector is allowed to re-point. */
static int utils_line_space(u8 font){
    if(!UTILS_UP()) return 0;
    return ((int(*)(u8))UTILS_VT(UT_VT_LINE_SPACE))(font); }

/* Draw `s` at (x,y) -- y is the TOP of the cap box, not a baseline. Returns the advance
 * in pixels (0 when absent), so a caller can chain runs of different fonts or colors. */
static int utils_text(int x,int y,u8 font,uint16_t color,const char* s){
    if(!UTILS_UP()) return 0;
    return ((int(*)(int,int,u8,uint16_t,const char*))UTILS_VT(UT_VT_TEXT))(x,y,font,color,s); }

/* Fill a rectangle. Pass UTILS_TRANSPARENT to punch a hole back to the chart. */
static void utils_fill(int x,int y,int w,int h,uint16_t color){
    if(!UTILS_UP()) return;
    ((void(*)(int,int,int,int,uint16_t))UTILS_VT(UT_VT_FILL))(x,y,w,h,color); }

/* Erase a rectangle back to the color key. ms == 0 erases NOW; otherwise the library's
 * own thread erases it when the dwell expires (clamped to UTILS_MAX_DWELL_MS), so a
 * transient banner takes itself down without the client staying alive to do it. A
 * long-lived readout simply never calls this. */
static void utils_erase(int x,int y,int w,int h,u32 ms){
    if(!UTILS_UP()) return;
    ((void(*)(int,int,int,int,u32))UTILS_VT(UT_VT_ERASE))(x,y,w,h,ms); }

#endif /* !UTILS_BUILD */

#endif /* UTILS_H */
