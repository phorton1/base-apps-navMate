/* aerial.h -- AERIAL.COE's contract: its .bss slot + export-table ABI.
 *
 * AERIAL is a COE (loaded off the card by the mod005 LL). This header is its published
 * contract, so a consumer COE or a contract-digesting diag can reach aerial without
 * hardcoding addresses. aerial.c currently carries these inline; this .h records the same
 * facts and is the home they migrate to when aerial's contract is fully extracted.
 *
 * Slot layout (coe_common.h coe_slot_t): D2[4] @ 0x044bb300 =
 *     { ctx(+0), flags(+4, byte0 = STATE), COMPOSITE_FLAGS(+8) }.
 * The LL drives STATE 0->1 (LOADED); coe_init drives 1->2 (INITED) -> 3 (RUNNING).
 */
#ifndef AERIAL_H
#define AERIAL_H

#include "coe_common.h"

#define AERIAL_SLOT_ADDR  0x044bb300u   /* D2[4] -- aerial's 12-byte contract slot (== CTX anchor) */
#define AERIAL_MAGIC      0x31454f43u   /* 'COE1' -- the COE file magic */
#define AERIAL_ABI        7u            /* export-table contract version; lives at ctx+0 */

/* aerial_ctx_t leads with the export table (aerial_abi_t) at ctx+0. Export offsets: */
#define AERIAL_EXP_ENABLE       4       /* void(*)(void)     -- aerial_coe_start ("enable") */
#define AERIAL_EXP_DEACTIVATE   8       /* void(*)(void)     -- aerial_deactivate_region ("stand down") */
#define AERIAL_EXP_SUPPRESS    12       /* int (*)(u32 self) -- kind5 pre: 1 = suppress native blit */
#define AERIAL_EXP_DRAW        16       /* int (*)(u32 self) -- kind5 post: draw our tiles to L3 */

/* Runtime A/B knobs word = slot.spare @ +8 (poke-able live). */
#define AERIAL_COMPOSITE_FLAGS_ADDR  (AERIAL_SLOT_ADDR + 8)

#endif /* AERIAL_H */
