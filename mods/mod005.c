/* This code is licensed under the MIT License -- see LICENSE.TXT in this directory. */
/* mod005.c -- E80 firmware mod: the COE linking loader (LL). mod4b left for mod004.
 *
 * mod4a: a scanning linking loader. It spawns a one-shot thread that scans the CF
 * root for *.COE and loads each once. The LL is edit-blind: it reads/relocates/
 * verifies a COE, applies its edit table, and calls its entry (coe_init, no args). A
 * COE ships only its edits + coe_init; the LL owns the one privileged text_poke.
 * mods/aerial.c -> AERIAL.COE is the first COE.
 *
 * The loader thread spawns from two triggers, covering the firmware's two disjoint
 * card-mount paths:
 *   - The first CHART PAINT (BOOT-PRESENT). ChartingAppPD_drawLayerByKind @0x006d9a18
 *     (PRE) is hit on every paint; its detour calls ll_on_paint, which on the first
 *     card-present paint spawns the one-shot loader. A paint proves the render subsystem
 *     AND the OS (scheduler, tick timer) are up, so both the thread create and the card
 *     read are safe. Riding the dispatcher -- one rung above the four composite sites the
 *     COE self-hooks -- avoids an orig_sum collision. This path is required because the
 *     boot FS init mounts a present-at-boot card WITHOUT notifying, and spawning the
 *     loader at init time (before the render path is up) resets the unit.
 *   - The MOUNT NOTIFY (COLD-INSERT SPAWN ONLY). cfCard_notifyStateChange @0x005d9ad0 (POST)
 *     is the central notifier the monitor (cfCard_monitorThread @0x005d9984) calls on a
 *     mount/unmount edge. Its detour (ll_on_notify) is reduced to a SPAWN-ONLY safety net: it
 *     spawns the loader on the first after-boot insert when no card was present at boot (so the
 *     paint gate never fired), and does nothing more. RE-SCANS are owned entirely by the loader's
 *     own 1 Hz fx_media_id (MEDI) edge poll (below), which also catches the Settings CF dialog --
 *     the case the notifier never fires. The splice stays installed but inert past the spawn.
 *
 * cfCard_mountReconcile (the Setup remove/reinsert dialog) is deliberately NOT hooked -- it
 * calls neither notifier; a real card remove+reinsert (the notify above) is the re-scan
 * trigger. An already-loaded COE is NEVER reloaded (the loader dedups by name against a
 * registry persisted on its immortal stack); a re-scan loads only NEW *.COE files, and the
 * running COE's own card poller still handles its card out/in teardown/reactivate.
 *
 * Aerial is NO LONGER flashed -- it left NOR for the card as a COE. mod4b (CF file
 * commands) is now its own mod (mod004), already in the progressive base chain -- not here.
 *
 * TARGET: ARM920T (ARMv4T), ARM state, LE. No libc, no Thumb, no blx.
 */
// @mod 005
// @pkg 6
// @version 574->575
//   (no @base: the mod builder derives this mod's base from @mod = the previous mod in the chain.
//    mod005 = the LL only; mod4b + all prior mods already live in the mod004 base, so nothing is
//    carried. The builder GENERATES the 574->575 self-check stamp from @version.)
//
// --- mod4a placement (build_cmod generates the firmware .ld from these) ---
// @run   run11 0x00293e14 1476
// @run   run20 0x002a621c 404
// @run   run12 0x002944d0 436
// @run   run19 0x002a4cb0 236
//   (the LL is ~2104 B of run code -- bigger than any single reclaimed run, so it spans a
//    few smaller ones. coe_load forces run11 -- the only free run big enough that is NOT
//    run17 (left free for a future big feature). ~82% aggregate occupancy.)
// @place run11      coe_load
// @place run11      icache_sync
// @place run11      coe_scan
// @place run11      fwcrumb
// @place run20      coe_scan_once
// @place run20      ll_spawn_loader
// @place run19      ll_on_paint
// @place run19      ll_on_notify
// @place run12      text_poke_n
// @place run12      ll_apply_edits
// @place run12      rsum
// @place run12      namehash
// @place run12      notifyState_detour
// @place run12      notifyState_trampoline
// @place run19      drawLayerByKind_detour
// @place run19      drawLayerByKind_trampoline
// @place 0x005d9ad0 notifyState_splice
// @place 0x006d9a18 drawLayerByKind_splice
#include "coe_common.h"   /* shared contract: coe_hdr_t/coe_edit_t/coe_slot_t, STATE, COE_MAGIC/FORMAT */
typedef int32_t  s32;

/* --- firmware bindings (same as mod004.c) --------------------------------- */
#define RM_MALLOC   ((void*(*)(u32))0x002a9434)
#define RM_FREE     ((void(*)(void*))0x001794e4)
#define FX_MEDIA()  ((void*)(*(volatile u32*)0x005d9a40 + 0xa4))
#define FX_OPEN     ((int(*)(void* media,void* fcb,const char* name,u32 type))0x002664e0)
#define FX_READ     ((int(*)(void* fcb,void* buf,u32 n,u32* act))0x00266900)
#define FX_CLOSE    ((int(*)(void* fcb))0x002660a0)
#define FX_DIRSEARCH ((int(*)(void* media,const char* path,void* dent,void* parent,void* lastname))0x00265d5c)
#define FX_DIRREAD   ((int(*)(void* media,void* dent,int* idx,void* oent))0x00267e88)
#define FX_DIRENT_SZ  0x120u
#define FX_DIRENT_MAX 512
#define RM_THREADCREATE ((int(*)(void* entry,void* input,u32 stk,u32 prio,void* tcb,void* nm,u32 id))0x0016e288)
#define RM_THREADSLEEP  ((void(*)(u32 ms))0x0016f594)
#define THREAD_NAME ((void*)0x010c26d4)
/* FS_READY -- the reliable FS-ready predicate: fx_media_id (CF driver +0xa4) == 'MEDI'. fx_media_open
 * sets it LAST (after the boot-sector parse + FAT reads), so FS_READY() true guarantees the CF root
 * is enumerable. The loader/scan gate on this. (Kept in sync with e569.h FS_READY.) */
#define FS_MEDIA_ID  (*(volatile u32*)0x024ebddc)
#define FS_MEDI_OPEN 0x4D454449u
#define FS_READY()   (FS_MEDIA_ID == FS_MEDI_OPEN)

#define SCAN_DIR   "\\"        /* CF root (root enum already proven via mod4b/FILESYS) */
#define MAX_COE    8           /* registry cap */
/* COE_MAGIC / COE_FORMAT and coe_hdr_t / coe_edit_t / coe_slot_t all come from coe_common.h */

/* rotate-add, identical to the packer / coe_load code_sum + the edit-guard */
static u32 rsum(const u8* p, u32 n)
{ u32 s=0,i; for(i=0;i<n;i++) s=(((s<<1)|(s>>31))+p[i])&0xffffffff; return s; }

/* --- text_poke_n + ll_apply_edits: the LL owns the ONE privileged copy.
 * After loading+relocating a COE the LL applies its edit table itself, so a COE ships only
 * its edits + coe_init, never the machinery. text_poke_n: write len (4-aligned) bytes to RO
 * .text via the DACR manager-domain bypass + ARM920T cache maintenance, IRQ/FIQ off for the
 * whole window (proven -- see the runtime .text-overwriting work). */
__attribute__((naked)) void text_poke_n(u32 dst, const void* src, u32 len)
{
    __asm__ volatile(
        "push {r4,r5,r6,r7,lr}\n"
        "mrs  r4, cpsr\n"
        "orr  r5, r4, #0xc0\n"
        "msr  cpsr_c, r5\n"            /* IRQ+FIQ off */
        "mrc  p15,0,r5,c3,c0,0\n"      /* r5 = DACR (save) */
        "bic  r6, r5, #3\n"
        "orr  r6, r6, #3\n"
        "mcr  p15,0,r6,c3,c0,0\n"      /* domain0 = manager (AP bypass) */
        "mov  r7, r0\n"                /* r7 = dst base */
        "mov  r6, r2\n"                /* r6 = len (copy counter) */
        "1:\n"
        "ldr  r3, [r1], #4\n"
        "str  r3, [r0], #4\n"
        "subs r6, r6, #4\n"
        "bne  1b\n"
        "add  r2, r7, r2\n"            /* r2 = end = dst+len */
        "bic  r0, r7, #31\n"           /* r0 = first cache line */
        "2:\n"
        "mcr  p15,0,r0,c7,c10,1\n"     /* clean D line by MVA */
        "add  r0, r0, #32\n"           /* ARM920T cache line = 32 B */
        "cmp  r0, r2\n"
        "blo  2b\n"
        "mov  r0, #0\n"
        "mcr  p15,0,r0,c7,c10,4\n"     /* drain write buffer (once) */
        "bic  r0, r7, #31\n"
        "3:\n"
        "mcr  p15,0,r0,c7,c5,1\n"      /* invalidate I line by MVA */
        "add  r0, r0, #32\n"
        "cmp  r0, r2\n"
        "blo  3b\n"
        "mcr  p15,0,r5,c3,c0,0\n"      /* restore DACR */
        "msr  cpsr_c, r4\n"            /* restore CPSR (IRQ on) */
        "pop  {r4,r5,r6,r7,pc}\n"
    );
}
/* ll_apply_edits -- verify + install every edit in a loaded COE's table. src pointers are
 * already relocated to heap by coe_load. orig_sum guards STOCK bytes (skew/collision -> skip,
 * fails SAFE), which is what makes .text ranges uniquely owned across COEs. */
static int ll_apply_edits(const coe_edit_t* edits, u32 nedits)
{
    u32 i, applied = 0;
    for (i = 0; i < nedits; i++) {
        const coe_edit_t* e = &edits[i];
        if (rsum((const u8*)e->dst, e->len) != e->orig_sum) continue;   /* not stock -> skip, SAFE */
        text_poke_n(e->dst, e->src, e->len);
        applied++;
    }
    return applied;
}

/* --- crash-diagnostic breadcrumbs (OFF by default) --------------------------------
 * The LL can stamp its load-path progress into a fixed high-DRAM block that survives the
 * HW-watchdog reset (dram_survives_reboot), so a boot-present crash leaves a trail: each
 * load stage stamps a rising code 0xFC0000nn, and coe_load records an edit-apply mask.
 * This is DISABLED by default and writes NOTHING unless armed -- poke FWLL_REGION[FWLL_EN]=1
 * to capture a post-boot crash, or rebuild with FWLL_DEFAULT_ON=1 to capture a boot-time one
 * (before a poke is possible). The block (0x07A10000) is DISJOINT from HBUDDY.COE's 4 KB
 * region (0x07A00000): the LL owns its OWN crash-resistant range and depends on no COE.
 * The gate is deterministic despite DRAM not being zeroed at boot -- the first crumb cold-
 * inits the region sig + enable word, so a stale-DRAM value can never arm it by accident. */
#define FWLL_REGION      ((volatile u32*)0x07A10000u)
#define FWLL_SIG         0x4c4c5746u   /* 'FWLL' */
#define FWLL_SIGW   0u   /* [0] region signature      */
#define FWLL_EN     1u   /* [1] enable (0 = off)      */
#define FWLL_CODE   2u   /* [2] rising fw stage code  */
#define FWLL_MASK   3u   /* [3] coe_load stage mask   */
#define FWLL_APPL   4u   /* [4] edits-applied count   */
#define FWLL_DEFAULT_ON  0   /* rebuild to 1 to capture a boot-time crash */
void fwcrumb(u32 code)
{
    volatile u32* r = FWLL_REGION;
    if (r[FWLL_SIGW] != FWLL_SIG) {                       /* cold-init (DRAM not zeroed at boot) */
        r[FWLL_SIGW]=FWLL_SIG; r[FWLL_EN]=FWLL_DEFAULT_ON; r[FWLL_MASK]=0; r[FWLL_APPL]=0;
    }
    if (r[FWLL_EN]) r[FWLL_CODE] = 0xFC000000u | code;
}
#define FWCRUMB(c)  fwcrumb((c))

/* icache_sync -- make freshly-written code at [addr, addr+len) executable on the ARM920T
 * (Harvard split caches, NO snooping). coe_load writes a COE image into heap via the D-cache then
 * jumps into it; without this the I-cache serves STALE lines for that region and the core fetches
 * garbage -> undefined-instruction trap (proven: the 2nd COE dies, while the 1st -- landing on cold
 * lines -- survives). Clean each D line by MVA + invalidate the matching I line, then drain the
 * write buffer once. Same CP15 ops text_poke_n uses; kept a separate leaf so the proven text_poke_n
 * stays untouched. ARM920T cache line = 32 B; no DACR/IRQ dance -- the region is normal writable
 * heap not yet executing on any thread. */
__attribute__((naked)) void icache_sync(u32 addr, u32 len)   /* global: stable @place name */
{
    __asm__ volatile(
        "add  r1, r0, r1\n"           /* r1 = end address */
        "bic  r0, r0, #31\n"          /* r0 = first cache line (32 B aligned) */
        "1:\n"
        "mcr  p15,0,r0,c7,c10,1\n"    /* clean D line by MVA */
        "mcr  p15,0,r0,c7,c5,1\n"     /* invalidate I line by MVA */
        "add  r0, r0, #32\n"
        "cmp  r0, r1\n"
        "blo  1b\n"
        "mov  r0, #0\n"
        "mcr  p15,0,r0,c7,c10,4\n"    /* drain write buffer (once) */
        "bx   lr\n"
    );
}

/* coe_load -- read a COE off the card into heap, verify, relocate, apply its edit table,
 * and call its coe_init entry. Returns base on success (for the registry), else 0. */
void* coe_load(const char* path)                       /* global: keep the symbol name for @place */
{
    coe_hdr_t h; void* fcb; u32* rel=0; u8* base=0; u32 got,i,s;
    FWCRUMB(0x50);                                        /* coe_load entered */
    fcb = RM_MALLOC(0x180); if(!fcb) return 0;
    if (FX_OPEN(FX_MEDIA(), fcb, path, 0)) { RM_FREE(fcb); return 0; }
    FWCRUMB(0x60);                                        /* FX_OPEN ok */
    if (FX_READ(fcb,&h,sizeof(h),&got) || got!=sizeof(h)) goto fail;
    if (h.magic!=COE_MAGIC || h.format!=COE_FORMAT) goto fail;
    FWCRUMB(0x70);                                        /* header read + magic ok */
    if (!h.code_len || !h.nreloc) goto fail;
    rel = RM_MALLOC(h.nreloc*4); if(!rel) goto fail;
    if (FX_READ(fcb,rel,h.nreloc*4,&got) || got!=h.nreloc*4) goto fail;
    FWCRUMB(0x80);                                        /* reloc table read ok */
    base = RM_MALLOC(h.code_len); if(!base) goto fail;
    if (FX_READ(fcb,base,h.code_len,&got) || got!=h.code_len) goto fail;
    FWCRUMB(0x90);                                        /* code body read ok */
    FX_CLOSE(fcb); RM_FREE(fcb); fcb=0;
    for (s=0,i=0;i<h.code_len;i++) s=(((s<<1)|(s>>31))+base[i])&0xffffffff;
    if (s!=h.code_sum) goto fail;
    FWCRUMB(0xA0);                                        /* code_sum verified */
    for (i=0;i<h.nreloc;i++) *(u32*)(base+rel[i]) += (u32)base;
    RM_FREE(rel); rel=0;
    FWCRUMB(0xB0);                                        /* relocated -- the LL now applies the COE's edits */
    /* The LL applies the COE's edit table itself -- this MUST run regardless of the crumb
     * gate, so the apply is unconditional and only the diagnostic record is gated. */
    u32 applied = (u32) ll_apply_edits((const coe_edit_t*)(base+h.edits_off), h.nedits);
    { volatile u32* r=FWLL_REGION;
      if (r[FWLL_SIGW]==FWLL_SIG && r[FWLL_EN]) { r[FWLL_MASK]=0x03; r[FWLL_APPL]=applied; } }
    if (h.slot_addr) COE_SET_STATE((coe_slot_t*)h.slot_addr, COE_LOADED);  /* LL drives 0->1; COE drives higher */
    icache_sync((u32)base, h.code_len);       /* Harvard-cache: publish the loaded+relocated code to the I-side */
    ((int(*)(void))(base + h.entry_off))();   /* coe_init: publishes ctx, drives INITED->RUNNING */
    FWCRUMB(0xC0);                                        /* coe_init returned */
    return base;
fail:
    if (fcb) { FX_CLOSE(fcb); RM_FREE(fcb); }
    if (base) RM_FREE(base);
    if (rel)  RM_FREE(rel);
    return 0;
}

/* name hash for dedup (order/case as the enumerator hands them, upper-cased 8.3) */
u32 namehash(const u8* nm, u32 n)
{ u32 h=2166136261u,i; for(i=0;i<n;i++){ h^=nm[i]; h=(h*16777619u)&0xffffffff; } return h; }

/* one scan pass: enumerate SCAN_DIR, load every *.COE not already in reg[]. */
void coe_scan(u32* reg, int* nreg)                      /* global: no constprop-clone -> stable @place name */
{
    if (!FS_READY()) return;                             /* MEDI = FAT parsed -> the root is enumerable */
    FWCRUMB(0x40);                                        /* coe_scan entered (card enumerate) */
    u8* oent=RM_MALLOC(FX_DIRENT_SZ); if(!oent) return;
    for (int idx=0; *nreg<MAX_COE && idx<FX_DIRENT_MAX; idx++) {
        if (FX_DIRREAD(FX_MEDIA(),0,&idx,oent)) break;   /* dent=0 -> enumerate the CF ROOT directory */
        if (oent[0]==0) break;
        if (oent[0]==0xE5) continue;
        if (oent[0x104]&0x10) continue;                 /* subdir */
        u32 n=0; while(n<64 && oent[n]) n++;
        if (n<5) continue;
        if (oent[n-4]!='.'||oent[n-3]!='C'||oent[n-2]!='O'||oent[n-1]!='E') continue;
        u32 hh=namehash(oent,n); int seen=0;
        for (int k=0;k<*nreg;k++) if(reg[k]==hh){ seen=1; break; }
        if (seen) continue;                             /* already loaded */
        char path[80]; u32 j=0; path[j++]='\\';        /* "\NAME.COE" at the CF root */
        for (u32 k=0;k<n;k++) path[j++]=(char)oent[k];
        path[j]=0;
        if (coe_load(path)) reg[(*nreg)++]=hh;          /* record on success */
    }
    RM_FREE(oent);
}

/* --- card-mount anchors + hooks (the mount model is in the header) -------------- */

/* The LL's own contract slot = D2[0] @ 0x044bb2d0 (coe_slot_t {ctx,flags,spare}). Its private
 * scan latches pack into slot0.flags UPPER BYTES -- separate BYTES (strb, no word RMW), so the
 * paint thread and the mount thread never race. The one-shot TCB handle uses slot0.spare. Aerial
 * is D2[4] @0x044bb300 (see aerial.h). Flashed .bss is discarded by the build,
 * so these are absolute dead-.bss anchors in the reclaimed D2 iface region (ends 0x044bb384). */
#define LL_SLOT     ((coe_slot_t*)0x044bb2d0)     /* D2[0]: {ctx(+0), flags(+4), spare(+8)} -- the LL's own slot */
#define LL_SPAWNED  (*(volatile u8*)0x044bb2d5)   /* slot0.flags byte1: loader thread spawned this boot (per-boot latch) */
#define LL_PAINTED  (*(volatile u8*)0x044bb2d6)   /* slot0.flags byte2: render path (hence FileX) is up.
                                                   * byte1/byte2 are separate BYTES (strb, no word RMW), so the
                                                   * paint thread and the mount thread never race. */
#define LL_RESCAN   (*(volatile u8*)0x044bb2d7)   /* slot0.flags byte3: HOST poke (navMate after an over-the-wire
                                                   * upload) -> the immortal loader thread re-scans. The loader ALSO
                                                   * re-scans on an fx_media_id (MEDI) rising edge; ll_on_notify no
                                                   * longer sets this (it is spawn-only). */
#define LL_TCB_SLOT ((void*)0x044bb2d8)           /* slot0.spare: the handle to the malloc'd loader TCB */

/* The loader thread: WAIT FOR THE FIRST PAINT, then scan -- and thereafter RE-SCAN on demand.
 * `reg[]` (the loaded-COE hash registry) lives on THIS thread's stack, and the thread is IMMORTAL
 * (it loops forever), so the registry PERSISTS across scans with no separate storage. Each scan is
 * dedup'd against reg[] (coe_scan skips names already loaded), so a re-scan loads only NEW *.COE
 * files and never re-runs an already-installed COE -- the "stepped" load. The re-scan is driven by
 * LL_RESCAN, set by ll_on_notify on a card MOUNT: no new detour, and no thread re-spawn (which would
 * leak TCBs / re-run an installed splice).
 *
 * The paint-wait is the BOOT-present fix: the mount hooks spawn this thread very early, while FileX /
 * the render subsystem are still coming up, and reading the card right then resets the unit.
 * LL_PAINTED (set by the drawLayerByKind detour on the first paint) proves the render path -- hence
 * FileX -- is live. Bounded (~20s) fallback. On insert-after-boot LL_PAINTED is already set, so it
 * falls through. */
void coe_scan_once(u32 input)
{
    u32 reg[MAX_COE]; int nreg=0;                         /* immortal-thread stack -> persists across scans */
    (void)input;
    FWCRUMB(0x20);                                        /* loader thread entered (before paint-wait) */
    for (int i=0; i<200 && !LL_PAINTED; i++)
        RM_THREADSLEEP(100);
    FWCRUMB(LL_PAINTED ? 0x30 : 0x31);                    /* 0x30 = paint seen; 0x31 = wait TIMED OUT */
    for (;;) {
        LL_RESCAN = 0;                                    /* clear before scanning -> a request during the scan re-fires */
        coe_scan(reg,&nreg);                              /* dedup'd: loads only *.COE not already in reg[] */
        /* Park until a re-scan is warranted -- two wake sources, no notify detour needed:
         *  - a not-ready -> ready EDGE on fx_media_id (MEDI): catches a physical reinsert AND the
         *    Settings CF remove/reinsert dialog (which the mount notifier never fires). `last` is
         *    seeded to the CURRENT FS state so a boot that came up already-ready does not re-fire.
         *  - LL_RESCAN poked by the host (navMate after an over-the-wire upload, which does NOT
         *    toggle MEDI) -- kept as the fully-remote trigger.
         * ~1 Hz is ample for a human dialog action and costs nothing. */
        u32 last = FS_READY() ? 1u : 0u;
        while (!LL_RESCAN) {
            RM_THREADSLEEP(1000);
            u32 now = FS_READY() ? 1u : 0u;
            if (!last && now) break;                      /* FS-ready rising edge -> re-scan */
            last = now;
        }
    }
}

/* Spawn the one-shot loader thread. Its TCB is a full ~0x104-B TX_THREAD, heap-allocated (like the
 * COE's own threads); slot0.spare holds only the handle. */
__attribute__((noinline)) void ll_spawn_loader(void)   /* global: stable @place name, no inline-clone */
{
    void* tcb = RM_MALLOC(0x104);
    *(void**)LL_TCB_SLOT = tcb;                          /* slot0.spare = 4-byte handle (not the TCB) */
    RM_THREADCREATE((void*)coe_scan_once, 0, 0x2000, 0, tcb, THREAD_NAME, 0x99);
}

/* LL_SPAWNED is a PER-BOOT latch: the loader THREAD is spawned at most once per power cycle
 * (spawning twice would leak TCBs and race two scanners). It is never cleared. What re-arms is the
 * SCAN, not the thread: once spawned, the immortal loader re-scans whenever ll_on_notify sets
 * LL_RESCAN on a mount. The dedup registry (reg[], persisted on the loader stack) makes a re-scan
 * load only NEW COEs and never re-run an installed splice. */

/* POST-notify callback: SPAWN-ONLY (the cold-insert safety net). On the first card MOUNT this boot
 * (kind==0) when no card was present at boot -- so the paint gate never fired -- it spawns the loader
 * thread. It does NOTHING thereafter: the loader's own 1 Hz fx_media_id (MEDI) edge poll owns EVERY
 * re-scan, so a dropped-in COE loads on the next FS-ready edge (a physical reinsert OR the Settings
 * remove/reinsert dialog, which the mount notifier never fires). The notifyStateChange splice stays
 * installed but is inert past this spawn -- nothing of ours is driven off it, so it cannot confound a
 * test of the MEDI poll. Gate on kind, NOT driver+0xa0. */
void ll_on_notify(u32 driver, u32 kind)
{
    (void)driver;
    if (kind != 0) return;                               /* mounts only */
    if (!LL_SPAWNED) { LL_SPAWNED = 1; ll_spawn_loader(); }  /* cold insert (no card at boot): spawn once */
}

/* Spawn the one-shot loader on the first CHART PAINT that sees a card. Called from the
 * drawLayerByKind detour (every paint). A paint proves the render subsystem AND the OS
 * (scheduler, tick timer) are up, so both creating the thread and the card read it does
 * are safe. Gated by LL_SPAWNED so it spawns at most once per boot. This is the
 * BOOT-PRESENT trigger; insert-after-boot uses the notify trigger (ll_on_notify). */
void ll_on_paint(void)
{
    if (FS_READY() && !LL_SPAWNED) {
        LL_SPAWNED = 1;
        FWCRUMB(0x10);                                    /* first card-present paint: spawning loader */
        ll_spawn_loader();
    }
}

/* @place run20 -- POST detour + displaced-prologue trampoline + in-place splice.
 * A 4-byte `b` splice (the detour sits in-.text run20, within b's +/-32MB of the
 * site), so it displaces ONE instruction; the trampoline replays it, then continues
 * at head+4. The native notify preserves r4/r5 (it saves them), so driver/kind held
 * there survive the call. */
__attribute__((naked)) void notifyState_detour(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4, r5, r6, lr}\n"   /* r6 = alignment filler */
        "mov r4, r0\n"                    /* r4 = driver */
        "mov r5, r1\n"                    /* r5 = kind (0=mount, 1=unmount) */
        "bl notifyState_trampoline\n"     /* run native notify IN FULL (r0=driver, r1=kind) */
        "mov r0, r4\n"
        "mov r1, r5\n"
        "bl ll_on_notify\n"               /* fire the scan on a mount notify */
        "ldmia sp!, {r4, r5, r6, lr}\n"
        "bx lr\n"
    );
}
__attribute__((naked)) void notifyState_trampoline(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4, r5, r6, r7, r10, lr}\n"  /* displaced notifyStateChange prologue (e92d44f0) */
        "mov ip, #0x005d0000\n"
        "orr ip, ip, #0x9a00\n"
        "orr ip, ip, #0xd4\n"             /* ip = 0x005d9ad4 = notifyStateChange head+4 */
        "bx ip\n"
    );
}
__attribute__((naked)) void notifyState_splice(void){ __asm__ volatile("b notifyState_detour\n"); }

/* @place run11 -- PRE-only detour on ChartingAppPD_drawLayerByKind @0x006d9a18 (the render
 * dispatcher). This is the LL's paint gate: on every dispatch it sets LL_PAINTED (slot0.flags
 * byte2 @0x044bb2d6) -> the loader thread reads that to know the render path is live before it touches
 * the card. TAIL-CALLS the trampoline (no POST): native returns straight to its caller. Uses only
 * r2/r3 (native sets both before reading, and never reads them at entry), so r0/r1 (this,kind) and
 * lr (the caller's return) pass through untouched. Latch-free: LL_PAINTED just gets re-set 1 each
 * paint (idempotent), so no read-modify-write and no race with the mount thread's LL_SPAWNED byte. */
__attribute__((naked)) void drawLayerByKind_detour(void)
{
    __asm__ volatile(
        "mov r2, #0x04000000\n"
        "orr r2, r2, #0x004b0000\n"
        "orr r2, r2, #0xb200\n"
        "orr r2, r2, #0xd4\n"             /* r2 = 0x044bb2d4 (slot0.flags) */
        "mov r3, #1\n"
        "strb r3, [r2, #2]\n"             /* LL_PAINTED = slot0.flags byte2 (0x044bb2d6) = 1 */
        "stmdb sp!, {r0, r1, r2, r3, ip, lr}\n" /* preserve native args + return across the call (8-aligned) */
        "bl ll_on_paint\n"               /* first card-present paint spawns the loader (once, gated) */
        "ldmia sp!, {r0, r1, r2, r3, ip, lr}\n"
        "b drawLayerByKind_trampoline\n"  /* tail into native; lr still = original caller */
    );
}
__attribute__((naked)) void drawLayerByKind_trampoline(void)
{
    __asm__ volatile(
        "stmdb sp!, {r4, r5, lr}\n"       /* displaced drawLayerByKind prologue (e92d4030) */
        "mov ip, #0x006d0000\n"
        "orr ip, ip, #0x9a00\n"
        "orr ip, ip, #0x1c\n"             /* ip = 0x006d9a1c = drawLayerByKind head+4 */
        "bx ip\n"
    );
}
__attribute__((naked)) void drawLayerByKind_splice(void){ __asm__ volatile("b drawLayerByKind_detour\n"); }
