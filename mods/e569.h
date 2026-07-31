/* This code is licensed under the MIT License -- see LICENSE.TXT in this directory. */
/* ============================================================================
 * e569.h -- E-Series (E80 / E120) firmware v5.69 ABI, for COE development.
 *
 * A reference of stock firmware entry points -- address, C signature, and the
 * behaviour a caller actually needs -- for code extensions (COEs) built on the
 * v5.69 base image. Include it to call the firmware from a COE instead of
 * re-deriving a binding every time. It declares NOTHING of its own: every macro
 * is a typed cast of a fixed firmware address, so this header emits no code and
 * no data.
 *
 *     #include "e569.h"
 *     void* p = RM_MALLOC(0x1000);
 *
 * *** USE AT YOUR OWN RISK ***
 * These are addresses inside somebody else's binary, recovered by analysis and
 * checked on hardware, but neither documented nor guaranteed by the manufacturer.
 * They are correct for ONE firmware version and will differ on any other. Calling
 * one with the wrong arguments, from the wrong thread context, or against an
 * object that is not what you assume can corrupt memory or reset the unit with no
 * warning. Nothing here is a supported interface. You accept all risk of using it.
 *
 * VERSION. Every address is firmware v5.69 -- the stock v5.69 application image, at
 * sites left unmodified by any extension. Addresses are RAM addresses (the image
 * maps 1:1 into the RAM segment). A different firmware version invalidates the file.
 *
 * TARGET. ARM920T (ARMv4T), ARM state, little-endian. There is no `blx`: reach an
 * absolute address via `mov lr,pc; bx <reg>`, never `blx` (an undefined
 * instruction here -> bootloop).
 *
 * NAMES + PROVENANCE. The stock image is stripped; only RTTI class names and
 * library import symbols survive, so most names here are OUR labels, not firmware
 * symbols.
 * Each entry is tagged:
 *   [lib]  a surviving library import symbol (FileX fx_*, ThreadX tx_*, ...) --
 *          a verbatim external name, high confidence.
 *   [RTTI] the CLASS name is from surviving RTTI; the method suffix is our label.
 *   [ren]  our Ghidra label for an otherwise-anonymous routine -- a tool name only,
 *          not anything the firmware calls it.
 *   [emp]  the behaviour or gotcha noted is established empirically on hardware,
 *          not merely read from the disassembly.
 *
 * What this file records is FACTS about the firmware -- signatures, argument
 * meaning, return codes, side effects, context, ownership, and the gotchas that
 * cost real hardware to find -- not the firmware's code.
 * ============================================================================ */
#ifndef E569_H
#define E569_H
#include <stdint.h>

/* ============================================================================
 * 1. Heap allocator  (rm_malloc: mutex + circular first-fit freelist + sbrk)
 * ============================================================================ */

/* rm_malloc  [ren] -- allocate from the main system heap.
 *   void* rm_malloc(uint32_t nbytes);
 *   returns: block pointer, or 0 (NULL) on out-of-memory. NOT zeroed.
 *   context: task context. Takes the heap mutex internally -> do NOT call from
 *            an IRQ/FIQ handler or with interrupts masked.
 *   notes:   granularity 0x800; the heap is ~52 MB total, ~32 MB really available
 *            (the wilderness). Heap is not the scarce resource here -- reclaimed
 *            code-space is. Reentrant across threads (mutex-guarded), not from IRQ. */
#define RM_MALLOC   ((void*(*)(uint32_t))0x002a9434)

/* rm_free  [ren] -- return a block from rm_malloc to the heap.
 *   void rm_free(void* p);
 *   p == 0 is safe (no-op). Double-free is NOT safe. Same mutex/context rules. */
#define RM_FREE     ((void(*)(void*))0x001794e4)

/* [emp] Free-heap estimate from peeks alone (no walk):
 *   avail = ( *(uint32_t*)0x002b0538 - *(uint32_t*)0x01ad2448 ) + freelist_total
 * The wilderness (~32 MB) is the first term; a freelist walk sees ONLY recycled
 * blocks (~0.4 MB) and must NOT be read as headroom. */
#define HEAP_BREAK_PTR  (*(volatile uint32_t*)0x002b0538)   /* current sbrk break     */
#define HEAP_BASE_PTR   (*(volatile uint32_t*)0x01ad2448)   /* wilderness base pointer */

/* ============================================================================
 * 2. FileX  (raw FAT file + directory API on the CF card)
 * ============================================================================ */

/* FX_MEDIA() -- the live FX_MEDIA* for the CF card.
 *   The CF driver singleton is *(0x005d9a40); its media control block is at +0xa4.
 *   Resolve it fresh at each use (do not cache across a card swap). */
#define FX_MEDIA()  ((void*)(*(volatile uint32_t*)0x005d9a40 + 0xa4))

/* fx_file_open  [lib] -- open a file by path into a caller-owned control block.
 *   int fx_file_open(void* media, void* fcb, const char* name, uint32_t type);
 *   media : FX_MEDIA()
 *   fcb   : caller-owned FX_FILE control block (see the 0x180 GOTCHA)
 *   name  : path with backslashes, absolute preferred, e.g. "\\RASTER\\BOCAS.RCT"
 *   type  : open mode; 0 = open-for-read
 *   returns: 0 = FX_SUCCESS; nonzero = a FileX error code
 *   side effects: fills fcb and links it into the media's open-file list -- a
 *                 successful open MUST be paired with fx_file_close.
 *   context: task context; FileX takes the media mutex. Not from IRQ.
 *   GOTCHA [emp]: allocate the fcb with rm_malloc(0x180). open writes fields as
 *     far as fcb+0x164; a 0x100-byte block silently corrupts the adjacent heap
 *     object. 0x180 is the safe size, proven on hardware. */
#define FX_OPEN     ((int(*)(void* media,void* fcb,const char* name,uint32_t type))0x002664e0)

/* fx_file_read  [lib] -- read bytes from the current file offset.
 *   int fx_file_read(void* fcb, void* buf, uint32_t nbytes, uint32_t* actual);
 *   returns: 0 = FX_SUCCESS (check *actual == nbytes for a full read);
 *            nonzero = error (e.g. end-of-file short read).
 *   side effects: advances the file offset by *actual. */
#define FX_READ     ((int(*)(void* fcb,void* buf,uint32_t nbytes,uint32_t* actual))0x00266900)

/* fx_file_seek  [lib] -- set the absolute file offset for the next read.
 *   int fx_file_seek(void* fcb, uint32_t offset);
 *   returns: 0 = FX_SUCCESS. */
#define FX_SEEK     ((int(*)(void* fcb,uint32_t offset))0x00266c24)

/* fx_file_close  [lib] -- close a file opened with fx_file_open.
 *   int fx_file_close(void* fcb);
 *   returns: 0 = FX_SUCCESS. Unlinks the fcb from the media open-file list; the
 *            fcb memory is yours to free afterwards. */
#define FX_CLOSE    ((int(*)(void* fcb))0x002660a0)

/* fx_directory_search  [lib] -- resolve a directory path to a FX_DIR_ENTRY.
 *   int fx_directory_search(void* media, const char* path, void* dent,
 *                           void* parent, void* lastname);   // parent, lastname: pass 0
 *   dent  : caller-owned FX_DIR_ENTRY buffer, FX_DIRENT_SZ bytes.
 *   returns: 0 = found; 4 = not found.
 *   GOTCHA [emp]: an ABSOLUTE path (leading '\\') makes this skip BOTH the
 *     thread-local current-directory (*tx_thread_current_ptr+0x94) AND the media
 *     default path (media+0x6f4). So the search/read PAIR touches no shared
 *     filesystem state and needs no fx_directory_default_set (which would be a
 *     process-global hazard). Use absolute paths from a background thread. */
#define FX_DIRSEARCH ((int(*)(void* media,const char* path,void* dent,void* parent,void* lastname))0x00265d5c)

/* fx_directory_entry_read  [lib] -- read the idx-th child of a directory entry.
 *   int fx_directory_entry_read(void* media, void* dent, int* idx, void* oent);
 *   dent : the FX_DIR_ENTRY from fx_directory_search; 0 = enumerate the CF ROOT.
 *   idx  : IN/OUT cursor. The callee may advance it past long-filename sub-entries;
 *          the caller adds 1 for the next iteration.
 *   oent : caller-owned FX_DIR_ENTRY buffer, FX_DIRENT_SZ bytes, filled on success.
 *   returns: 0 = ok; 8 = off the cluster chain (stop).
 *   Walks the cluster chain of whatever directory `dent` names, so it is stateless
 *   w.r.t. the current-directory globals -- the safety property above extends here. */
#define FX_DIRREAD   ((int(*)(void* media,void* dent,int* idx,void* oent))0x00267e88)

/* FX_DIR_ENTRY layout (both dent and oent buffers): */
#define FX_DIRENT_SZ        0x120u   /* allocate this many bytes for each entry buffer   */
#define FX_DIRENT_NAME      0x000u   /* 8.3 name; byte0 0 = END OF DIRECTORY, 0xE5 = free */
#define FX_DIRENT_ATTR      0x104u   /* FAT attribute byte; & 0x10 = subdirectory         */
#define FX_DIRENT_CLUSTER   0x110u   /* starting cluster                                  */
#define FX_DIRENT_SIZE      0x114u   /* file size in bytes                                */

/* ============================================================================
 * 3. Threads + scheduling  (RayLib wrappers over ThreadX)
 * ============================================================================ */

/* rm_threadCreate  [ren] -- create and start a thread (wraps tx_thread_create).
 *   int rm_threadCreate(void* entry, void* input, uint32_t stack_bytes,
 *                       uint32_t prio, void* tcb, void* name, uint32_t id);
 *   entry : void(*)(uint32_t input) thread body
 *   tcb   : caller-owned TX_THREAD control block; allocate rm_malloc(0x104)
 *   name  : a name blob -- THREAD_NAME below serves
 *   returns: 0 = TX_SUCCESS.
 *   GOTCHA [emp]: `prio` is a MAPPED index, NOT a ThreadX priority. The mapping is
 *     0->TX prio 31 (LOWEST), 1->30, 2->12, 5->8, 7->4, 8->TX prio 2 (near HIGHEST).
 *     Pass 0 for a genuine background thread. Passing 8 makes it preempt the UI. */
#define RM_THREADCREATE ((int(*)(void* entry,void* input,uint32_t stack_bytes,uint32_t prio,void* tcb,void* name,uint32_t id))0x0016e288)

/* rm_threadSleep  [ren] -- sleep the current thread (wraps tx_thread_sleep).
 *   void rm_threadSleep(uint32_t ms);   -- argument is MILLISECONDS.
 *   Yields the core; do NOT call from IRQ or with the scheduler held. */
#define RM_THREADSLEEP  ((void(*)(uint32_t ms))0x0016f594)

/* A ready-made thread-name blob for rm_threadCreate's `name` argument. */
#define THREAD_NAME     ((void*)0x010c26d4)

/* ============================================================================
 * 4. RayLib event flags  (one AUTO-RESET group per waiter; wraps tx_event_flags_*)
 *
 * The group object is 0x2c bytes; place it in your own heap struct (no separate
 * alloc). One SET wakes EXACTLY ONE waiter on an auto-reset group, so create your
 * OWN group rather than blocking on a native one -- a second waiter on a shared
 * group steals wakes at random and breaks both sides.
 * ============================================================================ */
#define EVGRP_SZ 0x2cu   /* bytes to reserve for one event-flag group */

/* RL_evCreate (AUTO-RESET)  [ren] -- create an auto-reset event-flag group.
 *   int RL_evCreate(void* grp, void* name, uint32_t id);
 *   memset(grp,0,0x2c); grp+0x24 = 0 => TX_OR_CLEAR (auto-reset); then
 *   tx_event_flags_create(grp,name). returns 0 = ok.
 *   name: THREAD_NAME serves.
 *   The MANUAL-RESET twin is at 0x0016e8bc (grp+0x24 != 0). */
#define RL_EVCREATE ((int(*)(void* grp,void* name,uint32_t id))0x0016e8cc)

/* RL_evWait  [ren] -- block until bit 0 is set, then CONSUME it (auto-reset).
 *   int RL_evWait(void* grp);
 *   tx_event_flags_get(grp,1,TX_OR_CLEAR,&actual,TX_WAIT_FOREVER).
 *   returns: 0 = woken; 0x308 = group was deleted (bail out of the loop). */
#define RL_EVWAIT   ((int(*)(void* grp))0x0016ea0c)

/* RL_evSet  [ren] -- set bit 0, waking one waiter.
 *   int RL_evSet(void* grp);   tx_event_flags_set(grp,1,TX_OR). returns 0 = ok.
 *   Cheap (~1 us) and safe to call often; it is the wake for a worker thread. */
#define RL_EVSET    ((int(*)(void* grp))0x0016e964)

/* ============================================================================
 * 5. Chart layer access  (ChartingAppPD key-surface lookup)
 *
 * A chart window's paint device (ChartingAppPD) owns a red-black map of numbered
 * "key" layers. Look one up, then take its Coral surface descriptor.
 * ============================================================================ */

/* ChartingAppPD_layerMapLookup  [RTTI]+[ren] -- find a layer node by key.
 *   uint32_t layerMapLookup(uint32_t map, uint32_t* key);
 *   map : the PD's layer map, i.e. pd+0x60.
 *   key : pointer to the key value (e.g. 5 for the aerial key-surface).
 *   returns: the node, or a NIL node (test node+0x5d for the NIL marker).
 *   node layout: key @node+0x0c, layer @node+0x14, background colour @node+0x28.
 *   [emp] the map is PER-window: a 2-window page has two distinct map heads, so
 *   each window owns its own key-5. Never assume a single global layer. */
#define LAYER_LOOKUP ((uint32_t(*)(uint32_t map,uint32_t* key))0x006d8b70)

/* ChartingAppPD_layerGetSurface  [RTTI]+[ren] -- a layer node's Coral surface.
 *   uint32_t layerGetSurface(uint32_t layer, uint32_t which);
 *   layer : *(uint32_t*)(node+0x14) from the lookup above.
 *   which : 1 for the primary surface.
 *   returns: a 16-byte surface descriptor pointer, or 0.
 *   surface descriptor (do NOT read past +0x10 -- a different heap object):
 *     +0x00 flags (bit 0x20 = VRAM-backed) | +0x01 bpp | +0x02 w (u16)
 *     +0x04 h (u16) | +0x08 mask | +0x0c base pointer (CPU-addressable VRAM/RAM)
 *   8bpp row pitch = round_up(w, 8). */
#define LAYER_SURF ((uint32_t(*)(uint32_t layer,uint32_t which))0x006d9064)

/* ============================================================================
 * 6. Chart repaint + the render pipeline
 * ============================================================================ */

/* FUN_008b64c0 -> POST_UI_MSG  [ren] -- enqueue an async message to the UI thread.
 *   void POST_UI_MSG(void* target, uint32_t msg, uint32_t arg);
 *   Effect: (*(*(*target+0x14)+0x9c))(target,msg,arg) -- enqueues and returns at
 *   once (~1 ms); the message is handled later on the display thread.
 *   The USE that matters to an overlay COE: post the native "render complete,
 *   redraw the UI" message UI_MSG_REDRAW (0x67) to a PhotoOverlayRC's message
 *   target (rc+0x20). Native then runs a full drawOverlays paint on its OWN thread
 *   -- which is the SAFE way to make native repaint from a background thread. Do
 *   NOT reach into a native composite synchronously to force a repaint (see the
 *   renderOverlayToSurface LANDMINE below).
 *   [emp] Ghidra misreports this as a 1-arg function; it takes 3. */
#define POST_UI_MSG   ((void(*)(void* target,uint32_t msg,uint32_t arg))0x008b64c0)
#define UI_MSG_REDRAW 0x67u    /* native's own "render complete, redraw UI" message id  */
#define RC_MSG_TARGET 0x20u    /* a PhotoOverlayRC's UI message target = rc+0x20         */

/* ChartingAppPD_markAerialDirty  [RTTI]+[ren] -- mark the aerial layer dirty and,
 * if pd+0x158 != 0, synchronously run renderOverlayToSurface.
 *   void markAerialDirty(uint32_t pd);
 *   LANDMINE [emp]: renderOverlayToSurface is a heavy, NO-MUTEX native composite.
 *     Driving it from a BACKGROUND thread against a window native may be tearing
 *     down (e.g. a page change) races native's own frame-driver on the same key
 *     buffers and WEDGES -> the hardware watchdog resets the unit (silent, no crash
 *     log). Call this ONLY on a repaint you own for a window you have confirmed
 *     live (e.g. via a registry scan), and prefer POST_UI_MSG(0x67) for a
 *     background-thread repaint. */
#define MARK_AERIAL_DIRTY ((void(*)(uint32_t pd))0x006daef0)

/* ChartingAppPD_markAerialServe  [RTTI]+[ren] -- set the serve gate (pd+0x158) so a
 * subsequent paint serves the aerial. Same LANDMINE family as markAerialDirty. */
#define MARK_AERIAL_SERVE ((void(*)(uint32_t pd))0x006daebc)

/* --- Render pipeline reference (SPLICE SITES, not call targets) --------------
 * These are where an overlay COE installs head-detours, not functions you call.
 * Listed for the pipeline shape + the displaced-prologue each detour must replay.
 *
 * ChartingAppPD_drawLayerByKind  @0x006d9a18  [RTTI]+[ren]  (vtable entry #4)
 *   The render dispatcher. Walks the kind map at this+0x64 and dispatches:
 *     kind 0x8   -> renderOverlayToSurface        (the overlay)
 *     kind 0x10  -> compositeLayers_6_3_2 + _4_6_1 (the basemap)
 *     kind 0x20  -> compositeLayers_4_6_1
 *     kind 0x100 -> compositeKey5_to_L3(this,0,this+0xf0)   (the AERIAL, key-5 -> L3)
 *
 * ChartingAppPD_compositeKey5_to_L3  @0x006da638  [RTTI]+[ren]
 *   The ONLY writer of the aerial to display plane L3 (blits key-5 -> L3). One
 *   caller (bl @0x006d9b4c inside drawLayerByKind). Prologue: e92d40f0 (stmdb
 *   {r4-r7,lr}); an 8-byte splice displaces two instrs -> continue at 0x006da640.
 *   [emp] on an NV2 / \RASTER card key-5 holds only its background colour 0x7f2b
 *   (set by configLayerColors_1to6, below), so this blit paints "no imagery";
 *   suppressing it discards nothing native had.
 *
 * ChartingAppPD_compositeLayers_6_3_2  @0x006da2f8  [RTTI]+[ren]
 *   Publishes the chart: blits key-3 (+key-2) -> key-6. An 8bpp INDEX copy, so a
 *   key-3 index remapped before this blit propagates unchanged. Prologue e92d44f0
 *   (stmdb {r4-r7,sl,lr}); continue at 0x006da300.
 *
 * ChartingAppPD_drawOverlays  @0x006d9b5c  [RTTI]+[ren]  (vtable entry #6)
 *   Per-paint overlay compositor; renders key-3 (FUN_006d4ef8). Tests flags
 *   &8/&0x10/&0x20 and IGNORES kind 0x100 -- which is why the aerial (kind 0x100)
 *   always lands after drawOverlays returns. Prologue e92d44f0; continue 0x006d9b64.
 *
 * ChartingAppPD_compositeLayers_4_6_1  @0x006d9f88  [RTTI]+[ren]
 *   Last stage before display plane L2 (key-4 <- key-6 + key-1 -> L2). Fires
 *   continuously (~10 Hz). Prologue e92d4cf0 (stmdb {r4-r7,r10,r11,lr}); continue
 *   at 0x006d9f90.
 *
 * ChartingAppPD_renderOverlayToSurface  @0x006daf7c  [RTTI]+[ren]
 *   Heavy native overlay composite. THREE synchronous, MUTEX-FREE callers
 *   (drawLayerByKind kind 8; markAerialServe; markAerialDirty). LANDMINE [emp]:
 *   never invoke it (directly or via markAerial*) from a background thread or
 *   re-entrantly from a paint hook -- it corrupts shared state / wedges the unit.
 *
 * ChartingAppPD_configLayerColors_1to6  @0x006db1ec  [RTTI]+[ren]
 *   Fills each layer's background colour (layer+0x28) from the palette via
 *   getItem -- the source of key-5's 0x7f2b "no data" land colour. Reference only.
 * -------------------------------------------------------------------------- */

/* ============================================================================
 * 7. Geographic projection  (ellipsoidal Mercator, semicircles)
 *
 * The display projection uses the International-1924 ellipsoid (a = 6378388), NOT
 * WGS84. Semicircles: degrees = value * 180 / 2^31. The provider hands out already
 * PROJECTED coordinates (easting @+0x16c, northing @+0x170 -- +0x170 is a mercator
 * northing, not a latitude).
 * ============================================================================ */

/* latLonToMercSemicircles  [ren] -- forward projection (geodetic -> mercator).
 *   void latLonToMercSemicircles(int32_t lat, int32_t lon, int32_t* out_e, int32_t* out_n);
 *   lat/lon in 1e-7 degrees; out_e = easting, out_n = mercator northing (semicircles).
 *   Registers by construction against the chart -- it is the firmware's own forward
 *   projection, so an overlay placed with it matches native's placement exactly. */
#define LATLON_TO_MERC ((void(*)(int32_t lat,int32_t lon,int32_t* out_e,int32_t* out_n))0x005a8540)

/* merc semicircles -> geodetic  [ren] -- inverse projection.
 *   void mercToLatLon(int32_t north, int32_t east, int32_t* out_lat, int32_t* out_lon);
 *   out_lat/out_lon in 1e-7 degrees. */
#define MERC_TO_LATLON ((void(*)(int32_t north,int32_t east,int32_t* out_lat,int32_t* out_lon))0x005a8650)

/* ============================================================================
 * 8. App data-item store  (the in-process DATABASE / DataProvider)
 *
 * The config/data store read by the DATABASE QUERY(getItem) / SetItem path. Items
 * are addressed by a two-axis (fid, enc) key. Full model in the public E80 firmware
 * docs (docs/e80_firmware/abstracts/DATABASE.md, DB_FIDS.md).
 * ============================================================================ */

/* DataProvider_instance  [ren] -- the config DataProvider singleton.
 *   void* DataProvider_instance(void);   returns *(void**)0x0044c874. */
#define DP_INSTANCE ((void*(*)(void))0x0044c530)

/* DataProvider_getItem  [ren] -- record-based read (provider vtable vmethod +0x8c).
 *   int getItem(void* provider, uint32_t fid, void* out_ConfigItem);
 *   out : a ~0x44-byte ConfigItem; store its expected ENC in the descriptor first.
 *   returns: 0x40000 on success; a negative value if the fid is not found.
 *   This is the ABI mod003 uses (DataProvider_instance -> [[provider]+0x8c]). */
#define DP_GETITEM ((int(*)(void* provider,uint32_t fid,void* out_ConfigItem))0x0044cec4)

/* DataProvider_getItemWithTransport  [ren] -- keyed read of one specific source. */
#define DP_GETITEM_XPORT ((int(*)(void* provider,uint32_t key,void* srcDesc,void* out))0x0044c698)

/* DataProvider_setItem  [ren] -- write one item.
 *   int setItem(void* provider, void* record_ConfigItem, uint32_t persist);
 *   record : a ConfigItem carrying fid + enc + value.
 *   persist: 1 = also serialize to the flob/NOR durable sink (provider+0x180);
 *            0 = RAM-only live write + listener notify, lost on reboot [emp].
 *   returns: 0x40000 on success. */
#define DP_SETITEM ((int(*)(void* provider,void* record_ConfigItem,uint32_t persist))0x0044c614)

/* ============================================================================
 * 9. JPEG decoder  (the firmware's own decompressor; drives one blob -> pixels)
 *
 * These are the pool of entry points a decode driver calls in sequence:
 *   create -> init -> set-source -> decode-headers -> prepare-output ->
 *   start-decompress -> [decode-1-row]* -> finish -> destroy.
 * mods/aerial.c's decode_blob is a hand-written driver over exactly these (packing
 * the RGB output to RGB555). Each is a position-independent absolute call target.
 * ============================================================================ */
#define JPEG_CREATE_DECODER   ((void*)0x00b2d040)   /* [ren] construct decoder object     */
#define JPEG_INIT             ((void*)0x00b28efc)   /* [ren] init(obj, 62, 428)           */
#define JPEG_SET_SOURCE       ((void*)0x00b06858)   /* [ren] set in-memory source (&desc) */
#define JPEG_DECODE_HEADERS   ((void*)0x00b28f9c)   /* [ren] read headers; 0 = fail       */
#define JPEG_PREPARE_OUTPUT   ((void*)0x00b2ad24)   /* [ren] fills W (+92) / H (+96) / comps (+104) */
#define JPEG_START_DECOMPRESS ((void*)0x00b29268)   /* [ren] begin scanline output        */
#define JPEG_DECODE_1_ROW     ((void*)0x00b293e4)   /* [ren] emit 1 scanline into *rowbuf; 0 = stop */
#define JPEG_FINISH           ((void*)0x00b291ac)   /* [ren] finish decompress             */
#define JPEG_DESTROY_DECODER  ((void*)0x00b28f98)   /* [ren] destroy decoder object        */

/* ============================================================================
 * 10. Runtime signals + key data (peeked, not called)
 * ============================================================================ */
/* FS_READY() -- the reliable filesystem-ready predicate: fx_media_id == MEDI. fx_media_open sets
 * this word LAST, after the boot-sector parse and the FAT reads, so FS_READY() true guarantees
 * fx_directory_* / fx_file_open will succeed. fx_media_close writes FS_MEDI_CLOSED. This is the
 * card signal our code gates on; the firmware maintains it off the electrical card-present bit
 * (*(0xb1e1fc), via cfCard_readCardDetect @0x00b1e208). */
#define FS_MEDIA_ID    (*(volatile uint32_t*)0x024ebddc)   /* FileX FX_MEDIA word0 (CF driver +0xa4) */
#define FS_MEDI_OPEN   0x4D454449u                          /* 'MEDI' -- media open, FAT parsed  */
#define FS_MEDI_CLOSED 0x4D454441u                          /* fx_media_close writes this        */
#define FS_READY()     (FS_MEDIA_ID == FS_MEDI_OPEN)
/* Display plane L3 (the 16bpp RGB555 aerial scanout plane): live CPU base is
 * 0xd6000000 + *(0xd7fd005c) (native programs the offset at boot). */
#define L3_BASE()   ((uint16_t*)(0xd6000000u + *(volatile uint32_t*)0xd7fd005c))
/* GDC2 CRTC panel geometry (E80 640x480 / E120 800x600): */
#define SCR_W()  (( *(volatile uint32_t*)0xd7fd0008        & 0xffff) + 1)
#define SCR_H()  (((*(volatile uint32_t*)0xd7fd0014 >> 16) & 0xffff) + 1)
/* Fujitsu Coral-PA drawing-engine status register (read-only): idle when
 * PS/DS/SS (bits 1:0 / 5:4 / 9:8) are all 0 and FE (bit 12) is 1. Full GDC2
 * register map is in docs/e80_firmware/architecture/display.md. */
#define CORAL_CTR   (*(volatile uint32_t*)0xd7ff0400)

/* ============================================================================
 * 11. Display planes -- taking one for our own overlay surface
 *
 * The GDC2 presents six display planes; the E-Series enables three (chrome L0,
 * application L2, photo L3). A COE can take a spare one and own it outright.
 * ============================================================================ */

/* PEG_SCREEN() -- the one PegCoralScreen singleton, set by Peg_initialize at boot.
 *   [emp] chart-window INDEPENDENT: it reads back identical to the older
 *   RC-registry chase (rc -> pd -> pd+0xe8) but needs no chart window to exist, so
 *   an overlay COE can take its plane at load time regardless of the current page.
 *   screen+0x38 / screen+0x3c are the panel width / height the firmware itself uses. */
#define PEG_SCREEN()  (*(void* volatile*)0x01867730)
#define PEG_SCREEN_W  0x38u
#define PEG_SCREEN_H  0x3cu

/* PegCoralScreen_bindLayerBitmap  [RTTI]+[ren] -- allocate a plane's backing bitmap and
 * program the plane, through the firmware's own path.
 *   void* bindLayerBitmap(void* screen, uint32_t layerIdx, uint32_t w, uint32_t h,
 *                         uint32_t winW, uint32_t winH, uint32_t bpp, uint32_t colorKey);
 *   winW/winH : 0 is accepted (window defaults to the bitmap); origin is (0,0).
 *   bpp       : 16 -> RGB555 (X1R5G5B5), no CLUT involved.
 *   returns   : nonzero on success.
 *   side effects: CoralVram_alloc's the bitmap itself (kind 2), programs base + geometry
 *     + color key, and FLUSHES the GDC2 command FIFO. For layerIdx != 0 it also builds a
 *     PEG wrapper object.
 *   TEARDOWN = the same call with w or h = 0: frees the bitmap and the wrapper, zeroes
 *     the descriptor. [emp] it does NOT clear the hardware enable, so the plane keeps
 *     scanning freed VRAM -- HIDE BEFORE YOU FREE. (An always-on plane never faces this.)
 *   LANDMINE [emp]: poking the plane registers directly INSTEAD of calling this leaves
 *     the geometry unlatched and the plane scans HORIZONTALLY ROTATED, with a stray line
 *     across the top. The register VALUES come out byte-identical either way -- only the
 *     FIFO latch differs -- so the fault is invisible until you look at asymmetric
 *     content. Always validate plane programming with an asymmetric test pattern; a box
 *     will lie to you. There is no poke-side workaround; this call is required. */
#define BIND_LAYER_BITMAP ((void*(*)(void* screen,uint32_t layerIdx,uint32_t w,uint32_t h,uint32_t winW,uint32_t winH,uint32_t bpp,uint32_t colorKey))0x00b15610)

/* PegCoralScreen_setLayerVisible  [RTTI]+[ren] -- show / hide a plane (device vtable +0xc4).
 *   void setLayerVisible(void* screen, uint32_t layerIdx, uint32_t enable);
 *   Wraps GDC2_enableLayer/disableLayer, takes the Coral mutex, and MAINTAINS THE RAM
 *   ENABLE SHADOW (*0x00b474fc + 0x128) that the firmware rebuilds the enable register
 *   from -- which is why this beats poking the enable register.
 *   GOTCHA [emp]: EDGE-TRIGGERED on descriptor +0x208. If descriptor and hardware are
 *     out of step it compares equal and SILENTLY DOES NOTHING -- exactly when you most
 *     want it to work. A force-off path must write the enable register directly. */
#define SET_LAYER_VISIBLE ((void(*)(void* screen,uint32_t layerIdx,uint32_t enable))0x00b15a20)

/* GDC2_setLayerWindow  [ren] -- position/size a plane's window on the panel.
 *   void setLayerWindow(uint32_t layerIdx, uint32_t x, uint32_t y, uint32_t w, uint32_t h);
 *   Writes the register block directly, takes effect immediately. Accepts 5 or 0x15
 *   for L5. Only needed to move a plane off (0,0). */
#define SET_LAYER_WINDOW ((void(*)(uint32_t layerIdx,uint32_t x,uint32_t y,uint32_t w,uint32_t h))0x00b47c64)

/* Per-plane descriptor block: screen + layerIdx*0x4c. The two fields a buffer writer
 * needs, both filled by bindLayerBitmap: */
#define LAYER_DESC(screen,idx)  ((u8*)(screen) + (idx)*0x4cu)
#define LDESC_BITMAP  0x1e0u    /* CPU-addressable VRAM base of the plane's bitmap */
#define LDESC_PITCH   0x228u    /* row pitch in PIXELS (16bpp: (w+0x1f) & ~0x1f)   */
#define LDESC_VISIBLE 0x208u    /* setLayerVisible's shadow -- the edge it triggers on */

/* GDC2 plane registers. Z-ORDER [emp] is SINGLE-WRITER: GDC2_setZOrder has exactly one
 * xref (CoralCompositor_init at display setup) and is never re-run, not even on a page
 * change -- so a float-to-top poke STICKS until a display re-init or a reboot. The
 * ENABLE register is a different story: it is rebuilt from the RAM shadow whenever the
 * firmware reprograms any layer, so go through SET_LAYER_VISIBLE rather than poking it.
 * The COLOR KEY register needs no enabling -- write the key colour and it is compared
 * (its bit31 is a separate feature, documented at GDC2_COLORKEY_BLACK_TOO below). */
#define GDC2_ENABLE_REG    (*(volatile uint32_t*)0xd7fd0100)
#define GDC2_ZORDER_REG    (*(volatile uint32_t*)0xd7fd0180)
#define GDC2_ZORDER_STOCK  0x00543210u   /* front..back [0,1,2,3,4,5] -- L5 is BACKMOST */
#define GDC2_ZORDER_L5_TOP 0x00432105u   /* front..back [5,0,1,2,3,4] -- L5 to the front */
#define GDC2_COLORKEY_REG(n) (*(volatile uint32_t*)(0xd7fd01a0u + (n)*4u))

/* [emp] BIT31 IS NOT AN ENABLE. The key comparison runs with it CLEAR -- a plane whose key
 * register holds a bare colour value already renders that colour transparent (measured: the
 * key band vanished with bit31 clear). What bit31 adds is a SECOND transparent value:
 * BLACK, 0x0000. Set it, and every black pixel on the plane becomes see-through as well.
 *
 * LANDMINE [emp]: that silently eats black TEXT and any black artwork, while leaving every
 * other colour untouched -- so a filled card and its title bar survive and only the letters
 * vanish, showing the layers behind through the glyph strokes. The buffer reads back
 * perfect, because the pixels are correct and are being discarded at scan-out. It looks
 * like corruption that varies with position, since what shows through changes across the
 * screen, and it defeats every value-based or geometry-based explanation. Leave bit31 CLEAR
 * unless transparent black is genuinely wanted. */
#define GDC2_COLORKEY_BLACK_TOO 0x80000000u

/* Raw pool allocation, for a COE that wants a surface bindLayerBitmap does not give it:
 *   CoralVram_alloc          @0x00b14960  [ren] VRAM pool alloc (separate from
 *       rm_malloc); 4 pools at screenObj+0x1b40[k], screenObj = *(PD+0xe8).
 *   CoralScreen_allocSurface @0x00b154dc  [ren] allocate a 16-byte surface
 *       descriptor (= device-vtable +0xac). Layout as in section 5. */

#endif /* E569_H */
