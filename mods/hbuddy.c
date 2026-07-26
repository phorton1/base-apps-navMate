/* This code is licensed under the MIT License -- see LICENSE.TXT in this directory. */
/* ============================================================================
 * hbuddy.c -- HBUDDY.COE: crash-persistent DRAM diagnostics, as a HOOKLESS library COE.
 * AUTHORING SOURCE ONLY. _coe_build.pl packs this file into HBUDDY.COE; the mod005 LL
 * finds it on the CF root, loads + relocates it, sets its slot STATE=LOADED, and calls
 * coe_init. This file is never flashed.
 *
 * *** A PURE LIBRARY COE (no firmware detours) ***
 * hbuddy installs ZERO edits into firmware .text -- it is the first COE that only
 * PUBLISHES a contract (hbuddy.h) for other COEs to call. coe_init allocates a small
 * heap ctx, fills the export vtable, ARMS the DRAM region, publishes the ctx pointer,
 * and drives STATE to RUNNING; from then a consumer's guarded wrappers (hbuddy.h) fire.
 * When HBUDDY.COE is absent (renamed *.off) those wrappers no-op, so a consumer runs
 * unchanged -- the drop-in test this COE exists to prove.
 *
 * THE REGION (hbuddy.h): a fixed 4 KB block of high heap wilderness (0x07A00000) that
 * survives the HW-watchdog reset (dram_survives_reboot). Header {sig, arm#, stage,
 * seq, cap, rw, frozen, lock} then a ring of HB_REC_WORDS-word records. The ring is
 * PRESERVED across a reboot (coe_init does NOT clear it on a warm boot) so a crash trail
 * written just before a reset is still there to read afterward. A consumer clears it
 * explicitly (hbuddy_ring_reset) when it wants a fresh capture.
 *
 * TARGET: ARM920T (ARMv4T), ARM state, LE. No libc, no Thumb, no blx.
 * ============================================================================ */
// @coe_name HBUDDY                 // -> HBUDDY.COE (the card file the mod005 LL loads)
// @base mod005                     // required by the builder; hbuddy hashes nothing (zero @hook)
// @coe_version 1                   // COE build stamp -> header +0x1c
// @slot 1                          // hbuddy's 12-B .bss contract slot = D2[1] @0x044bb2dc
#include <stdint.h>
#define HBUDDY_BUILD                 /* we IMPLEMENT the exports -> skip hbuddy.h's consumer wrappers */
#include "coe_common.h"              /* coe_slot_t, STATE enum, COE_SET_STATE; brings u8/u32 */
#include "hbuddy.h"                  /* the region layout + export-table shape we publish */
#include "e569.h"                    /* RM_MALLOC */

#define HBUDDY_MAGIC 0x31454f43u     /* 'COE1' -- the COE file magic (_coe_build reads this *_MAGIC) */
#define HBUDDY_ABI   1u              /* export-table contract version (the LL does NOT gate on it) */

#ifdef COE_BUILD

#define HB_REG ((volatile u32*)HBUDDY_REGION)

static void hb_ring_zero(volatile u32* r){
    for(u32 i=0;i<HB_RING_CAP*HB_REC_WORDS;i++) r[HB_HDR_WORDS+i]=0;
}

/* ARM: prove a COE write + ensure the header is valid. The ring is PRESERVED on a warm
 * boot (sig already present) so a pre-crash trail survives to be read; it is zeroed only
 * on the very first cold use. The append lock is ALWAYS cleared -- a crash mid-hold must
 * not wedge logging after the reboot. cap/rw are (re)stamped idempotently. */
static void hb_arm(void){
    volatile u32* r=HB_REG;
    if(r[HB_H_SIG]==HBUDDY_SIG){
        r[HB_H_ARM]+=1u;                                 /* warm: keep stage/seq/frozen/ring */
    }else{
        r[HB_H_SIG]=HBUDDY_SIG; r[HB_H_ARM]=1u;          /* cold: first ever -- full init */
        r[HB_H_STAGE]=0; r[HB_H_SEQ]=0; r[HB_H_WIDX]=0; r[HB_H_FROZEN]=0;
        hb_ring_zero(r);
    }
    r[HB_H_CAP]=HB_RING_CAP; r[HB_H_RW]=HB_REC_WORDS; r[HB_H_LOCK]=0;
}

/* STAGE: OR a bit into the breadcrumb mask (replaces aerial's old COE_CRUMB_BIT). */
static void hb_stage(u32 bit){ HB_REG[HB_H_STAGE] |= bit; }

/* LOG: append one record {seq, tag, up to HB_REC_WORDS-2 payload words}. A bounded SWP
 * spin claims the sequence ticket (ARMv4T has no ldrex); on contention the event is
 * dropped rather than wedge a caller. Frozen -> no-op. The ticket is the total order. */
static void hb_log(u32 tag,const u32* w,u32 n){
    volatile u32* r=HB_REG;
    if(r[HB_H_FROZEN]) return;
    u32 got=1;
    for(u32 t=0;t<64u && got;t++)
        __asm__ volatile("swp %0,%1,[%2]":"=&r"(got):"r"(1u),"r"(&r[HB_H_LOCK]):"memory");
    if(got) return;                                      /* contended -> drop (best-effort) */
    u32 seq=r[HB_H_SEQ]; u32 idx=r[HB_H_WIDX];
    r[HB_H_SEQ]=seq+1u;
    { u32 ni=idx+1u; r[HB_H_WIDX]=(ni>=HB_RING_CAP)?0u:ni; } /* wrap by compare -- no modulo */
    r[HB_H_LOCK]=0;
    volatile u32* e=r+HB_HDR_WORDS+idx*HB_REC_WORDS;      /* idx*8 -> shift, no division */
    e[0]=seq; e[1]=tag;
    u32 m=HB_REC_WORDS-2u;
    for(u32 i=0;i<m;i++) e[2+i]=(i<n && w)?w[i]:0u;
}

/* RESET: start a fresh capture -- clear the ring cursor, the frozen latch, the lock, and
 * zero the records. Leaves the stage mask and arm# alone (their own lifecycles). */
static void hb_reset(void){
    volatile u32* r=HB_REG;
    r[HB_H_SEQ]=0; r[HB_H_WIDX]=0; r[HB_H_FROZEN]=0; r[HB_H_LOCK]=0;
    hb_ring_zero(r);
}

/* FREEZE: stop appending -- capture the ring as-is (the trigger fired). */
static void hb_freeze(void){ HB_REG[HB_H_FROZEN]=1; }

/* ---- THE COE ENTRY (the header's entry_off points here; the LL calls it after applying
 * this COE's edit table, which is empty). Allocates the export ctx, fills the vtable
 * (each &fn is an R_ARM_ABS32 the LL rebased to heap), ARMS the region, publishes the ctx
 * pointer into the slot, and drives STATE INITED->RUNNING so consumers' guards open. */
int coe_init(void){
    hbuddy_export_t* c=RM_MALLOC(sizeof(hbuddy_export_t));
    if(!c) return 0;
    for(u32 i=0;i<sizeof(*c)/4u;i++) ((u32*)c)[i]=0;     /* mzero (no libc) */
    COE_SET_STATE((coe_slot_t*)HBUDDY_SLOT_ADDR, COE_INITED);   /* 1 (LOADED) -> 2 (starting) */
    hb_arm();                                            /* prove write + validate the header */
    c->vt[HB_VT_ARM]    = (u32)(void*)&hb_arm;
    c->vt[HB_VT_STAGE]  = (u32)(void*)&hb_stage;
    c->vt[HB_VT_LOG]    = (u32)(void*)&hb_log;
    c->vt[HB_VT_RESET]  = (u32)(void*)&hb_reset;
    c->vt[HB_VT_FREEZE] = (u32)(void*)&hb_freeze;
    c->abi_version      = HBUDDY_ABI;                    /* published last (table now complete) */
    ((volatile coe_slot_t*)HBUDDY_SLOT_ADDR)->ctx = (u32)c;     /* publish ctx BEFORE RUNNING */
    COE_SET_STATE((coe_slot_t*)HBUDDY_SLOT_ADDR, COE_RUNNING);  /* 2 -> 3: guarded callers fire */
    return (int)(u32)c;
}

#endif /* COE_BUILD */
