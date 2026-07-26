/* This code is licensed under the MIT License -- see LICENSE.TXT in this directory. */
/* ============================================================================
 * hbuddy.h -- HBUDDY.COE's contract: crash-persistent DRAM diagnostics, as a
 * LIBRARY COE. Include it from a consumer COE (aerial) to reach hbuddy without
 * hardcoding an address or a vtable index.
 *
 * HBUDDY owns a fixed 4 KB block of high heap wilderness (0x07A00000) that survives
 * the HW-watchdog reset (see dram_survives_reboot). Over it it publishes three
 * diagnostics: an ARM proof-of-write word, a STAGE bitmask (breadcrumbs), and a
 * crash-persistent EVENT RING -- all readable raw over the wire live OR after a reset.
 *
 * THE GUARDED CALL. The wrappers below bake hbuddy's fixed .bss slot address and a
 * vtable INDEX at compile time and resolve slot -> ctx -> vt[index] at RUNTIME, firing
 * ONLY when hbuddy's slot has reached RUNNING. When HBUDDY.COE is absent (renamed
 * *.off) or not yet up, every wrapper is a cheap no-op -- so a consumer builds and runs
 * identically with or without it. That equivalence IS the drop-in test.
 *
 * The DRAM region layout is documented here so a host reader can find and unpack the
 * block after a reset with no live COE. TARGET: ARM920T (ARMv4T), ARM state, LE.
 * ============================================================================ */
#ifndef HBUDDY_H
#define HBUDDY_H

#include "coe_common.h"    /* coe_slot_t + the STATE enum (COE_RUNNING); brings u8/u32 */

/* --- hbuddy's 12-byte .bss contract slot: D2[1] (LL=slot0, aerial=slot4; codespace.md) */
#define HBUDDY_SLOT_ADDR   0x044bb2dcu     /* D2_BASE 0x044bb2d0 + slot 1 * 12 */

/* --- the crash-persistent DRAM region ---------------------------------------------
 * A fixed block in high heap wilderness, above where the break realistically grows and
 * never zeroed by sbrk or the bootloader (dram_survives_reboot). hbuddy owns 4 KB here;
 * mod005's own firmware crumbs live in a DISJOINT block at 0x07A10000, 64 KB clear. An
 * 8-word header then a ring of fixed-width records; the host unpacks it raw. */
#define HBUDDY_REGION      0x07A00000u
#define HBUDDY_REGION_LEN  0x1000u         /* 4 KB */
#define HBUDDY_SIG         0x48425544u     /* 'HBUD' -- the COE-written proof-of-write */
#define HB_REC_WORDS       8u              /* one ring record = {seq, tag, p0..p5} */

/* region header, offsets in WORDS from HBUDDY_REGION: */
#define HB_H_SIG     0u    /* 'HBUD' once armed                                  */
#define HB_H_ARM     1u    /* arm-session counter (rises each boot; survives)    */
#define HB_H_STAGE   2u    /* stage bitmask -- hbuddy_stage ORs bits             */
#define HB_H_SEQ     3u    /* ring write cursor = total records ever appended    */
#define HB_H_WIDX    4u    /* ring slot index 0..cap-1, advanced incrementally   */
#define HB_H_CAP     5u    /* ring capacity in records                           */
#define HB_H_RW      6u    /* record width in words (= HB_REC_WORDS)             */
#define HB_H_FROZEN  7u    /* 1 = ring stopped appending (a snapshot was frozen) */
#define HB_H_LOCK    8u    /* bounded-SWP append lock (cleared at every arm)     */
#define HB_HDR_WORDS 9u
/* cap = whole records that fit after the header. The slot index is kept in HB_H_WIDX and
 * wrapped by compare (NOT `seq % cap`), so cap need not be a power of two -- a modulo by a
 * non-power-of-two constant pulls in __aeabi_uidivmod, which a COE has no runtime for. */
#define HB_RING_CAP  ((HBUDDY_REGION_LEN/4u - HB_HDR_WORDS) / HB_REC_WORDS)   /* 126 */

/* --- the published export table (at hbuddy ctx+0), indexed by the wrappers -------- */
enum { HB_VT_ARM = 0, HB_VT_STAGE, HB_VT_LOG, HB_VT_RESET, HB_VT_FREEZE, HB_VT_N };
typedef struct {
    u32 abi_version;       /* +0  == HBUDDY_ABI; 0 until published (a free "not up" test) */
    u32 vt[HB_VT_N];       /* +4  export function pointers (relocated to heap by the LL)  */
} hbuddy_export_t;

/* --- the guarded wrappers a consumer COE calls. Each is a no-op unless hbuddy's slot
 * has reached RUNNING (absent / not-up => the SAME quiet branch, free). `static` -> the
 * linker drops any a consumer does not call. The indirect call compiles to
 * `mov lr,pc; bx` under -mcpu=arm920t (no blx), so these are safe from ordinary C. --- */
#ifndef HBUDDY_BUILD    /* HBUDDY.COE itself defines this and IMPLEMENTS the exports instead */

static void hbuddy_arm(void){
    volatile coe_slot_t* sl=(volatile coe_slot_t*)HBUDDY_SLOT_ADDR;
    if((sl->flags & 0xffu)==COE_RUNNING && sl->ctx)
        ((void(*)(void))((hbuddy_export_t*)sl->ctx)->vt[HB_VT_ARM])();
}
static void hbuddy_stage(u32 bit){
    volatile coe_slot_t* sl=(volatile coe_slot_t*)HBUDDY_SLOT_ADDR;
    if((sl->flags & 0xffu)==COE_RUNNING && sl->ctx)
        ((void(*)(u32))((hbuddy_export_t*)sl->ctx)->vt[HB_VT_STAGE])(bit);
}
static void hbuddy_log(u32 tag,const u32* words,u32 n){
    volatile coe_slot_t* sl=(volatile coe_slot_t*)HBUDDY_SLOT_ADDR;
    if((sl->flags & 0xffu)==COE_RUNNING && sl->ctx)
        ((void(*)(u32,const u32*,u32))((hbuddy_export_t*)sl->ctx)->vt[HB_VT_LOG])(tag,words,n);
}
static void hbuddy_ring_reset(void){
    volatile coe_slot_t* sl=(volatile coe_slot_t*)HBUDDY_SLOT_ADDR;
    if((sl->flags & 0xffu)==COE_RUNNING && sl->ctx)
        ((void(*)(void))((hbuddy_export_t*)sl->ctx)->vt[HB_VT_RESET])();
}
static void hbuddy_ring_freeze(void){
    volatile coe_slot_t* sl=(volatile coe_slot_t*)HBUDDY_SLOT_ADDR;
    if((sl->flags & 0xffu)==COE_RUNNING && sl->ctx)
        ((void(*)(void))((hbuddy_export_t*)sl->ctx)->vt[HB_VT_FREEZE])();
}

#endif /* !HBUDDY_BUILD */

#endif /* HBUDDY_H */
