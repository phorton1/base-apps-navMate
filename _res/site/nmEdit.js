// nmEdit.js - navMate track/route editing
// Vertex drag/insert/delete, trim, split, join, append, and round-trip update.
// Depends on globals from map.js: map, editSubject, deselectFeature(), hideInfo(), abgrToCSS()

// ---- Edit state ----

let editMode   = false;
let splitMode  = false;
let appendMode = false;   // false | 'start' | 'end'

let rubberBandLine   = null;
let rubberBandAnchor = null;

let vtxHandles = [];   // L.Marker, one per vertex
let midHandles = [];   // L.Marker, one per segment midpoint
let midDragIdx = -1;   // index in layer LatLngs of the vertex being drag-inserted

// ---- Join state ----

let joinMode  = false;
let joinPhase = '';       // 'pickEndA' | 'pickTrackB' | 'pickStartB' | 'preview'
let joinTrackA = null;
let joinIdxA   = -1;
let joinTrackB = null;
let joinIdxB   = -1;
let joinPreviewLayers = [];

// ---- Icons ----

const vtxIcon      = L.divIcon({ className: 'nm-vtx',              iconSize: [12, 12], iconAnchor: [6, 6] });
const vtxStartIcon = L.divIcon({ className: 'nm-vtx nm-vtx-start', iconSize: [12, 12], iconAnchor: [6, 6] });
const vtxEndIcon   = L.divIcon({ className: 'nm-vtx nm-vtx-end',   iconSize: [12, 12], iconAnchor: [6, 6] });
const midIcon      = L.divIcon({ className: 'nm-mid',              iconSize: [8,   8], iconAnchor: [4, 4] });

// ---- Context menu ----

const ctxMenuDiv = document.createElement('div');
ctxMenuDiv.id = 'nm-ctx-menu';
ctxMenuDiv.style.display = 'none';
(function() {
    function makeBtn(id, text, fn) {
        const b = document.createElement('button');
        b.id          = id;
        b.textContent = text;
        b.onclick     = fn;
        ctxMenuDiv.appendChild(b);
    }
    makeBtn('nm-ctx-edit',      'Edit Track',      function() { enterEditMode();       });
    makeBtn('nm-ctx-join',      'Join Track',      function() { enterJoinMode();       });
    makeBtn('nm-ctx-create',    'Create Route',    function() { startCreateRoute();    });
    makeBtn('nm-ctx-create-wp', 'Create Waypoint', function() { startCreateWaypoint(); });
    makeBtn('nm-ctx-edit-wp',   'Edit Waypoint',   function() { editWaypointFromCtx();   });
    makeBtn('nm-ctx-move-wp',   'Move Waypoint',   function() { startMoveWaypoint();     });
    makeBtn('nm-ctx-delete-wp', 'Delete Waypoint', function() { deleteWaypointFromCtx(); });
}());
document.body.appendChild(ctxMenuDiv);

function hideCtxMenu() {
    ctxMenuDiv.style.display = 'none';
}

function showCtxMenu(x, y, mode) {
    const editBtn     = document.getElementById('nm-ctx-edit');
    const joinBtn     = document.getElementById('nm-ctx-join');
    const createBtn   = document.getElementById('nm-ctx-create');
    const createWpBtn = document.getElementById('nm-ctx-create-wp');
    const editWpBtn   = document.getElementById('nm-ctx-edit-wp');
    const deleteWpBtn = document.getElementById('nm-ctx-delete-wp');
    const moveWpBtn   = document.getElementById('nm-ctx-move-wp');
    const show = function(b, on) { if (b) b.style.display = on ? 'block' : 'none'; };
    if (mode === 'map') {
        show(editBtn, false); show(joinBtn, false);
        show(createBtn, true); show(createWpBtn, true); show(editWpBtn, false); show(deleteWpBtn, false);
        show(moveWpBtn, false);
    } else if (mode === 'waypoint') {
        // Every right-clickable marker is a Waypoint record, so all are movable --
        // including those whose wp_type is "route_pt" (that is only a display/symbol
        // type, NOT a structural route_pt reference).  Real route_pts are route
        // members, not markers; they are only editable as vertices in route-edit mode.
        show(editBtn, false); show(joinBtn, false);
        show(createBtn, false); show(createWpBtn, false); show(editWpBtn, true); show(deleteWpBtn, true);
        show(moveWpBtn, true);
    } else {
        const isRoute   = editSubject && editSubject.props.obj_type === 'route';
        const isDbTrack = editSubject && editSubject.props.data_source === 'db'
                                      && editSubject.props.obj_type === 'track';
        if (editBtn) editBtn.textContent = isRoute ? 'Edit Route' : 'Edit Track';
        show(editBtn, true);
        show(joinBtn, isDbTrack);
        show(createBtn, false); show(createWpBtn, false); show(editWpBtn, false); show(deleteWpBtn, false);
        show(moveWpBtn, false);
    }
    ctxMenuDiv.style.display = 'block';
    const cw = ctxMenuDiv.offsetWidth;
    const ch = ctxMenuDiv.offsetHeight;
    ctxMenuDiv.style.left = (x + cw > window.innerWidth  ? x - cw : x) + 'px';
    ctxMenuDiv.style.top  = (y + ch > window.innerHeight ? y - ch : y) + 'px';
}

// ---- Edit bar ----

let editSplitHint;
let appendStartBtn, appendEndBtn, createDoneBtn;
const editBarDiv = document.createElement('div');
editBarDiv.id = 'nm-edit-bar';
editBarDiv.style.display = 'none';
(function() {
    function makeBtn(text, cls, fn) {
        const b = document.createElement('button');
        b.textContent = text;
        if (cls) b.className = cls;
        b.onclick = fn;
        editBarDiv.appendChild(b);
        return b;
    }
    makeBtn('< Trim start', '', function() { doTrim('start');           });
    makeBtn('Trim end >',   '', function() { doTrim('end');             });
    appendStartBtn = makeBtn('+Start', '', function() { toggleAppendMode('start'); });
    appendEndBtn   = makeBtn('+End',   '', function() { toggleAppendMode('end');   });
    makeBtn('Split...', '', function() { enterSplitMode(); });
    createDoneBtn = makeBtn('Done',    'nm-btn-confirm', function() { exitEditMode(true); });
    makeBtn('Confirm',                 'nm-btn-confirm', function() { exitEditMode(true); });
    makeBtn('Cancel',                  'nm-btn-cancel',  function() { exitEditMode(false); });
    const hint = document.createElement('span');
    hint.className   = 'nm-split-hint';
    hint.textContent = 'Click on track to select split vertex';
    editBarDiv.appendChild(hint);
    editSplitHint         = hint;
    createDoneBtn.style.display = 'none';
}());
document.body.appendChild(editBarDiv);

// ---- Join bar ----

let joinHint;
let joinConfirmBtn;
const joinBarDiv = document.createElement('div');
joinBarDiv.id = 'nm-join-bar';
joinBarDiv.style.display = 'none';
(function() {
    const hint = document.createElement('span');
    hint.className = 'nm-join-hint';
    joinBarDiv.appendChild(hint);
    joinHint = hint;
    function makeBtn(text, cls, fn) {
        const b = document.createElement('button');
        b.textContent = text;
        if (cls) b.className = cls;
        b.onclick = fn;
        joinBarDiv.appendChild(b);
        return b;
    }
    joinConfirmBtn = makeBtn('Confirm Join', 'nm-btn-confirm', function() { confirmJoin();    });
    makeBtn('Cancel',                        'nm-btn-cancel',  function() { exitJoinMode();   });
}());
document.body.appendChild(joinBarDiv);

function showJoinBar(hintText, showConfirm) {
    joinHint.textContent = hintText;
    joinConfirmBtn.style.display = showConfirm ? '' : 'none';
    joinBarDiv.style.display = 'flex';
}

// ---- Map event handlers ----

map.on('click', function(e) {
    if (moveMode) { placeMovePoint(e.latlng); return; }
    if (appendMode && editSubject) {
        const lls = editSubject.layer.getLatLngs();
        if (appendMode === 'end') {
            lls.push(e.latlng);
            if (editSubject.editUuids) editSubject.editUuids.push(null);
        } else {
            lls.unshift(e.latlng);
            if (editSubject.editUuids) editSubject.editUuids.unshift(null);
        }
        editSubject.layer.setLatLngs(lls);
        rubberBandAnchor = appendMode === 'end' ? lls[lls.length - 1] : lls[0];
        if (!rubberBandLine) {
            rubberBandLine = L.polyline([rubberBandAnchor, rubberBandAnchor], {
                color: '#ffff00', weight: 2, dashArray: '5 5', interactive: false
            }).addTo(map);
        } else {
            rubberBandLine.setLatLngs([rubberBandAnchor, rubberBandAnchor]);
        }
        buildHandles();
        return;
    }
    if (!editMode && !joinMode) deselectFeature();
});

map.on('mousemove', function(e) {
    if (moveMode) { if (!moveProposed) _updateMovePoint(e.latlng); return; }
    if (!appendMode || !rubberBandLine || !rubberBandAnchor) return;
    rubberBandLine.setLatLngs([rubberBandAnchor, e.latlng]);
});

map.on('contextmenu', function(e) {
    if (moveMode) { exitMoveMode(); return; }
    if (editMode || joinMode || appendMode) return;
    ctxMenuLatLng = e.latlng;
    ctxMenuXY     = { x: e.originalEvent.clientX, y: e.originalEvent.clientY };
    showCtxMenu(e.originalEvent.clientX, e.originalEvent.clientY, 'map');
});

// Dismiss the context menu on any click/drag outside it.  Capture phase so
// Leaflet feature handlers that stopPropagation() can't swallow the event;
// the contains() guard lets clicks on the menu's own buttons through.
document.addEventListener('mousedown', function(e) {
    if (ctxMenuDiv.style.display === 'none') return;
    if (ctxMenuDiv.contains(e.target)) return;
    hideCtxMenu();
}, true);

document.addEventListener('keydown', function(e) {
    if (e.key !== 'Escape') return;
    hideCtxMenu();
    if (wpDialogState) { closeWaypointDialog(); return; }
    if (moveMode)      { exitMoveMode();        return; }
    if (appendMode) {
        exitAppendMode();
    } else if (joinMode) {
        exitJoinMode();
    } else if (splitMode) {
        splitMode = false;
        editSplitHint.style.display = 'none';
        if (editSubject) buildHandles();
        editBarDiv.style.display = 'flex';
    } else if (editMode) {
        exitEditMode(false);
    } else {
        deselectFeature();
    }
});

// ---- Append mode ----

function enterAppendMode(which) {
    if (!editMode || !editSubject || splitMode) return;
    exitAppendMode();
    appendMode = which;
    const lls = editSubject.layer.getLatLngs();
    if (lls.length > 0) {
        rubberBandAnchor = which === 'start' ? lls[0] : lls[lls.length - 1];
        rubberBandLine   = L.polyline([rubberBandAnchor, rubberBandAnchor], {
            color: '#ffff00', weight: 2, dashArray: '5 5', interactive: false
        }).addTo(map);
    }
    _updateAppendButtons();
}

function exitAppendMode() {
    if (!appendMode) return;
    appendMode = false;
    if (rubberBandLine) { map.removeLayer(rubberBandLine); rubberBandLine = null; }
    rubberBandAnchor = null;
    _updateAppendButtons();
}

function toggleAppendMode(which) {
    if (appendMode === which) { exitAppendMode(); return; }
    enterAppendMode(which);
}

function _updateAppendButtons() {
    if (appendStartBtn) appendStartBtn.className = appendMode === 'start' ? 'nm-btn-active' : '';
    if (appendEndBtn)   appendEndBtn.className   = appendMode === 'end'   ? 'nm-btn-active' : '';
}

// ---- Vertex handle management ----

function clearHandles() {
    vtxHandles.forEach(function(h) { map.removeLayer(h); });
    midHandles.forEach(function(h) { map.removeLayer(h); });
    vtxHandles = [];
    midHandles = [];
}

function buildHandles() {
    clearHandles();
    if (!editSubject) return;
    const lls  = editSubject.layer.getLatLngs();
    const last = lls.length - 1;
    lls.forEach(function(ll, i) {
        const icon = i === 0 ? vtxStartIcon : i === last ? vtxEndIcon : vtxIcon;
        const h = L.marker(ll, { icon: icon, draggable: !joinMode, zIndexOffset: 1000 }).addTo(map);
        h.on('drag',    function() { if (!splitMode) syncPolyline(); });
        h.on('dragend', function() { if (!splitMode) buildMidHandles(); });
        h.on('click', function(e) {
            L.DomEvent.stopPropagation(e);
            const idx  = vtxHandles.indexOf(this);
            const hlast = vtxHandles.length - 1;
            if (splitMode) {
                doSplitAtIdx(idx);
            } else if (joinMode && joinPhase === 'pickEndA') {
                setJoinEndA(idx);
            } else if (joinMode && joinPhase === 'pickStartB') {
                setJoinStartB(idx);
            } else if (editMode) {
                if (idx === 0) {
                    const was = appendMode === 'start';
                    exitAppendMode();
                    if (!was) enterAppendMode('start');
                } else if (idx === hlast) {
                    const was = appendMode === 'end';
                    exitAppendMode();
                    if (!was) enterAppendMode('end');
                }
            }
        });
        h.on('contextmenu', function(e) {
            if (splitMode || joinMode) return;
            L.DomEvent.stopPropagation(e);
            const idx = vtxHandles.indexOf(this);
            if (idx !== -1) deleteVertex(idx);
        });
        vtxHandles.push(h);
    });
    if (!joinMode) buildMidHandles();
}

function buildMidHandles() {
    midHandles.forEach(function(h) { map.removeLayer(h); });
    midHandles = [];
    if (!editSubject) return;
    const lls = editSubject.layer.getLatLngs();
    for (let i = 0; i < lls.length - 1; i++) {
        const mid = L.latLng((lls[i].lat + lls[i + 1].lat) / 2,
                             (lls[i].lng + lls[i + 1].lng) / 2);
        const h = L.marker(mid, { icon: midIcon, draggable: true, zIndexOffset: 900 }).addTo(map);
        h.on('dragstart', function() {
            const idx  = midHandles.indexOf(this);
            if (idx === -1) return;
            const lls  = editSubject.layer.getLatLngs();
            const midLl = this.getLatLng();
            lls.splice(idx + 1, 0, midLl);
            editSubject.layer.setLatLngs(lls);
            if (editSubject.editUuids) editSubject.editUuids.splice(idx + 1, 0, null);
            midDragIdx = idx + 1;
        });
        h.on('drag', function() {
            if (midDragIdx === -1) return;
            const lls = editSubject.layer.getLatLngs();
            lls[midDragIdx] = this.getLatLng();
            editSubject.layer.setLatLngs(lls);
        });
        h.on('dragend', function() {
            midDragIdx = -1;
            buildHandles();
        });
        h.on('click', function(e) {
            L.DomEvent.stopPropagation(e);
            const idx = midHandles.indexOf(this);
            if (idx !== -1) insertVertex(idx);
        });
        midHandles.push(h);
    }
}

function syncPolyline() {
    if (!editSubject) return;
    editSubject.layer.setLatLngs(vtxHandles.map(function(h) { return h.getLatLng(); }));
}

function deleteVertex(idx) {
    const lls = editSubject.layer.getLatLngs();
    if (lls.length <= 2) return;
    lls.splice(idx, 1);
    editSubject.layer.setLatLngs(lls);
    if (editSubject.editUuids) editSubject.editUuids.splice(idx, 1);
    buildHandles();
}

function insertVertex(afterIdx) {
    const lls = editSubject.layer.getLatLngs();
    const a = lls[afterIdx], b = lls[afterIdx + 1];
    lls.splice(afterIdx + 1, 0, L.latLng((a.lat + b.lat) / 2, (a.lng + b.lng) / 2));
    editSubject.layer.setLatLngs(lls);
    if (editSubject.editUuids) editSubject.editUuids.splice(afterIdx + 1, 0, null);
    buildHandles();
}

// ---- Enter / exit edit mode ----

function enterEditMode() {
    if (!editSubject || editMode) return;
    editMode = true;
    if (editSubject.type === 'route') {
        editSubject.editUuids = editSubject.origCoords.map(function(c) { return c.uuid; });
    }
    hideCtxMenu();
    hideInfo();
    buildHandles();
    editBarDiv.style.display = 'flex';
}

function exitEditMode(doConfirm) {
    if (!editMode || !editSubject) return;
    exitAppendMode();
    splitMode = false;
    editSplitHint.style.display = 'none';
    if (createDoneBtn) createDoneBtn.style.display = 'none';
    clearHandles();
    editMode = false;
    editBarDiv.style.display = 'none';
    const creating = editSubject.creating;
    if (doConfirm) {
        if (editSubject.type === 'route' && creating) {
            submitCreateRoute();
        } else if (editSubject.type === 'route') {
            submitRouteUpdate();
        } else {
            submitTrackUpdate();
        }
    } else {
        if (creating) {
            map.removeLayer(editSubject.layer);
            editSubject = null;
        } else if (editSubject.type === 'route') {
            editSubject.layer.setLatLngs(
                editSubject.origCoords.map(function(c) { return L.latLng(c.lat, c.lon); })
            );
            deselectFeature();
        } else {
            editSubject.layer.setLatLngs(
                editSubject.origCoords.map(function(c) { return L.latLng(c[0], c[1]); })
            );
            deselectFeature();
        }
    }
}

// ---- Trim ----

function doTrim(end) {
    if (!editMode || !editSubject) return;
    const lls = editSubject.layer.getLatLngs();
    if (lls.length <= 2) return;
    if (end === 'start') {
        lls.shift();
        if (editSubject.editUuids) editSubject.editUuids.shift();
    } else {
        lls.pop();
        if (editSubject.editUuids) editSubject.editUuids.pop();
    }
    editSubject.layer.setLatLngs(lls);
    buildHandles();
}

// ---- Split ----

function enterSplitMode() {
    if (!editMode || !editSubject) return;
    splitMode = true;
    editSplitHint.style.display = 'inline';
}

function doSplitAtIdx(vertexIdx) {
    if (editSubject && editSubject.type === 'route') {
        doSplitRouteAtIdx(vertexIdx);
        return;
    }
    doSplitTrackAtIdx(vertexIdx);
}

function doSplitTrackAtIdx(vertexIdx) {
    splitMode = false;
    editSplitHint.style.display = 'none';
    const lls = editSubject.layer.getLatLngs();
    if (vertexIdx <= 0 || vertexIdx >= lls.length - 1) {
        editMode = true;
        editBarDiv.style.display = 'flex';
        buildHandles();
        return;
    }
    editMode = false;
    editBarDiv.style.display = 'none';
    clearHandles();
    const defaultName = editSubject.props.name + '-2';
    const newName = window.prompt('Name for the second track segment:', defaultName);
    if (newName === null) {
        editMode = true;
        editBarDiv.style.display = 'flex';
        buildHandles();
        return;
    }
    const payload = {
        op:        'split',
        uuid:      editSubject.props.uuid,
        source:    editSubject.props.data_source,
        split_idx: vertexIdx,
        new_name:  newName.trim() || defaultName,
    };
    deselectFeature();
    fetch('/track/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

function doSplitRouteAtIdx(vertexIdx) {
    splitMode = false;
    editSplitHint.style.display = 'none';
    const lls = editSubject.layer.getLatLngs();
    if (vertexIdx <= 0 || vertexIdx >= lls.length - 1) {
        editMode = true;
        editBarDiv.style.display = 'flex';
        buildHandles();
        return;
    }
    editMode = false;
    editBarDiv.style.display = 'none';
    clearHandles();
    const defaultName = editSubject.props.name + '-2';
    const newName = window.prompt('Name for the second route segment:', defaultName);
    if (newName === null) {
        editMode = true;
        editBarDiv.style.display = 'flex';
        buildHandles();
        return;
    }
    const payload = {
        op:        'split',
        source:    'db',
        uuid:      editSubject.props.uuid,
        split_idx: vertexIdx,
        new_name:  newName.trim() || defaultName,
    };
    deselectFeature();
    fetch('/route/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

// ---- Submit updates ----

function submitTrackUpdate() {
    const lls    = editSubject.layer.getLatLngs();
    const coords = lls.map(function(ll) { return [ll.lat, ll.lng]; });
    const payload = {
        op:     'update',
        uuid:   editSubject.props.uuid,
        source: editSubject.props.data_source,
        coords: coords,
    };
    deselectFeature();
    fetch('/track/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

function submitRouteUpdate() {
    const lls      = editSubject.layer.getLatLngs();
    const uuids    = editSubject.editUuids || [];
    const waypoints = lls.map(function(ll, i) {
        return { uuid: uuids[i] || null, lat: ll.lat, lon: ll.lng };
    });
    const payload = {
        op:        'full_update',
        source:    'db',
        uuid:      editSubject.props.uuid,
        waypoints: waypoints,
    };
    deselectFeature();
    fetch('/route/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

function submitCreateRoute() {
    const lls      = editSubject.layer.getLatLngs();
    const name     = editSubject.props.name;
    const collUuid = editSubject.createCollUuid;
    map.removeLayer(editSubject.layer);
    editSubject = null;
    if (lls.length < 2) return;
    const waypoints = lls.map(function(ll) {
        return { uuid: null, lat: ll.lat, lon: ll.lng };
    });
    const payload = {
        op:              'create',
        source:          'db',
        name:            name,
        collection_uuid: collUuid,
        waypoints:       waypoints,
    };
    fetch('/route/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

// ---- Create Route ----

// The destination collection now comes from the DB-tree selection (same gate
// as Create Waypoint), replacing the old prompt('Collection UUID:').
function startCreateRoute() {
    hideCtxMenu();
    fetchMapDest(function(dest) {
        if ((dest.store || 'db') !== 'db') {       // route creation is database-only
            showMapMessage('Route creation is database-only.\nSelect a destination in the Database window.');
            return;
        }
        const name = window.prompt('Route name:');
        if (!name) return;
        beginCreateRoute(name, dest.collection_uuid);
    });
}

function beginCreateRoute(name, collUuid) {
    const line = L.polyline([], { color: '#ffff00', weight: 2 }).addTo(map);
    editSubject = {
        layer:          line,
        props:          { uuid: null, name: name, obj_type: 'route', data_source: 'db', color: 'ff00ffffff' },
        origCoords:     [],
        type:           'route',
        createCollUuid: collUuid,
        creating:       true,
        editUuids:      [],
    };

    editMode = true;
    hideInfo();
    buildHandles();
    editBarDiv.style.display = 'flex';
    if (createDoneBtn) createDoneBtn.style.display = '';
    enterAppendMode('end');
}

// ---- Waypoint create / edit dialog ----
//
// Shared overlay dialog (mode = create | edit) reached from the map context
// menu (Create Waypoint) and from a right-click on a db waypoint marker
// (Edit Waypoint).  Fields: name, wp_type (drives sym), sym picker.  The
// create destination is the DB-tree selection resolved by GET /api/dest;
// saves POST /waypoint/save.  WP_TYPE_* come from map.js; the tables below
// mirror apps/navMate/n_defs.pm.

const WP_TYPE_NAMES   = ['nav','route_pt','sounding','label','hazard','shipwreck','fish','diving','poi'];
const WP_DEFAULT_SYMS = [2, 4, 11, 3, 7, 14, 25, 23, 9];   // E80 sym number per wp_type
const WP_SYM_CHOICES  = [2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,
                         22,23,24,25,26,27,28,29,30,31,32,33,34,35];
const E80_SYM_NAMES = {                           // from a_utils.pm E80_SYM_*
    2:'Square', 3:'Triangle', 4:'Diamond', 5:'Shaded Diamond', 6:'Anchor',
    7:'Skull', 8:'Square X', 9:'Triangle (i)', 10:'Down Triangle (T)',
    11:'Circle (MOB)', 12:'Buoy', 13:'Sailboat', 14:'Shipwreck', 15:'Cocktail',
    16:'Swimmer', 17:'Exclamation', 18:'Cloud', 19:'Tree', 20:'Reef',
    21:'Weeds', 22:'Dive Flag', 23:'Blue Flag', 24:'Big Fish', 25:'Fish',
    26:'Fish *', 27:'Fish **', 28:'Fish ***', 29:'Two Fish', 30:'Swordfish',
    31:'Dolphin', 32:'Shark', 33:'Lobster', 34:'Sportfisher', 35:'Trawler',
};

// Color: mirrors the app's double picker (winMultiEditor) -- the 6 standard E80
// colors OR a full-spectrum custom color.  Stored value is ABGR hex "aabbggrr"
// (n_utils.pm @E80_ROUTE_COLOR_ABGR); map.js abgrToCSS renders it.
const E80_COLOR_ABGR   = ['ff0000ff','ff00ffff','ff00ff00','ffff0000','ffff00ff','ffffffff'];
const E80_COLOR_NAMES  = ['Red','Yellow','Green','Blue','Purple','Black (White on Map)'];
const WP_DEFAULT_COLOR = 'ff00ff00';   // green -- the ff..ff "white" default looked bad

function abgrToHex6(abgr) {                       // "aabbggrr" -> "#rrggbb"
    abgr = (abgr || '').toLowerCase();
    if (abgr.length < 8) return '#00ff00';
    return '#' + abgr.slice(6, 8) + abgr.slice(4, 6) + abgr.slice(2, 4);
}
function hex6ToAbgr(hex6) {                       // "#rrggbb" -> "aabbggrr"
    const h = (hex6 || '').replace('#', '');
    if (h.length < 6) return WP_DEFAULT_COLOR;
    return ('ff' + h.slice(4, 6) + h.slice(2, 4) + h.slice(0, 2)).toLowerCase();
}

const MAP_DEST_MSG = 'Select a single destination node\nin the database tree to create new items';

let ctxMenuLatLng = null;   // map latlng of the last right-click (Create Waypoint)
let ctxMenuXY     = null;   // screen x/y of the last right-click
let ctxWaypoint   = null;   // {uuid, props, screenXY} stashed for Edit Waypoint
let wpDialogState = null;   // {mode, latlng, dest, uuid} while the dialog is open
let wpSelectedSym = null;
let wpColor       = WP_DEFAULT_COLOR;
let wpSaveSeq     = 0;       // client seq matched against /waypoint/result
let wpSaving      = false;   // a save is in flight (guards double-submit)

const STORE_LABELS = { db: 'Database', e80: 'E80', fsh: 'FSH' };

// transient toast for the "select a single destination" guidance
const mapMsgDiv = document.createElement('div');
mapMsgDiv.id = 'nm-wp-msg';
mapMsgDiv.style.display = 'none';
document.body.appendChild(mapMsgDiv);
let mapMsgTimer = null;
function showMapMessage(msg) {
    mapMsgDiv.classList.remove('nm-wp-msg-error');   // amber guidance
    mapMsgDiv.textContent = msg;
    mapMsgDiv.style.display = 'block';
    if (mapMsgTimer) clearTimeout(mapMsgTimer);
    mapMsgTimer = setTimeout(function() { mapMsgDiv.style.display = 'none'; }, 3500);
}

// Save rejection (preflight / spoke error) -- red, and the dialog stays open.
function showSaveError(msg) {
    mapMsgDiv.classList.add('nm-wp-msg-error');
    mapMsgDiv.textContent = msg;
    mapMsgDiv.style.display = 'block';
    if (mapMsgTimer) clearTimeout(mapMsgTimer);
    mapMsgTimer = setTimeout(function() {
        mapMsgDiv.style.display = 'none';
        mapMsgDiv.classList.remove('nm-wp-msg-error');
    }, 4500);
}

// GET /api/dest, then run cb(dest) only if a single destination is selected;
// otherwise show the guidance toast.
function fetchMapDest(cb) {
    fetch('/api/dest').then(function(r) { return r.json(); }).then(function(dest) {
        if (!dest || !dest.ok) { showMapMessage(MAP_DEST_MSG); return; }
        cb(dest);
    }).catch(function() {});
}

// Fixed-width row label so all the controls left-align in a column.
function wpLabel(text) {
    const s = document.createElement('span');
    s.className = 'nm-wp-label';
    s.textContent = text;
    return s;
}

// Build the dialog DOM once.
const wpDialogDiv = document.createElement('div');
wpDialogDiv.id = 'nm-wp-dialog';
wpDialogDiv.style.display = 'none';
let wpDialogTitle, wpNameInput, wpNameHint, wpTypeSelect, wpTypeRow,
    wpSymDD, wpSymBtn, wpSymBtnImg, wpSymBtnLabel, wpSymPanel,
    wpColorSelect, wpColorInput, wpColorRow;
(function() {
    wpDialogTitle = document.createElement('div');
    wpDialogTitle.className = 'nm-wp-title';
    wpDialogDiv.appendChild(wpDialogTitle);

    const nameRow = document.createElement('label');
    nameRow.className = 'nm-wp-row';
    nameRow.appendChild(wpLabel('Name'));
    wpNameInput = document.createElement('input');
    wpNameInput.type = 'text';
    nameRow.appendChild(wpNameInput);
    wpNameHint = document.createElement('span');
    wpNameHint.className = 'nm-wp-hint';
    wpNameHint.textContent = 'max 15';
    wpNameHint.style.display = 'none';
    nameRow.appendChild(wpNameHint);
    wpDialogDiv.appendChild(nameRow);

    wpTypeRow = document.createElement('label');
    wpTypeRow.className = 'nm-wp-row';
    wpTypeRow.appendChild(wpLabel('Type'));
    wpTypeSelect = document.createElement('select');
    wpTypeSelect.addEventListener('change', function() {
        selectSym(WP_DEFAULT_SYMS[+wpTypeSelect.value]);   // type drives sym
    });
    wpTypeRow.appendChild(wpTypeSelect);
    wpDialogDiv.appendChild(wpTypeRow);

    // Symbol: a custom dropdown showing icon + name per row (a native <select>
    // can't render images in its options).  A div, not a <label>, so option
    // clicks don't re-trigger the labelled button.
    const symRow = document.createElement('div');
    symRow.className = 'nm-wp-row';
    symRow.appendChild(wpLabel('Symbol'));

    wpSymDD = document.createElement('div');
    wpSymDD.className = 'nm-wp-symdd';
    wpSymBtn = document.createElement('button');
    wpSymBtn.type = 'button';
    wpSymBtn.className = 'nm-wp-symdd-btn';
    wpSymBtnImg = document.createElement('img');
    wpSymBtnLabel = document.createElement('span');
    wpSymBtnLabel.className = 'nm-wp-symdd-name';
    const symCaret = document.createElement('span');
    symCaret.className = 'nm-wp-symdd-caret';   // triangle drawn in CSS (ASCII-only source)
    wpSymBtn.appendChild(wpSymBtnImg);
    wpSymBtn.appendChild(wpSymBtnLabel);
    wpSymBtn.appendChild(symCaret);
    wpSymBtn.addEventListener('click', toggleSymPanel);
    wpSymDD.appendChild(wpSymBtn);

    wpSymPanel = document.createElement('div');
    wpSymPanel.className = 'nm-wp-symdd-panel';
    wpSymPanel.style.display = 'none';
    WP_SYM_CHOICES.forEach(function(s) {
        const opt = document.createElement('div');
        opt.className = 'nm-wp-symdd-opt';
        opt.dataset.sym = s;
        const img = document.createElement('img');
        img.src = '/sym/native/' + String(s).padStart(2, '0') + '.png';
        const nm = document.createElement('span');
        nm.textContent = E80_SYM_NAMES[s] || ('Sym ' + s);
        opt.appendChild(img);
        opt.appendChild(nm);
        opt.addEventListener('click', function() { selectSym(s); closeSymPanel(); });
        wpSymPanel.appendChild(opt);
    });
    wpSymDD.appendChild(wpSymPanel);

    symRow.appendChild(wpSymDD);
    wpDialogDiv.appendChild(symRow);

    // Color: standard E80 colors pulldown + a swatch that is itself the
    // full-spectrum picker (click it).  Mirrors the app's double picker.
    wpColorRow = document.createElement('label');
    wpColorRow.className = 'nm-wp-row';
    wpColorRow.appendChild(wpLabel('Color'));
    wpColorSelect = document.createElement('select');
    E80_COLOR_NAMES.forEach(function(nm, i) {
        const opt = document.createElement('option');
        opt.value = E80_COLOR_ABGR[i];
        opt.textContent = nm;
        wpColorSelect.appendChild(opt);
    });
    const customOpt = document.createElement('option');
    customOpt.value = 'custom';
    customOpt.textContent = 'Custom...';
    wpColorSelect.appendChild(customOpt);
    wpColorSelect.addEventListener('change', onColorSelectChange);
    wpColorRow.appendChild(wpColorSelect);
    wpColorInput = document.createElement('input');
    wpColorInput.type = 'color';
    wpColorInput.className = 'nm-wp-swatch';
    wpColorInput.addEventListener('input', onColorPicked);
    wpColorRow.appendChild(wpColorInput);
    wpDialogDiv.appendChild(wpColorRow);

    const btnRow = document.createElement('div');
    btnRow.className = 'nm-wp-buttons';
    const saveBtn = document.createElement('button');
    saveBtn.textContent = 'Save';
    saveBtn.className = 'nm-btn-confirm';
    saveBtn.addEventListener('click', saveWaypoint);
    const cancelBtn = document.createElement('button');
    cancelBtn.textContent = 'Cancel';
    cancelBtn.className = 'nm-btn-cancel';
    cancelBtn.addEventListener('click', closeWaypointDialog);
    btnRow.appendChild(saveBtn);
    btnRow.appendChild(cancelBtn);
    wpDialogDiv.appendChild(btnRow);
}());
document.body.appendChild(wpDialogDiv);

// Rebuild the type <select>.  route_pt is offered only when editing a waypoint
// that already is one (refs aren't created standalone from the map).
function populateTypeOptions(includeRoutePt) {
    wpTypeSelect.innerHTML = '';
    for (let t = 0; t < WP_TYPE_NAMES.length; t++) {
        if (t === WP_TYPE_ROUTE_PT && !includeRoutePt) continue;
        const opt = document.createElement('option');
        opt.value = t;
        opt.textContent = WP_TYPE_NAMES[t];
        wpTypeSelect.appendChild(opt);
    }
}

function selectSym(sym) {
    wpSelectedSym = +sym;
    wpSymBtnImg.src = '/sym/native/' + String(wpSelectedSym).padStart(2, '0') + '.png';
    wpSymBtnLabel.textContent = E80_SYM_NAMES[wpSelectedSym] || ('Sym ' + wpSelectedSym);
    const opts = wpSymPanel.querySelectorAll('.nm-wp-symdd-opt');
    for (let i = 0; i < opts.length; i++) {
        opts[i].classList.toggle('nm-wp-symdd-opt-sel', +opts[i].dataset.sym === wpSelectedSym);
    }
}

function toggleSymPanel() {
    if (wpSymPanel.style.display === 'none') openSymPanel();
    else closeSymPanel();
}
function openSymPanel() {
    wpSymPanel.style.display = 'block';
    const sel = wpSymPanel.querySelector('.nm-wp-symdd-opt-sel');
    if (sel) sel.scrollIntoView({ block: 'nearest' });
}
function closeSymPanel() {
    if (wpSymPanel) wpSymPanel.style.display = 'none';
}

function setColor(abgr) {
    wpColor = (abgr || WP_DEFAULT_COLOR).toLowerCase();
    const idx = E80_COLOR_ABGR.indexOf(wpColor);
    wpColorSelect.value = (idx >= 0) ? wpColor : 'custom';
    wpColorInput.value  = abgrToHex6(wpColor);
}
function onColorSelectChange() {
    if (wpColorSelect.value === 'custom') wpColorInput.click();   // full-spectrum picker
    else setColor(wpColorSelect.value);
}
function onColorPicked() {
    setColor(hex6ToAbgr(wpColorInput.value));
}

function positionDialogNear(x, y) {
    const w = wpDialogDiv.offsetWidth;
    const h = wpDialogDiv.offsetHeight;
    const nx = (x + w > window.innerWidth)  ? (window.innerWidth  - w - 6) : x;
    const ny = (y + h > window.innerHeight) ? (window.innerHeight - h - 6) : y;
    wpDialogDiv.style.left = Math.max(4, nx) + 'px';
    wpDialogDiv.style.top  = Math.max(4, ny) + 'px';
}

// opts: create -> {latlng, dest, screenXY};  edit -> {uuid, props, screenXY}
function openWaypointDialog(mode, opts) {
    hideCtxMenu();
    opts = opts || {};
    const dest = opts.dest || {};
    // store: create -> from the resolved dest; edit -> the marker's data_source
    const store = (mode === 'edit')
        ? ((opts.props && opts.props.data_source) || 'db')
        : (dest.store || 'db');
    const storeLabel = dest.store_label || STORE_LABELS[store] || 'Database';
    const isDb = (store === 'db');

    let name  = '';
    let type  = WP_TYPE_NAV;
    let sym   = WP_DEFAULT_SYMS[WP_TYPE_NAV];
    let color = WP_DEFAULT_COLOR;
    if (mode === 'edit' && opts.props) {
        name  = opts.props.name || '';
        type  = (opts.props.wp_type != null) ? +opts.props.wp_type : WP_TYPE_NAV;
        sym   = (opts.props.sym     != null) ? +opts.props.sym     : (WP_DEFAULT_SYMS[type] || 0);
        color = opts.props.color || WP_DEFAULT_COLOR;
    }
    wpDialogState = {
        mode:   mode,
        store:  store,
        latlng: opts.latlng || null,
        dest:   dest,
        uuid:   opts.uuid   || (opts.props && opts.props.uuid) || null,
    };
    wpDialogTitle.textContent = (mode === 'edit' ? 'Edit ' : 'Create ') + storeLabel + ' Waypoint';

    // store-aware fields: db has Type + Color; e80/fsh have neither (sym only)
    // and a hard 15-char name limit enforced right here in the editor.
    wpTypeRow.style.display  = isDb ? '' : 'none';
    wpColorRow.style.display = isDb ? '' : 'none';
    wpNameHint.style.display = isDb ? 'none' : '';
    if (isDb) wpNameInput.removeAttribute('maxlength');
    else      wpNameInput.setAttribute('maxlength', '15');

    populateTypeOptions(mode === 'edit' && type === WP_TYPE_ROUTE_PT);
    wpNameInput.value  = name;
    wpTypeSelect.value = type;
    selectSym(sym);
    setColor(color);

    wpDialogDiv.style.display = 'block';
    const xy = opts.screenXY;
    positionDialogNear(xy ? xy.x : (window.innerWidth  / 2),
                       xy ? xy.y : (window.innerHeight / 2));
    wpNameInput.focus();
    wpNameInput.select();
}

function closeWaypointDialog() {
    closeSymPanel();
    wpDialogDiv.style.display = 'none';
    wpDialogState = null;
    wpSaving = false;
}

// Close the sym dropdown on any click/drag outside it (capture phase, like the
// context-menu dismiss).  The sym button's own click handles the toggle.
document.addEventListener('mousedown', function(e) {
    if (wpSymPanel && wpSymPanel.style.display !== 'none' &&
        wpSymDD && !wpSymDD.contains(e.target)) {
        closeSymPanel();
    }
}, true);

function saveWaypoint() {
    if (!wpDialogState || wpSaving) return;
    const name = wpNameInput.value.trim();
    if (!name) { wpNameInput.focus(); return; }      // name required
    const store = wpDialogState.store || 'db';
    const isDb  = (store === 'db');
    if (!isDb && name.length > 15) {                 // spoke 15-char limit (client-enforced)
        showSaveError('Name must be 15 characters or less for ' + (STORE_LABELS[store] || store));
        return;
    }
    const wp_type = +wpTypeSelect.value;
    const sym = (wpSelectedSym != null) ? +wpSelectedSym : (WP_DEFAULT_SYMS[wp_type] || 0);
    const seq = ++wpSaveSeq;

    let payload;
    if (wpDialogState.mode === 'edit') {
        payload = { op: 'update', seq: seq, store: store, uuid: wpDialogState.uuid,
                    name: name, sym: sym };
        if (isDb) { payload.wp_type = wp_type; payload.color = wpColor; }
    } else {
        const d  = wpDialogState.dest   || {};
        const ll = wpDialogState.latlng || {};
        payload = { op: 'create', seq: seq, store: store, name: name, sym: sym,
                    lat: ll.lat, lon: ll.lng };
        if (isDb) {
            payload.wp_type         = wp_type;
            payload.color           = wpColor;
            payload.collection_uuid = d.collection_uuid || '';
            payload.anchor_uuid     = d.anchor_uuid     || '';
            payload.anchor_type     = d.anchor_type     || '';
        } else {
            payload.group_uuid = d.group_uuid || '';
        }
    }

    wpSaving = true;
    fetch('/waypoint/save', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).then(function() { pollWaypointResult(seq, 0); })
      .catch(function() { wpSaving = false; showSaveError('Could not reach the app'); });
}

// Poll /waypoint/result until the matching seq appears: ok -> close; else keep
// the dialog open and toast the reason (preflight reject / spoke error).
function pollWaypointResult(seq, tries) {
    fetch('/waypoint/result').then(function(r) { return r.json(); }).then(function(res) {
        if (res && +res.seq === seq) {
            wpSaving = false;
            if (res.ok) closeWaypointDialog();
            else        showSaveError(res.msg || 'Save failed');
            return;
        }
        if (tries < 40) setTimeout(function() { pollWaypointResult(seq, tries + 1); }, 120);
        else { wpSaving = false; showSaveError('Timed out waiting for the app'); }
    }).catch(function() {
        if (tries < 40) setTimeout(function() { pollWaypointResult(seq, tries + 1); }, 120);
        else wpSaving = false;
    });
}

function startCreateWaypoint() {
    const latlng = ctxMenuLatLng;
    const xy     = ctxMenuXY;
    hideCtxMenu();
    if (!latlng) return;
    fetchMapDest(function(dest) {
        openWaypointDialog('create', { latlng: latlng, dest: dest, screenXY: xy });
    });
}

// Called from map.js when a db waypoint marker is right-clicked.
function showWaypointMenu(props, clientX, clientY, lat, lon) {
    ctxWaypoint = { uuid: props.uuid, props: props, screenXY: { x: clientX, y: clientY },
                    latlng: (lat != null && lon != null) ? L.latLng(lat, lon) : null };
    showCtxMenu(clientX, clientY, 'waypoint');
}

function editWaypointFromCtx() {
    if (!ctxWaypoint) return;
    openWaypointDialog('edit', ctxWaypoint);
}

function deleteWaypointFromCtx() {
    if (!ctxWaypoint) return;
    const wp = ctxWaypoint;
    hideCtxMenu();
    showWpConfirm("Delete waypoint '" + (wp.props.name || '') + "'?\nThis cannot be undone.",
        wp.screenXY, function() { sendDeleteWaypoint(wp); });
}

// Delete rides the same /waypoint/save + result channel: the app preflights
// route membership and rejects (red toast) if the waypoint is used by a route.
function sendDeleteWaypoint(wp) {
    if (wpSaving) return;
    const seq = ++wpSaveSeq;
    wpSaving = true;
    fetch('/waypoint/save', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
            op:    'delete',
            seq:   seq,
            store: wp.props.data_source || 'db',
            uuid:  wp.uuid || wp.props.uuid,
        }),
    }).then(function() { pollWaypointResult(seq, 0); })
      .catch(function() { wpSaving = false; showSaveError('Could not reach the app'); });
}

// ---- Delete confirmation overlay ----
const wpConfirmDiv = document.createElement('div');
wpConfirmDiv.id = 'nm-wp-confirm';
wpConfirmDiv.style.display = 'none';
let wpConfirmMsg;
let wpConfirmCb = null;
(function() {
    wpConfirmMsg = document.createElement('div');
    wpConfirmMsg.className = 'nm-wp-confirm-msg';
    wpConfirmDiv.appendChild(wpConfirmMsg);
    const row = document.createElement('div');
    row.className = 'nm-wp-buttons';
    const yes = document.createElement('button');
    yes.textContent = 'Delete';
    yes.className = 'nm-btn-danger';
    yes.addEventListener('click', function() {
        const cb = wpConfirmCb;
        closeWpConfirm();
        if (cb) cb();
    });
    const no = document.createElement('button');
    no.textContent = 'Cancel';
    no.addEventListener('click', closeWpConfirm);
    row.appendChild(yes);
    row.appendChild(no);
    wpConfirmDiv.appendChild(row);
}());
document.body.appendChild(wpConfirmDiv);

function showWpConfirm(msg, xy, cb) {
    wpConfirmMsg.textContent = msg;
    wpConfirmCb = cb;
    wpConfirmDiv.style.display = 'block';
    const w = wpConfirmDiv.offsetWidth;
    const h = wpConfirmDiv.offsetHeight;
    const x = xy ? xy.x : (window.innerWidth  / 2);
    const y = xy ? xy.y : (window.innerHeight / 2);
    wpConfirmDiv.style.left = Math.max(4, (x + w > window.innerWidth  ? window.innerWidth  - w - 6 : x)) + 'px';
    wpConfirmDiv.style.top  = Math.max(4, (y + h > window.innerHeight ? window.innerHeight - h - 6 : y)) + 'px';
}
function closeWpConfirm() {
    wpConfirmDiv.style.display = 'none';
    wpConfirmCb = null;
}

// ---- Move waypoint ----
//
// Reached from a right-click on a db/e80/fsh waypoint marker (Move Waypoint;
// hidden for route points).  A deliberate, no-accidental-drag gesture: enter a
// per-waypoint mode where a ghost copy of the marker + a dashed "leash" from the
// original spot follow the cursor; a left-click drops the ghost at a proposed
// position (re-click repositions); Confirm commits via the same /waypoint/save
// op=update channel as Edit (with lat/lon).  The waypoint record is unchanged
// until Confirm, so routes that reference it stay put, then snap to the new
// position when the server re-pushes them.

let moveMode     = false;
let moveWp       = null;    // { uuid, props, store, orig: L.latLng }
let moveProposed = null;    // L.latLng once placed (null while still tracking)
let moveGhost    = null;    // L.marker following the cursor / placed
let moveLeash    = null;    // L.polyline original -> ghost

let moveHint, moveConfirmBtn;
const moveBarDiv = document.createElement('div');
moveBarDiv.id = 'nm-move-bar';
moveBarDiv.style.display = 'none';
(function() {
    const hint = document.createElement('span');
    hint.className = 'nm-move-hint';
    moveBarDiv.appendChild(hint);
    moveHint = hint;
    function makeBtn(text, cls, fn) {
        const b = document.createElement('button');
        b.textContent = text;
        if (cls) b.className = cls;
        b.onclick = fn;
        moveBarDiv.appendChild(b);
        return b;
    }
    moveConfirmBtn = makeBtn('Confirm Move', 'nm-btn-confirm', function() { confirmMoveWaypoint(); });
    makeBtn('Cancel',                        'nm-btn-cancel',  function() { exitMoveMode();         });
}());
document.body.appendChild(moveBarDiv);

// Ghost icon: mirror map.js's marker-icon selection so the ghost reads as the
// real waypoint (db sym markers resolve async: provisional circle -> tinted sym).
function _setMoveGhostIcon(props) {
    if (!moveGhost) return;
    const symN = (props.sym != null && props.sym >= 0 && props.sym <= 39) ? +props.sym : null;
    if (symN == null) {
        moveGhost.setIcon(makeColoredWpIcon(props.color));
    } else if (props.data_source === 'e80' || props.data_source === 'fsh') {
        moveGhost.setIcon(nativeSymIcon(symN));
    } else {
        moveGhost.setIcon(makeColoredWpIcon(props.color));
        coloredSymIcon(symN, props.color).then(function(ic) {
            if (ic && moveGhost) { try { moveGhost.setIcon(ic); } catch (_) {} }
        });
    }
}

function startMoveWaypoint() {
    if (!ctxWaypoint) return;
    const wp = ctxWaypoint;
    hideCtxMenu();
    if (!wp.latlng) return;
    enterMoveMode(wp);
}

function enterMoveMode(wp) {
    if (moveMode) exitMoveMode();
    moveMode     = true;
    moveProposed = null;
    moveWp = {
        uuid:  wp.uuid,
        props: wp.props,
        store: wp.props.data_source || 'db',
        orig:  L.latLng(wp.latlng.lat, wp.latlng.lng),
    };
    hideInfo();
    moveGhost = L.marker(moveWp.orig, {
        icon: makeColoredWpIcon(wp.props.color), interactive: false, zIndexOffset: 2000, opacity: 0.6,
    }).addTo(map);
    _setMoveGhostIcon(wp.props);
    moveLeash = L.polyline([moveWp.orig, moveWp.orig], {
        color: '#ffff00', weight: 2, dashArray: '5 5', interactive: false,
    }).addTo(map);
    moveConfirmBtn.style.display = 'none';
    moveHint.textContent = "Click the new position for '" + (moveWp.props.name || '') + "'";
    moveBarDiv.style.display = 'flex';
}

function _updateMovePoint(latlng) {
    if (!moveGhost || !moveLeash || !moveWp) return;
    moveGhost.setLatLng(latlng);
    moveLeash.setLatLngs([moveWp.orig, latlng]);
}

function placeMovePoint(latlng) {
    moveProposed = latlng;
    _updateMovePoint(latlng);
    moveConfirmBtn.style.display = '';
    moveHint.textContent = 'New position ' + latlng.lat.toFixed(5) + ', ' + latlng.lng.toFixed(5) +
                           ' -- click to re-place, or Confirm';
}

function confirmMoveWaypoint() {
    if (!moveMode || !moveProposed || !moveWp || wpSaving) return;
    const seq = ++wpSaveSeq;
    wpSaving = true;
    const p = moveProposed;
    fetch('/waypoint/save', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify({
            op:    'update',
            seq:   seq,
            store: moveWp.store,
            uuid:  moveWp.uuid,
            name:  moveWp.props.name,                                 // spokes require a name on update
            sym:   (moveWp.props.sym != null ? +moveWp.props.sym : undefined),
            lat:   p.lat,
            lon:   p.lng,
        }),
    }).then(function() { pollMoveResult(seq, 0); })
      .catch(function() { wpSaving = false; showSaveError('Could not reach the app'); });
}

// Move's own result poll: success exits move mode (the server re-push re-renders
// the waypoint + its routes at the new spot); failure keeps the ghost so the user
// can re-place or Cancel.
function pollMoveResult(seq, tries) {
    fetch('/waypoint/result').then(function(r) { return r.json(); }).then(function(res) {
        if (res && +res.seq === seq) {
            wpSaving = false;
            if (res.ok) exitMoveMode();
            else        showSaveError(res.msg || 'Move failed');
            return;
        }
        if (tries < 40) setTimeout(function() { pollMoveResult(seq, tries + 1); }, 120);
        else { wpSaving = false; showSaveError('Timed out waiting for the app'); }
    }).catch(function() {
        if (tries < 40) setTimeout(function() { pollMoveResult(seq, tries + 1); }, 120);
        else wpSaving = false;
    });
}

function exitMoveMode() {
    if (!moveMode) return;
    moveMode     = false;
    moveProposed = null;
    if (moveGhost) { map.removeLayer(moveGhost); moveGhost = null; }
    if (moveLeash) { map.removeLayer(moveLeash); moveLeash = null; }
    moveWp = null;
    moveBarDiv.style.display = 'none';
}

// ---- Join ----

function enterJoinMode() {
    if (!editSubject || editMode || joinMode) return;
    if (editSubject.props.data_source !== 'db') return;
    joinMode   = true;
    joinPhase  = 'pickEndA';
    joinTrackA = editSubject;
    joinIdxA   = -1;
    joinTrackB = null;
    joinIdxB   = -1;
    hideCtxMenu();
    hideInfo();
    buildHandles();
    showJoinBar('Click the vertex where ' + (joinTrackA.props.name || 'track') + ' should END', false);
}

function setJoinEndA(idx) {
    joinIdxA      = idx;
    joinPhase     = 'pickTrackB';
    clearHandles();
    editSubject   = null;
    showJoinBar('Click the second track to join', false);
}

function handleJoinTrackBPick(track) {
    if (!track || !joinTrackA) return;
    if (track.layer === joinTrackA.layer) return;
    if (track.props.data_source !== 'db') return;
    joinTrackB    = track;
    editSubject   = track;
    track.layer.setStyle({ color: '#ffff00', weight: 4 });
    joinPhase = 'pickStartB';
    buildHandles();
    showJoinBar('Click the vertex where ' + (track.props.name || 'track') + ' should START', false);
}

function setJoinStartB(idx) {
    joinIdxB      = idx;
    joinPhase     = 'preview';
    clearHandles();
    editSubject   = null;
    buildJoinPreview();
    showJoinBar(
        'Confirm join: ' + (joinTrackA.props.name || 'track A') + ' + ' + (joinTrackB.props.name || 'track B'),
        true
    );
}

function buildJoinPreview() {
    clearJoinPreview();
    const llsA   = joinTrackA.layer.getLatLngs();
    const llsB   = joinTrackB.layer.getLatLngs();
    const sliceA = llsA.slice(0, joinIdxA + 1);
    const sliceB = llsB.slice(joinIdxB);
    const gap    = [llsA[joinIdxA], llsB[joinIdxB]];
    joinPreviewLayers = [
        L.polyline(sliceA, { color: '#ffffff', weight: 3 }).addTo(map),
        L.polyline(sliceB, { color: '#ffffff', weight: 3 }).addTo(map),
        L.polyline(gap,    { color: '#ffff00', weight: 2, dashArray: '6 6' }).addTo(map),
    ];
}

function clearJoinPreview() {
    joinPreviewLayers.forEach(function(l) { map.removeLayer(l); });
    joinPreviewLayers = [];
}

function confirmJoin() {
    if (!joinMode || !joinTrackA || !joinTrackB || joinIdxA < 0 || joinIdxB < 0) return;
    const payload = {
        op:     'join',
        source: 'db',
        uuid:   joinTrackA.props.uuid,
        uuid_b: joinTrackB.props.uuid,
        idx_a:  joinIdxA,
        idx_b:  joinIdxB,
    };
    exitJoinMode();
    fetch('/track/edit', {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(payload),
    }).catch(function() {});
}

function exitJoinMode() {
    if (!joinMode) return;
    joinMode  = false;
    joinPhase = '';
    clearHandles();
    clearJoinPreview();
    if (joinTrackA) joinTrackA.layer.setStyle({ color: abgrToCSS(joinTrackA.props.color), weight: 2 });
    if (joinTrackB) joinTrackB.layer.setStyle({ color: abgrToCSS(joinTrackB.props.color), weight: 2 });
    joinTrackA    = null;
    joinTrackB    = null;
    joinIdxA      = -1;
    joinIdxB      = -1;
    editSubject   = null;
    joinBarDiv.style.display = 'none';
}
