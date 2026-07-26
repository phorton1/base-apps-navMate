/* coe_common.h -- the shared LL<->COE contract: structs, the STATE enum, constants.
 *
 * Included by BOTH the LL (mods/mod005.c) and every COE (mods/aerial.c, ...). It holds
 * only DECLARATIONS -- no bodies. The runtime machinery (text_poke_n, apply_edits) lives
 * in the LL (mod005.c): the LL owns the one privileged copy and applies each COE's edit
 * table itself at load, so a COE ships only its edit data + coe_init, never the machinery.
 * (This file is what mods/coe_common.c became when its bodies moved into the LL.)
 *
 * FROZEN contract -- the whole point of mod005. Change nothing here without a format bump.
 * TARGET: ARM920T (ARMv4T), ARM state, LE.
 */
#ifndef COE_COMMON_H
#define COE_COMMON_H

#include <stdint.h>
typedef uint8_t  u8;
typedef uint32_t u32;

/* --- container identity + format ------------------------------------------- */
#define COE_MAGIC   0x31454f43u   /* 'COE1' -- identifies a COE file (feature-independent) */
#define COE_FORMAT  2u            /* format 2: LL-applies-edits header (below). fmt 1 = old self-hook. */

/* --- the COE file header (0x38 bytes, FROZEN). coe_pack writes it; the LL reads it. ----
 * Layout on disk: [header 0x38][reloc u32 * nreloc][code code_len]. reloc/entry/edits
 * offsets are all offsets into CODE (loaded at `base`), so the header size is irrelevant
 * to them. The last six words carry forward-headroom so the format never changes again. */
typedef struct {
    u32 magic;        /* 0x00  'COE1' */
    u32 format;       /* 0x04  = COE_FORMAT */
    u32 abi;          /* 0x08  feature ABI -- a COE-to-COE concern; the LL does NOT gate on it */
    u32 code_len;     /* 0x0c  bytes of code[] */
    u32 entry_off;    /* 0x10  -> coe_init (the LL calls it AFTER applying the edits) */
    u32 nreloc;       /* 0x14  R_ARM_ABS32 count */
    u32 code_sum;     /* 0x18  rotate-add checksum over code[] (a COE is EXECUTABLE -> refuse a bad card) */
    u32 version;      /* 0x1c  per-build coe_version stamp (identifies the card file) */
    u32 edits_off;    /* 0x20  -> the coe_edits[] table within code[] (the LL applies these) */
    u32 nedits;       /* 0x24  number of coe_edit_t entries */
    u32 flags;        /* 0x28  RESERVED (forward-headroom; 0) */
    u32 start_off;    /* 0x2c  RESERVED optional 2nd lifecycle entry (0 = none) */
    u32 slot_addr;    /* 0x30  the COE's 12-byte .bss slot absolute addr (LL sets STATE=LOADED here;
                       *       a contract-digesting diag reads it to find the slot). 0 = none. */
    u32 spare1;       /* 0x34  RESERVED (0) */
} coe_hdr_t;          /* 0x38 */

/* --- one edit: the LL installs an 8-byte ldr-pc splice at a firmware .text site --------
 * The LL verifies rsum(dst,len)==orig_sum (stock still present -> skew/collision guard,
 * fails SAFE) before poking. `src` is a COE symbol; the LL relocates it (R_ARM_ABS32). */
typedef struct {
    const void* src;  /* the splice stub (relocated to heap) */
    u32 dst;          /* firmware .text destination */
    u32 len;          /* bytes to write, 4-aligned (= 8 for a splice) */
    u32 orig_sum;     /* rotate-add of the ORIGINAL len bytes at dst */
} coe_edit_t;

/* --- the 12-byte .bss contract slot every COE (and the LL) owns ------------------------
 * A "slot" is bookkeeping only; the mechanism has no slot concept -- each owner
 * bakes its own absolute .bss address. Layout: */
typedef struct {
    u32 ctx;          /* +0  heap ctx pointer, published by the owner at load (0 = absent) */
    u32 flags;        /* +4  LOW BYTE = STATE (below); upper 3 bytes are the owner's own */
    u32 spare;        /* +8  the owner's own word */
} coe_slot_t;

/* --- STATE: the one universal field (slot.flags low byte). The LL drives 0->1 (LOADED);
 * the COE drives the higher states (INITED while starting, RUNNING when live). Dependents'
 * guarded-call wrappers (in a library COE's .h) fire only at RUNNING. --------------------*/
enum { COE_ABSENT = 0, COE_LOADED = 1, COE_INITED = 2, COE_RUNNING = 3, COE_FAULT = 0xff };
#define COE_STATE(slot)        ((u32)((volatile coe_slot_t*)(slot))->flags & 0xffu)
#define COE_SET_STATE(slot,s)  do { volatile coe_slot_t* _s=(volatile coe_slot_t*)(slot); \
                                    *(volatile u8*)&_s->flags = (u8)(s); } while (0)

#endif /* COE_COMMON_H */
