#!/usr/bin/perl
#-------------------------------------------------------------------------
# winOCPN.pm
#-------------------------------------------------------------------------
# Browser for the OpenCPN spoke -- a LIVE, read-only projection of what the
# oESeries plugin currently has loaded in OpenCPN, held in navOCPN's ocdb.
# navMate is the HTTP server; the plugin POSTs its full inventory and this
# pane mirrors it.  Sibling to winE80 (a live view of the plotter) and winFSH
# (a view of a loaded FSH file).
#
# Tree structure (OpenCPN has no group/collection concept -- sec 6):
#   My Waypoints            (standalone marks; pure route-vertices excluded)
#     mark ...
#   Routes
#     route ...
#       route point ...
#   Tracks
#     track ...
#
# Checkboxes control Leaflet map visibility, parallel to winE80/winFSH.
# Selecting a node populates the editor + detail panels on the right.
#
# EDITING: selecting a waypoint/route/track loads an editor (name/comment/lat/
# lon/sym for marks; name/comment for routes; name for tracks).  Save ENQUEUES
# an outbound update command that the plugin applies and echoes back -- so an
# in-pane edit is a real hub->OpenCPN push (parallel to winE80 editing the live
# plotter).  Bulk mutation still also crosses the boundary through navOps: PASTE
# an OpenCPN object INTO navMate.db (inbound), or PUSH/PASTE a hub object OUT to
# OpenCPN (outbound commands[] batch).

package winOCPN;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_TREE_SEL_CHANGED
	EVT_TREE_ITEM_RIGHT_CLICK
	EVT_TREE_ITEM_ACTIVATED
	EVT_LEFT_DOWN
	EVT_MENU
	EVT_MENU_RANGE
	EVT_TEXT
	EVT_BUTTON
	EVT_COMBOBOX
	EVT_CHECKBOX
	EVT_CHOICE
	EVT_SIZE);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use navOCPN;
use navServer qw(addRenderFeatures removeRenderFeatures openMapBrowser isBrowserConnected);
use navVisibility qw(getOCPNVisible setOCPNVisible clearAllOCPNVisible getAllOCPNVisibleUUIDs batchRemoveOCPNVisible);
use navOutline;
use n_defs;
use n_utils;
use navPrefs;
use nmResources;
use navClipboard;
use nmOCPNIcons;
use navOps qw(buildContextMenu onContextMenuCommand);
use winRename qw($CTX_CMD_RENAME isRenameHomogeneous onRenameOCPN);
use winMultiEditor;
use navMatch;
use winFind;
use base 'winTreeBase';

my $dbg_wocpn = 0;

# Context-menu command IDs (same numeric values as winE80/winFSH/winDatabase
# so the IDs stay interchangeable across panels).
my $CTX_CMD_SHOW_MAP   = 10560;
my $CTX_CMD_HIDE_MAP   = 10561;
my $CTX_CMD_FIND_THIS  = 10570;
my $CTX_CMD_MULTI_EDIT = 10571;


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'OpenCPN', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_MULTIPLE);

	my $state_imgs = Wx::ImageList->new(13, 13);
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(0));
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(1));
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(2));
	$this->{tree}->SetStateImageList($state_imgs);
	$this->{_state_imgs} = $state_imgs;
	winTreeBase::_attachSwatchImageList($this->{tree});

	# Right side is one grey panel: an editor strip at top (packed by the
	# winTreeBase layout walker) and a detail TextCtrl below.  The editor is
	# OpenCPN-tailored -- name / comment / lat / lon / sym only (OpenCPN marks
	# carry no depth/temp/date/time and no E80 palette color).  Saving an edit
	# ENQUEUES an outbound update command (nmOCPNDirectOps + navOCPN::pushItems)
	# that the plugin applies and echoes back -- so an in-pane edit is a real
	# hub->OpenCPN push, mirroring how winE80 edits the live plotter.
	# Three stacked zones (Patrick's layout): a FIXED header strip (Save / title /
	# Show-on-Map / Extended toggle) that never scrolls; an EDITOR ScrolledWindow
	# ($ed_scroll) holding the field rows + the Extended block -- the ONLY thing
	# that scrolls, so toggling Extended grows its virtual height (a scrollbar
	# appears WITHIN this zone) without moving anything else; and the detail
	# TextCtrl below, in its own fixed zone.  winOCPN-local: the shared
	# winTreeBase::_layoutEditor field walker is reused as-is (it Moves rows
	# parent-relative, so it lays them into $ed_scroll unchanged); winE80/winFSH
	# keep the flat editor+detail layout.
	my $right_panel = Wx::Panel->new($this, -1);
	$right_panel->SetBackgroundColour(
		Wx::SystemSettings::GetColour(wxSYS_COLOUR_BTNFACE));
	$this->{right_panel} = $right_panel;

	my $ed_scroll = Wx::ScrolledWindow->new($right_panel, -1);
	$ed_scroll->SetBackgroundColour(
		Wx::SystemSettings::GetColour(wxSYS_COLOUR_BTNFACE));
	$ed_scroll->SetScrollRate(0, 12);
	$this->{ed_scroll} = $ed_scroll;

	my $ED_MARGIN      = 8;
	my $ED_LABEL_W     = 60;
	my $ED_COL_GAP     = 8;
	my $ED_CTRL_X      = $ED_MARGIN + $ED_LABEL_W + $ED_COL_GAP;
	my $ED_CTRL_H      = 23;
	my $ED_ROW_GAP     = 2;
	my $ED_ROW_H       = $ED_CTRL_H + $ED_ROW_GAP;
	# Fields live in $ed_scroll (their own zone); their start Y is a MINIMAL top
	# margin so Name sits right at the top of the zone (no wasted line) -- the
	# header is a separate fixed strip above the scroller.
	my $ED_HEADER_SIZE = 2;
	$this->{_ed_ctrl_x}      = $ED_CTRL_X;
	$this->{_ed_ctrl_h}      = $ED_CTRL_H;
	$this->{_ed_margin}      = $ED_MARGIN;
	$this->{_ed_header_size} = $ED_HEADER_SIZE;
	$this->{_ed_row_h}       = $ED_ROW_H;
	$this->{_ed_bottom_pad}  = 4;   # tight gap after the last field
	$this->{_ed_field_rows}  = { comment => 2 };   # comment is a 2-line multi-line editor

	# Fixed zone geometry: the header is a SINGLE condensed row (Save / title /
	# Show-on-Map / Extended, all on the top line); the editor scroll zone is
	# sized to a waypoint's collapsed field set so Extended is what makes it
	# scroll.  $HDR_Y is the header row's Y.  These are the tunable knobs.
	my $HDR_Y = 4;
	$this->{_ocpn_header_h}    = $HDR_Y + $ED_CTRL_H + 4;
	# 9 rows (the comment editor spans 2) + 22 so a waypoint's fields PLUS the
	# "EXTENDED FIELDS" seam both show on the first Extended-press.
	$this->{_ocpn_edit_zone_h} = $ED_HEADER_SIZE + 9 * $ED_ROW_H + 22;

	my $ey = sub { $ED_HEADER_SIZE + $_[0] * $ED_ROW_H };

	# Top-line header (condensed onto one row): Save | title | Show-on-Map | Extended.
	$this->{ed_save} = Wx::Button->new($right_panel, -1, 'Save',
		[4, $HDR_Y], [48, $ED_CTRL_H]);
	$this->{ed_save}->Enable(0);

	$this->{ed_title} = Wx::StaticText->new($right_panel, -1, '',
		[56, $HDR_Y], [52, $ED_CTRL_H]);
	$this->{ed_title}->SetFont(
		Wx::Font->new(-1, wxFONTFAMILY_DEFAULT, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_BOLD));

	# navMate MAP visibility (navVisibility) -- kept DELIBERATELY distinct from the
	# OpenCPN `visible` B-field in the scroll zone (sec 6).  On the top header row,
	# alongside the Extended toggle, so neither scrolls.
	$this->{ed_visible} = Wx::CheckBox->new($right_panel, -1, 'Show on Map',
		[112, $HDR_Y], [92, $ED_CTRL_H], wxCHK_3STATE);
	$this->{ed_visible}->Show(0);

	$this->{ed_lbl_name} = Wx::StaticText->new($ed_scroll, -1, 'Name',
		[$ED_MARGIN, $ey->(0)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_name} = Wx::TextCtrl->new($ed_scroll, -1, '',
		[$ED_CTRL_X, $ey->(0)], [200, $ED_CTRL_H]);

	$this->{ed_lbl_comment} = Wx::StaticText->new($ed_scroll, -1, 'Comment',
		[$ED_MARGIN, $ey->(1)], [$ED_LABEL_W, $ED_CTRL_H]);
	# 2-line multi-line comment editor (spans 2 rows -- see _ed_field_rows).  navMate
	# stores the true text incl. any newline; the wire carries it verbatim (R3).
	$this->{ed_comment} = Wx::TextCtrl->new($ed_scroll, -1, '',
		[$ED_CTRL_X, $ey->(1)], [200, 2 * $ED_ROW_H - $ED_ROW_GAP], wxTE_MULTILINE);

	$this->{ed_lbl_lat} = Wx::StaticText->new($ed_scroll, -1, 'Lat',
		[$ED_MARGIN, $ey->(2)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lat} = Wx::TextCtrl->new($ed_scroll, -1, '',
		[$ED_CTRL_X, $ey->(2)], [110, $ED_CTRL_H]);
	$this->{ed_lat_ddm} = Wx::StaticText->new($ed_scroll, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(2)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_lon} = Wx::StaticText->new($ed_scroll, -1, 'Lon',
		[$ED_MARGIN, $ey->(3)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lon} = Wx::TextCtrl->new($ed_scroll, -1, '',
		[$ED_CTRL_X, $ey->(3)], [110, $ED_CTRL_H]);
	$this->{ed_lon_ddm} = Wx::StaticText->new($ed_scroll, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(3)], [-1, $ED_CTRL_H]);

	# Icon picker -- the OpenCPN icon vocabulary (nmOCPNIcons, sec 7), NOT the
	# E80 sym combo.  Repopulated per-load from the live library.
	$this->{ed_lbl_icon} = Wx::StaticText->new($ed_scroll, -1, 'Icon',
		[$ED_MARGIN, $ey->(4)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_icon} = nmOCPNIcons::makeOCPNIconPicker($ed_scroll,
		[$ED_CTRL_X, $ey->(4)], [240, $ED_CTRL_H]);

	# route from/to (m_StartString/m_EndString -- shown only for routes/tracks)
	$this->{ed_lbl_from} = Wx::StaticText->new($ed_scroll, -1, 'From',
		[$ED_MARGIN, $ey->(5)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_from} = Wx::TextCtrl->new($ed_scroll, -1, '',
		[$ED_CTRL_X, $ey->(5)], [200, $ED_CTRL_H]);
	$this->{ed_lbl_to} = Wx::StaticText->new($ed_scroll, -1, 'To',
		[$ED_MARGIN, $ey->(6)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_to} = Wx::TextCtrl->new($ed_scroll, -1, '',
		[$ED_CTRL_X, $ey->(6)], [200, $ED_CTRL_H]);

	# OpenCPN B booleans (Basic tier): `visible` in OpenCPN (distinct from the
	# header map-visibility) + name_shown; `active` is [R], shown read-only.
	$this->{ed_lbl_ocpnvis} = Wx::StaticText->new($ed_scroll, -1, 'In OCPN',
		[$ED_MARGIN, $ey->(7)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_ocpn_visible} = Wx::CheckBox->new($ed_scroll, -1, 'Visible',
		[$ED_CTRL_X, $ey->(7)], [-1, $ED_CTRL_H]);
	$this->{ed_lbl_nameshow} = Wx::StaticText->new($ed_scroll, -1, 'Label',
		[$ED_MARGIN, $ey->(8)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_name_shown} = Wx::CheckBox->new($ed_scroll, -1, 'Show name',
		[$ED_CTRL_X, $ey->(8)], [-1, $ED_CTRL_H]);
	$this->{ed_lbl_active} = Wx::StaticText->new($ed_scroll, -1, 'Active',
		[$ED_MARGIN, $ey->(9)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_active} = Wx::StaticText->new($ed_scroll, -1, 'no',
		[$ED_CTRL_X, $ey->(9)], [200, $ED_CTRL_H]);

	$this->{_ed_field_widgets} = {
		name     => [ 'ed_lbl_name',    'ed_name',         []            ],
		comment  => [ 'ed_lbl_comment', 'ed_comment',      []            ],
		icon     => [ 'ed_lbl_icon',    'ed_icon',         []            ],
		lat      => [ 'ed_lbl_lat',     'ed_lat',          ['ed_lat_ddm'] ],
		lon      => [ 'ed_lbl_lon',     'ed_lon',          ['ed_lon_ddm'] ],
		from     => [ 'ed_lbl_from',    'ed_from',         []            ],
		to       => [ 'ed_lbl_to',      'ed_to',           []            ],
		ocpnvis  => [ 'ed_lbl_ocpnvis', 'ed_ocpn_visible', []            ],
		nameshow => [ 'ed_lbl_nameshow','ed_name_shown',   []            ],
		active   => [ 'ed_lbl_active',  'ed_active',       []            ],
	};

	# ---- the Extended expander (waypoints only) ----------------------------
	# The toggle lives in the FIXED header (row 1, next to Show-on-Map) so it is
	# always reachable and never scrolls away.  Its panel is a plain container in
	# the $ed_scroll zone, dropped in-line below the field rows; the editor zone's
	# own scrollbar absorbs the overflow, leaving the detail zone untouched.
	$this->{ed_ext_toggle} = Wx::Button->new($right_panel, -1, 'Extended >',
		[206, $HDR_Y], [84, $ED_CTRL_H]);
	$this->{ed_ext_toggle}->Show(0);
	$this->{_ext_open} = 0;

	my $ext = Wx::Panel->new($ed_scroll, -1, [0, 0], [10, 150]);
	$ext->SetBackgroundColour(Wx::SystemSettings::GetColour(wxSYS_COLOUR_BTNFACE));
	$this->{ed_ext_panel} = $ext;
	_buildExtendedPanel($this, $ext);
	$ext->Show(0);

	# A centered seam header shown just above the extended block when it opens, so
	# pressing Extended visibly announces "more below" instead of only adding a
	# scrollbar.  Lives in the scroll zone; positioned by _layoutOcpnEditor.
	$this->{ed_ext_sep} = Wx::StaticText->new($ed_scroll, -1,
		'-------- EXTENDED FIELDS --------',
		[0, 0], [10, $ED_CTRL_H]);   # left-justified, to line up with the labels
	$this->{ed_ext_sep}->Show(0);

	$this->{detail} = Wx::TextCtrl->new($right_panel, -1, '',
		wxDefaultPosition, wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{detail}->SetFont(
		Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL));

	EVT_SIZE($right_panel, sub {
		my ($panel, $event) = @_;
		$event->Skip();
		_resizeOcpnRightPanel($this);
	});

	my $sash = ($data && ref($data) eq 'HASH' && $data->{sash}) ? $data->{sash} : 250;
	$this->SplitVertically($this->{tree}, $right_panel, $sash);
	$this->SetSashGravity(0);

	$this->_clearEditor();

	EVT_TREE_SEL_CHANGED($this, $this->{tree}, \&onTreeSelect);
	EVT_TREE_ITEM_RIGHT_CLICK($this, $this->{tree}, \&onTreeRightClick);
	EVT_TREE_ITEM_ACTIVATED($this, $this->{tree}, \&_onTreeActivated);
	EVT_MENU($this, $CTX_CMD_SHOW_MAP,   \&_onShowMap);
	EVT_MENU($this, $CTX_CMD_HIDE_MAP,   \&_onHideMap);
	EVT_MENU($this, $CTX_CMD_FIND_THIS,  \&_onFindThis);
	EVT_MENU($this, $CTX_CMD_MULTI_EDIT, \&_onMultiEdit);
	EVT_MENU($this, $CTX_CMD_RENAME,     \&_onRename);
	# All navOps context-menu IDs (Copy=10200 .. PUSH_OCPN=10253), same range
	# pattern as winE80/winFSH keeps the panel dispatch parallel.
	EVT_MENU_RANGE($this, 10200, 10299, \&_onNmOpsCmd);
	EVT_LEFT_DOWN($this->{tree}, sub { $this->_onTreeLeftDown(@_) });
	EVT_TEXT($this,     $this->{ed_name},    $this->can('_onFieldChanged'));
	EVT_TEXT($this,     $this->{ed_comment}, $this->can('_onFieldChanged'));
	EVT_TEXT($this,     $this->{ed_lat},     $this->can('_onLatEdit'));
	EVT_TEXT($this,     $this->{ed_lon},     $this->can('_onLonEdit'));
	EVT_COMBOBOX($this, $this->{ed_icon},    $this->can('_onFieldChanged'));
	EVT_TEXT($this,     $this->{ed_from},    $this->can('_onFieldChanged'));
	EVT_TEXT($this,     $this->{ed_to},      $this->can('_onFieldChanged'));
	EVT_CHECKBOX($this, $this->{ed_ocpn_visible}, $this->can('_onFieldChanged'));
	EVT_CHECKBOX($this, $this->{ed_name_shown},   $this->can('_onFieldChanged'));
	EVT_BUTTON($this,   $this->{ed_save},    \&_onSave);
	EVT_CHECKBOX($this, $this->{ed_visible}, $this->can('_onEdVisibleChanged'));
	EVT_BUTTON($this,   $this->{ed_ext_toggle}, \&_onExtToggle);
	# Extended-panel controls all just mark the editor dirty on change.
	for my $k (qw(ed_scamin ed_scamax ed_arrival ed_pspeed ed_rr_count ed_rr_space ed_rr_color ed_tide ed_etd))
	{
		EVT_TEXT($this, $this->{$k}, $this->can('_onFieldChanged')) if $this->{$k};
	}
	EVT_CHECKBOX($this, $this->{ed_scamin_on}, $this->can('_onFieldChanged'));
	EVT_CHECKBOX($this, $this->{ed_rr_show},   $this->can('_onFieldChanged'));
	EVT_CHOICE($this,   $this->{ed_rr_units},  $this->can('_onFieldChanged'));

	$this->{_loaded} = 0;
	my @outline_keys = navOutline::getExpanded('ocpn');
	$this->{_expanded_keys} = @outline_keys
		? { map { $_ => 1 } @outline_keys }
		: ($data && $data->{expanded})
			? { map { $_ => 1 } split(/,/, $data->{expanded}) }
			: {};
	$this->{_selected_keys} = {};

	$this->_loadOcpnDb();
	_buildAndRestore($this);

	$this->installVisibilityObserver();

	return $this;
}


sub getDataForIniFile
{
	my ($this) = @_;
	$this->_captureExpandedInto() if $this->{_loaded} && $this->{tree}->GetCount() > 0;
	return { sash => $this->GetSashPosition() };
}


#---------------------------------
# data source -- shape the ocdb into a pane-friendly db
#---------------------------------
# navOCPN holds the ocdb as marks/routes/tracks keyed by uuid.  We snapshot it
# once per refresh into $this->{_db} with the SAME record shape winE80/winFSH
# use, so the winTreeBase accessors and feature builders work unchanged:
#   waypoints => { uuid => { uuid,name,comment,lat,lon,sym,color,guid,origin,
#                            icon,is_standalone } }
#   routes    => { uuid => { uuid,name,comment,color,guid,origin,
#                            wpts=>[ resolved wp records ] } }
#   tracks    => { uuid => { uuid,name,color,guid,origin,points=>[{lat,lon,ts}] } }
# Pure route-vertices (is_standalone==0) are held in the marks map (routes
# resolve them) but are NOT surfaced under My Waypoints.

sub _loadOcpnDb
{
	my ($this) = @_;
	# One central projection (navOCPN::shapedDb) feeds both this pane and the
	# navOps snapshot, so the two never drift.
	$this->{_db} = navOCPN::shapedDb();

	# Tree swatches show each mark's actual OpenCPN glyph (15px), not a derived
	# E80 sym.  Build the name->bitmap map once per vocabulary hash (cached to
	# disk by nmOCPNIcons, so refreshes are cheap).
	my $h = navOCPN::currentIconHash();
	if (!defined($this->{_swatch_hash}) || $this->{_swatch_hash} ne $h)
	{
		$this->{_swatch_by_name} = nmOCPNIcons::bitmapMapByName($h, 15);
		$this->{_swatch_hash}    = $h;
	}
}


# _swatchSpec -- OVERRIDE the winTreeColors default (which returns an E80 sym for
# a waypoint).  An OpenCPN mark shows its real glyph via the 'bitmap' kind; a mark
# whose icon isn't in the live vocabulary (names-only / not yet fetched) falls
# back to the derived sym so the row still shows something.
sub _swatchSpec
{
	my ($this, $node) = @_;
	my $type = $node->{type} // '';
	if ($type eq 'waypoint')
	{
		my $icon = $node->{data}{icon} // '';
		my $bmp  = ($icon ne '') ? $this->{_swatch_by_name}{$icon} : undef;
		return { kind => 'bitmap', key => "ocpn:$icon", value => $bmp } if $bmp && $bmp->IsOk();
		return { kind => 'sym', value => ($node->{data}{sym} // 0) + 0 };
	}
	elsif ($type eq 'route' || $type eq 'track')
	{
		my $cidx = ($node->{data}{color} // 0) + 0;
		return { kind => 'color', value => ($E80_ROUTE_COLOR_ABGR[$cidx] // 'FF888888') };
	}
	return undef;
}


#---------------------------------
# refresh
#---------------------------------

sub refresh
{
	my ($this) = @_;
	display($dbg_wocpn+1, 0, "winOCPN::refresh");
	if ($this->{tree}->GetCount() > 0)
	{
		$this->_captureExpandedInto();
		$this->_captureSelectedInto();
		$this->_captureFirstVisibleInto();
	}
	$this->_loadOcpnDb();
	_buildAndRestore($this);
}


#---------------------------------
# tree build
#---------------------------------

sub _buildAndRestore
{
	my ($this) = @_;
	my $tree = $this->{tree};
	return if !$tree;

	$tree->DeleteAllItems();
	$this->{detail}->SetValue('');

	my @prev_visible = getAllOCPNVisibleUUIDs();
	if (@prev_visible)
	{
		removeRenderFeatures('ocpn', \@prev_visible);
		clearAllOCPNVisible();
	}

	my $db   = $this->{_db} || { waypoints => {}, routes => {}, tracks => {} };
	my $root = $tree->AddRoot('OCPN');

	my $n_total = scalar(keys %{$db->{waypoints}}) + scalar(keys %{$db->{routes}}) + scalar(keys %{$db->{tracks}});
	my $top = $tree->AppendItem($root, ($n_total ? 'OpenCPN' : 'OpenCPN (no plugin connected)'), -1, -1,
		Wx::TreeItemData->new({ type => 'root', data => { name => 'OpenCPN' } }));
	$tree->SetItemBold($top, 1);
	$this->{_top_item} = $top;

	_buildGroups($this, $tree, $root, $db);
	_buildRoutes($this, $tree, $root, $db);
	_buildTracks($this, $tree, $root, $db);

	$this->{_loaded} = 1;
	winTreeBase::_walkRestoreStateImages($this, $tree, $root);
	$this->_syncLeafletAfterRebuild();
	$tree->Expand($root);
	winTreeBase::_walkRestoreExpanded($tree, $root, $this->{_expanded_keys});
	winTreeBase::_walkRestoreSelected($tree, $root, $this->{_selected_keys});
	winTreeBase::_walkRestoreFirstVisible($tree, $root, $this->{_first_visible_key});
}


sub _buildGroups
{
	# OpenCPN has NO group concept (sec 6): standalone marks are a flat list.  So
	# unlike winE80/winFSH we do NOT wrap them in a "Groups" header -- the single
	# "Marks" node (labelled to match OpenCPN's own UI) sits directly under the root.
	# It keeps the my_waypoints
	# type (navOps enumerates + the base visibility walker toggles the whole subtree
	# off that node), so cut/copy/paste and show/hide-all still work without the
	# extra folder level.
	my ($this, $tree, $root, $db) = @_;
	my $wps = $db->{waypoints} // {};

	my @uuids = grep { $wps->{$_}{is_standalone} }
	            sort { winTreeBase::_name_sort_key($wps->{$a}{name}) cmp winTreeBase::_name_sort_key($wps->{$b}{name}) }
	            keys %$wps;
	my $n     = scalar @uuids;
	my $label = $n ? "Marks ($n)" : 'Marks';
	my $mw    = $tree->AppendItem($root, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'my_waypoints' }));
	for my $uuid (@uuids)
	{
		my $wp   = $wps->{$uuid};
		my $item = $tree->AppendItem($mw, $wp->{name} ne '' ? $wp->{name} : $uuid, -1, -1,
			Wx::TreeItemData->new({ type => 'waypoint', uuid => $uuid, data => $wp }));
		$this->_setSwatch($item);
	}

	return $mw;
}


sub _buildRoutes
{
	my ($this, $tree, $root, $db) = @_;
	my $routes = $db->{routes} // {};

	my $hdr = $tree->AppendItem($root, 'Routes', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'routes' }));

	for my $uuid (sort { winTreeBase::_name_sort_key($routes->{$a}{name}) cmp winTreeBase::_name_sort_key($routes->{$b}{name}) }
	              keys %$routes)
	{
		my $r    = $routes->{$uuid};
		my $wpts = $r->{wpts} // [];
		my $n    = scalar @$wpts;
		my $route_item = $tree->AppendItem($hdr, ($r->{name} ne '' ? $r->{name} : $uuid) . " ($n pts)", -1, -1,
			Wx::TreeItemData->new({ type => 'route', uuid => $uuid, data => $r }));
		$this->_setSwatch($route_item);

		for my $i (0 .. $#$wpts)
		{
			my $wp    = $wpts->[$i];
			my $label = ($wp->{name} // '') ne '' ? $wp->{name} : ($wp->{uuid} // '?');
			$tree->AppendItem($route_item, $label, -1, -1,
				Wx::TreeItemData->new({
					type       => 'route_point',
					uuid       => $wp->{uuid},
					route_uuid => $uuid,
					position   => $i + 1,
					data       => $wp,
				}));
		}
	}

	return $hdr;
}


sub _buildTracks
{
	my ($this, $tree, $root, $db) = @_;
	my $tracks = $db->{tracks} // {};
	my $n      = scalar keys %$tracks;
	my $label  = $n ? "Tracks ($n)" : 'Tracks';
	my $hdr    = $tree->AppendItem($root, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'tracks' }));

	for my $uuid (sort { winTreeBase::_name_sort_key($tracks->{$a}{name}) cmp winTreeBase::_name_sort_key($tracks->{$b}{name}) }
	              keys %$tracks)
	{
		my $t   = $tracks->{$uuid};
		my $pts = $t->{cnt} // (ref $t->{points} eq 'ARRAY' ? scalar @{$t->{points}} : 0);
		my $item = $tree->AppendItem($hdr, ($t->{name} ne '' ? $t->{name} : $uuid) . " ($pts pts)", -1, -1,
			Wx::TreeItemData->new({ type => 'track', uuid => $uuid, data => $t }));
		$this->_setSwatch($item);
	}

	return $hdr;
}


#---------------------------------
# selection -> detail  (read-only)
#---------------------------------

sub onTreeSelect
{
	my ($this, $event) = @_;
	my $item = $event->GetItem();
	return if !$item->IsOk();
	my $item_data = $this->{tree}->GetItemData($item);
	return if !$item_data;
	my $node = $item_data->GetData();
	return if ref $node ne 'HASH';

	my $type = $node->{type} // '';
	my $text = '';

	if ($type eq 'root')
	{
		$this->_clearEditor();
		$text = "OpenCPN spoke -- a live view of the connected plugin's inventory.\n";
		my $pv = navOCPN::peerProtocolVersion();
		$text .= sprintf("  %-14s = %s\n", 'navMate speaks', navOCPN::protocolVersion());
		$text .= sprintf("  %-14s = %s\n", 'plugin speaks',  ($pv ne '' ? $pv : '(none yet)'));
	}
	elsif ($type eq 'header')
	{
		$this->_clearEditor();
		$text = "($node->{kind})";
	}
	elsif ($type eq 'my_waypoints')
	{
		$this->_clearEditor();
		$text = "Standalone OpenCPN marks (not route vertices).";
	}
	elsif ($type eq 'route_point' && $node->{data})
	{
		# Route vertices are read-only in the pane (edit the parent route, or
		# the standalone mark if it is shared).
		$this->_clearEditor();
		$text = _ocpnRoutePointText($node);
	}
	elsif ($type eq 'waypoint' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = _ocpnWaypointText($node);
	}
	elsif ($type eq 'route' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = _ocpnRouteText($node);
	}
	elsif ($type eq 'track' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = _ocpnTrackText($node);
	}

	$this->{detail}->SetValue($text);
}


sub _ocpnRoutePointText
{
	my ($node) = @_;
	my $wp   = $node->{data} // {};
	my $text = '';
	$text .= sprintf("  %-12s = %s\n", 'position',   $node->{position}   // '');
	$text .= sprintf("  %-12s = %s\n", 'route_uuid', $node->{route_uuid} // '');
	$text .= sprintf("  %-12s = %s\n", 'uuid',       $node->{uuid}       // '');
	$text .= sprintf("  %-12s = %s\n", 'name',       $wp->{name}         // '');
	$text .= latLonLineText($wp->{lat}, $wp->{lon}) if defined $wp->{lat} && defined $wp->{lon};
	return $text;
}


sub _ocpnWaypointText
{
	my ($node) = @_;
	my $wp   = $node->{data};
	my $text = '';
	$text .= sprintf("  %-12s = %s\n", 'uuid',    $node->{uuid} // '') if $node->{uuid};
	$text .= sprintf("  %-12s = %s\n", 'guid',    $wp->{guid} // '')   if $wp->{guid};
	$text .= sprintf("  %-12s = %s\n", 'origin',  $wp->{origin} // '');
	$text .= sprintf("  %-12s = %s\n", 'name',    $wp->{name}    // '');
	$text .= sprintf("  %-12s = %s\n", 'comment', $wp->{comment} // '') if ($wp->{comment} // '') ne '';
	$text .= latLonLineText($wp->{lat}, $wp->{lon});
	$text .= sprintf("  %-12s = %s\n", 'icon',    $wp->{icon}) if ($wp->{icon} // '') ne '';
	$text .= sprintf("  %-12s = %s\n", 'sym',     symText($wp->{sym})) if defined $wp->{sym};
	$text .= _ocpnBText($wp->{b});
	return $text;
}


#---------------------------------
# _ocpnBText($b) -- the OpenCPN category-B superset, read-only (sec 6)
#---------------------------------
# Every OpenCPN-only field navMate carries but has no canonical home for, shown
# read-only in the detail pane so the user sees the full OpenCPN object even
# where it isn't editable.  Accepts a mark, route, or track `b` blob (each with
# its own subset) and prints only the keys present.

sub _bBool { return (defined $_[0] && $_[0]) ? 'yes' : 'no'; }

sub _ocpnBText
{
	my ($b) = @_;
	return '' if ref($b) ne 'HASH' || !%$b;
	my $t = "\n  -- OpenCPN fields --\n";
	# route/track string B-fields
	$t .= sprintf("  %-14s = %s\n", 'from', $b->{from}) if defined $b->{from} && $b->{from} ne '';
	$t .= sprintf("  %-14s = %s\n", 'to',   $b->{to})   if defined $b->{to}   && $b->{to}   ne '';
	# visibility (in OpenCPN -- distinct from navMate map visibility)
	$t .= sprintf("  %-14s = %s\n", 'visible(OCPN)', _bBool($b->{visible})) if exists $b->{visible};
	$t .= sprintf("  %-14s = %s\n", 'name_shown',    _bBool($b->{name_shown})) if exists $b->{name_shown};
	$t .= sprintf("  %-14s = %s\n", 'active[R]',      _bBool($b->{active}))     if exists $b->{active};
	# mark scale / nav fields
	if (exists $b->{scamin_on})
	{
		$t .= sprintf("  %-14s = %s\n", 'scamin',
			($b->{scamin_on} ? ($b->{scamin} // 0) : 'off'));
		$t .= sprintf("  %-14s = %s\n", 'scamax', $b->{scamax}) if ($b->{scamax} // 0) != 0;
	}
	$t .= sprintf("  %-14s = %s\n", 'arrival_radius', $b->{arrival_radius})
		if defined $b->{arrival_radius} && $b->{arrival_radius} != 0;
	$t .= sprintf("  %-14s = %s\n", 'planned_speed', $b->{planned_speed})
		if defined $b->{planned_speed} && $b->{planned_speed} != 0;
	$t .= sprintf("  %-14s = %s\n", 'tide_station', $b->{tide_station})
		if defined $b->{tide_station} && $b->{tide_station} ne '';
	$t .= sprintf("  %-14s = %s\n", 'etd', scalar(localtime($b->{etd})))
		if defined $b->{etd} && $b->{etd} != 0;
	my $rr = $b->{range_rings};
	if (ref($rr) eq 'HASH' && ($rr->{count} // 0) > 0)
	{
		$t .= sprintf("  %-14s = %d @ %s %s, %s\n", 'range_rings',
			$rr->{count}, $rr->{space}, ($rr->{units} ? 'km' : 'nm'), $rr->{color} // '');
	}
	my $hl = $b->{hyperlinks};
	if (ref($hl) eq 'ARRAY' && @$hl)
	{
		$t .= sprintf("  %-14s = %d link(s)\n", 'hyperlinks', scalar @$hl);
		for my $h (@$hl)
		{
			next if ref($h) ne 'HASH';
			$t .= sprintf("      %s %s\n", ($h->{desc} // ''), ($h->{link} // ''));
		}
	}
	return $t;
}


sub _ocpnRouteText
{
	my ($node) = @_;
	my $r    = $node->{data};
	my $wpts = $r->{wpts} // [];
	my $text = '';
	$text .= sprintf("  %-12s = %s\n", 'uuid',    $node->{uuid} // '') if $node->{uuid};
	$text .= sprintf("  %-12s = %s\n", 'guid',    $r->{guid} // '')    if $r->{guid};
	$text .= sprintf("  %-12s = %s\n", 'origin',  $r->{origin} // '');
	$text .= sprintf("  %-12s = %s\n", 'name',    $r->{name}    // '');
	$text .= sprintf("  %-12s = %s\n", 'comment', $r->{comment} // '') if ($r->{comment} // '') ne '';
	$text .= sprintf("  %-12s = %d\n", 'points',  scalar @$wpts);
	$text .= _ocpnBText($r->{b});
	$text .= "\n" . routePointsText($wpts) if @$wpts;
	return $text;
}


sub _ocpnTrackText
{
	my ($node) = @_;
	my $track  = $node->{data};
	my $points = ref $track->{points} eq 'ARRAY' ? $track->{points} : [];
	my $text   = '';
	$text .= sprintf("  %-12s = %s\n", 'uuid',   $node->{uuid} // '') if $node->{uuid};
	$text .= sprintf("  %-12s = %s\n", 'guid',   $track->{guid} // '') if $track->{guid};
	$text .= sprintf("  %-12s = %s\n", 'origin', $track->{origin} // '');
	$text .= sprintf("  %-12s = %s\n", 'name',   $track->{name}  // '');
	$text .= sprintf("  %-12s = %d\n", 'points', scalar @$points);
	$text .= _ocpnBText($track->{b});
	$text .= trackEndpointsText($track);
	$text .= "\n" . trackPointsText($points, variable => 1) if @$points;
	return $text;
}


#---------------------------------
# editor (OpenCPN-tailored) -- Save enqueues a field-level UPDATE command (sec 8)
#---------------------------------
# Basic strip: name/comment/icon/lat/lon + OpenCPN visible/name_shown (active is
# [R], read-only) for a mark; name/comment/from/to/visible for a route; name/
# from/to for a track.  The icon picker is the OpenCPN vocabulary (nmOCPNIcons),
# not the E80 sym set.  Waypoints also get the Extended expander (scale/rings/
# tide/etd).  Save DIFFS the controls against the loaded values and pushes ONLY
# the changed fields as an 'update', so the plugin's read-modify-write leaves
# every untouched OpenCPN-only field at its live value (protocol sec 8).

sub _numStr { return (defined $_[0] && $_[0] ne '') ? "$_[0]" : ''; }
sub _txtNum
{
	my ($s) = @_;
	return undef if !defined $s;
	$s =~ s/^\s+|\s+$//g;
	return undef if $s eq '';
	return ($s =~ /^-?\d*\.?\d+$/) ? $s + 0 : undef;
}
sub _numOr { my ($v, $d) = @_; return (defined $v && $v ne '') ? $v + 0 : $d; }

sub _loadEditor
{
	my ($this, $node) = @_;
	my $type = $node->{type} // '';
	my $uuid = $node->{uuid};
	my $data = $node->{data} // {};
	my $b    = (ref($data->{b}) eq 'HASH') ? $data->{b} : {};

	my $is_wp = ($type eq 'waypoint');
	my $is_rt = ($type eq 'route');
	my $is_tk = ($type eq 'track');

	$this->{_edit_uuid}    = $uuid;
	$this->{_edit_type}    = $type;
	$this->{_edit_data}    = $data;
	$this->{_editor_dirty} = 0;

	$this->{ed_title}->SetLabel($is_wp ? 'Waypoint' : $is_rt ? 'Route' : $is_tk ? 'Track' : '');

	my @fields = ('name');
	push @fields, 'comment'  if $is_wp || $is_rt;
	push @fields, 'icon'     if $is_wp;
	push @fields, 'lat'      if $is_wp;
	push @fields, 'lon'      if $is_wp;
	push @fields, 'from'     if $is_rt || $is_tk;
	push @fields, 'to'       if $is_rt || $is_tk;
	push @fields, 'ocpnvis'  if $is_wp || $is_rt;
	push @fields, 'nameshow' if $is_wp;
	push @fields, 'active'   if $is_wp || $is_rt;
	$this->{_ed_fields} = \@fields;

	$this->{_loading_editor} = 1;

	$this->{ed_name}->SetValue($data->{name} // '');
	$this->{ed_comment}->SetValue($data->{comment} // '') if $is_wp || $is_rt;

	if ($is_wp)
	{
		my ($lat, $lon) = $this->_wpLatLon($data);
		$this->{ed_lat}->SetValue(sprintf('%.6f', $lat));
		$this->{ed_lon}->SetValue(sprintf('%.6f', $lon));
		winTreeBase::_updateLatDDM($this);
		winTreeBase::_updateLonDDM($this);
		_reloadIconPicker($this);
		$this->{ed_icon}->setIconByName($data->{icon} // '');
		_loadExtended($this, $b);
	}
	if ($is_rt || $is_tk)
	{
		$this->{ed_from}->SetValue($b->{from} // '');
		$this->{ed_to}->SetValue($b->{to}     // '');
	}
	$this->{ed_ocpn_visible}->SetValue($b->{visible} ? 1 : 0) if $is_wp || $is_rt;
	$this->{ed_name_shown}->SetValue($b->{name_shown} ? 1 : 0) if $is_wp;
	$this->{ed_active}->SetLabel($b->{active} ? 'yes' : 'no')  if $is_wp || $is_rt;

	# header checkbox = navMate MAP visibility (navVisibility), NOT OpenCPN visible
	$this->{ed_visible}->Show(1);
	$this->{ed_visible}->Set3StateValue(
		$this->_getVisible($uuid // '') ? wxCHK_CHECKED : wxCHK_UNCHECKED);

	$this->{_ext_show} = $is_wp;   # Extended expander is waypoints-only
	_layoutOcpnEditor($this, \@fields);

	$this->{_loading_editor} = 0;
	$this->{ed_save}->Enable(0);
}


# _reloadIconPicker -- populate the picker from the live vocabulary.  Reloads
# when the vocabulary hash changes (or the combo is still empty) so a picker
# built before the plugin connected fills in once icons arrive; otherwise a no-op
# so waypoint-to-waypoint selection stays snappy.
sub _reloadIconPicker
{
	my ($this) = @_;
	my $h = navOCPN::currentIconHash();
	return if $this->{ed_icon}->GetCount() > 0
		&& defined($this->{_icon_hash_loaded})
		&& $this->{_icon_hash_loaded} eq $h;
	$this->{ed_icon}->loadModel(nmOCPNIcons::pickerModel($h));
	$this->{_icon_hash_loaded} = $h;
}


# _loadExtended -- fill the Extended controls from a mark's `b` blob.
sub _loadExtended
{
	my ($this, $b) = @_;
	$b ||= {};
	my $scamin = $b->{scamin};
	$scamin = undef if defined $scamin && $scamin == 2147483646;   # sentinel -> blank
	$this->{ed_scamin_on}->SetValue($b->{scamin_on} ? 1 : 0);
	$this->{ed_scamin}->SetValue(_numStr($scamin));
	$this->{ed_scamax}->SetValue(_numStr($b->{scamax}));
	$this->{ed_arrival}->SetValue(_numStr($b->{arrival_radius}));
	$this->{ed_pspeed}->SetValue(_numStr($b->{planned_speed}));
	my $rr = (ref($b->{range_rings}) eq 'HASH') ? $b->{range_rings} : {};
	$this->{ed_rr_show}->SetValue($rr->{show} ? 1 : 0);
	$this->{ed_rr_count}->SetValue(_numStr($rr->{count}));
	$this->{ed_rr_space}->SetValue(_numStr($rr->{space}));
	$this->{ed_rr_units}->SetSelection(($rr->{units} // 0) ? 1 : 0);
	$this->{ed_rr_color}->SetValue($rr->{color} // '');
	$this->{ed_tide}->SetValue($b->{tide_station} // '');
	$this->{ed_etd}->SetValue(_numStr($b->{etd}));
}


sub _onSave
{
	my ($this, $event) = @_;
	my $uuid = $this->{_edit_uuid};
	my $type = $this->{_edit_type} // '';
	return if !$uuid;
	my $orig = $this->{_edit_data} // {};
	my $ob   = (ref($orig->{b}) eq 'HASH') ? $orig->{b} : {};

	if ($type eq 'waypoint')
	{
		# MARKS support field-level read-modify-write on the plugin (sec 8): push
		# ONLY the changed fields.
		my %chg;
		my $name = $this->{ed_name}->GetValue();
		$chg{name} = $name if $name ne ($orig->{name} // '');
		my $c = $this->{ed_comment}->GetValue();
		$chg{description} = $c if $c ne ($orig->{comment} // '');

		my $lat = parseLatLon($this->{ed_lat}->GetValue());
		my $lon = parseLatLon($this->{ed_lon}->GetValue());
		if (!defined($lat) || !defined($lon))
		{
			warning(0, 0, "winOCPN: invalid lat/lon - save aborted");
			return;
		}
		my ($olat, $olon) = $this->_wpLatLon($orig);
		$chg{lat} = $lat + 0 if abs(($lat + 0) - ($olat + 0)) > 1e-9;
		$chg{lon} = $lon + 0 if abs(($lon + 0) - ($olon + 0)) > 1e-9;
		my $icon = $this->{ed_icon}->getIconName();
		$chg{icon} = $icon if $icon ne ($orig->{icon} // '');
		my $vis = $this->{ed_ocpn_visible}->GetValue() ? 1 : 0;
		$chg{visible} = $vis if $vis != ($ob->{visible} ? 1 : 0);
		my $ns = $this->{ed_name_shown}->GetValue() ? 1 : 0;
		$chg{name_shown} = $ns if $ns != ($ob->{name_shown} ? 1 : 0);
		_collectExtendedChanges($this, $ob, \%chg);

		if (%chg)
		{
			navOCPN::pushFieldUpdate('waypoint', $uuid, \%chg);
			$this->{tree}->SetItemText($this->{_edit_item}, $name)
				if $this->{_edit_item} && exists $chg{name};
		}
	}
	elsif ($type eq 'route' || $type eq 'track')
	{
		# ROUTES/TRACKS are full-embed rebuilds on the plugin -- there is NO
		# partial field update (a bare {visible} would drop name + points).  Push
		# the COMPLETE object (name/comment/points + edited B) as an upsert 'add'.
		my $item = _buildFullRouteTrackItem($this, $type, $uuid, $orig, $ob);
		navOCPN::pushItems([$item], 'add');
		$this->{tree}->SetItemText($this->{_edit_item}, $this->{ed_name}->GetValue())
			if $this->{_edit_item};
	}

	$this->{ed_save}->Enable(0);
	$this->{_editor_dirty} = 0;
}


# _buildFullRouteTrackItem -- assemble the COMPLETE clip item for a route/track
# Save (ocdb snapshot + the editor's edited fields), so the full-embed push keeps
# name, points, and the B set (from/to/visible) intact.
sub _buildFullRouteTrackItem
{
	my ($this, $type, $uuid, $orig, $ob) = @_;
	my $db = $this->{_db} || {};

	if ($type eq 'route')
	{
		my @rps;
		my $pos = 0;
		for my $wp (@{$orig->{wpts} // []})
		{
			my $full = $db->{waypoints}{$wp->{uuid} // ''} // $wp;
			push @rps, {
				type => 'route_point', uuid => $wp->{uuid}, route_uuid => $uuid,
				position => $pos++, data => { %$full },
			};
		}
		my %data = (
			%$orig,
			name    => $this->{ed_name}->GetValue(),
			comment => $this->{ed_comment}->GetValue(),
			b => {
				%$ob,
				from    => $this->{ed_from}->GetValue(),
				to      => $this->{ed_to}->GetValue(),
				visible => ($this->{ed_ocpn_visible}->GetValue() ? 1 : 0),
			},
		);
		return { type => 'route', uuid => $uuid, data => \%data, route_points => \@rps };
	}

	# track
	my %data = (
		%$orig,
		name => $this->{ed_name}->GetValue(),
		b => {
			%$ob,
			from => $this->{ed_from}->GetValue(),
			to   => $this->{ed_to}->GetValue(),
		},
	);
	return { type => 'track', uuid => $uuid, data => \%data };
}


# _collectExtendedChanges -- diff the Extended controls into %chg (wire shape).
sub _collectExtendedChanges
{
	my ($this, $ob, $chg) = @_;

	my $on = $this->{ed_scamin_on}->GetValue() ? 1 : 0;
	$chg->{scamin_on} = $on if $on != ($ob->{scamin_on} ? 1 : 0);

	# blank scamin -> the OpenCPN no-scamin sentinel
	my $sc = _txtNum($this->{ed_scamin}->GetValue());
	$sc = 2147483646 if !defined $sc;
	$chg->{scamin} = $sc if $sc != _numOr($ob->{scamin}, 2147483646);

	my $sx = _txtNum($this->{ed_scamax}->GetValue()) // 0;
	$chg->{scamax} = $sx if $sx != _numOr($ob->{scamax}, 0);

	my $ar = _txtNum($this->{ed_arrival}->GetValue()) // 0;
	$chg->{arrival_radius} = $ar if abs($ar - _numOr($ob->{arrival_radius}, 0)) > 1e-9;

	my $ps = _txtNum($this->{ed_pspeed}->GetValue()) // 0;
	$chg->{planned_speed} = $ps if abs($ps - _numOr($ob->{planned_speed}, 0)) > 1e-9;

	my $tide = $this->{ed_tide}->GetValue();
	$chg->{tide_station} = $tide if $tide ne ($ob->{tide_station} // '');

	my $etd = int(_txtNum($this->{ed_etd}->GetValue()) // 0);
	$chg->{etd} = $etd if $etd != int(_numOr($ob->{etd}, 0));

	# range rings: send the whole nested struct if any component changed.
	my $orr = (ref($ob->{range_rings}) eq 'HASH') ? $ob->{range_rings} : {};
	my %nrr = (
		count => int(_txtNum($this->{ed_rr_count}->GetValue()) // 0),
		space => _txtNum($this->{ed_rr_space}->GetValue()) // 0,
		units => ($this->{ed_rr_units}->GetSelection() > 0) ? 1 : 0,
		color => $this->{ed_rr_color}->GetValue(),
		show  => $this->{ed_rr_show}->GetValue() ? 1 : 0,
	);
	if (   $nrr{count}            != int(_numOr($orr->{count}, 0))
		|| abs($nrr{space} - _numOr($orr->{space}, 0)) > 1e-9
		|| $nrr{units}            != (_numOr($orr->{units}, 0) ? 1 : 0)
		|| ($nrr{color} // '')    ne ($orr->{color} // '')
		|| $nrr{show}             != ($orr->{show} ? 1 : 0))
	{
		$chg->{range_rings} = \%nrr;
	}
}


#---------------------------------
# Extended expander -- build / layout / toggle  (waypoints only)
#---------------------------------

sub _buildExtendedPanel
{
	my ($this, $ext) = @_;
	my ($LX, $CX, $LW, $H, $RH) = (6, 100, 90, 22, 26);
	my $rowy = sub { return 4 + $_[0] * $RH; };
	my $lbl  = sub { Wx::StaticText->new($ext, -1, $_[0], [$LX, $rowy->($_[1])], [$LW, $H]); };
	my $txt  = sub { Wx::TextCtrl->new($ext, -1, '', [$CX, $rowy->($_[0])], [$_[1] // 120, $H]); };

	$this->{ed_scamin_on} = Wx::CheckBox->new($ext, -1, 'Use scale-min', [$LX, $rowy->(0)], [-1, $H]);
	$lbl->('  min scale', 1);  $this->{ed_scamin}  = $txt->(1);
	$lbl->('  max scale', 2);  $this->{ed_scamax}  = $txt->(2);
	$lbl->('arrival (nm)', 3); $this->{ed_arrival} = $txt->(3);
	$lbl->('speed (kt)', 4);   $this->{ed_pspeed}  = $txt->(4);
	$this->{ed_rr_show} = Wx::CheckBox->new($ext, -1, 'Range rings', [$LX, $rowy->(5)], [-1, $H]);
	$lbl->('  count', 6);      $this->{ed_rr_count} = $txt->(6, 50);
	$this->{ed_rr_units} = Wx::Choice->new($ext, -1, [$CX + 60, $rowy->(6)], [56, $H], ['nm', 'km']);
	$lbl->('  spacing', 7);    $this->{ed_rr_space} = $txt->(7);
	$lbl->('  color', 8);      $this->{ed_rr_color} = $txt->(8);
	$lbl->('tide stn', 9);     $this->{ed_tide}    = $txt->(9);
	$lbl->('etd (epoch)', 10); $this->{ed_etd}     = $txt->(10);

	$this->{_ext_full_h} = 4 + 11 * $RH + 8;   # full content height (no internal scroll)
	return;
}

my $OCPN_MIN_DETAIL = 120;

# _layoutOcpnEditor -- lay out the EDITOR ZONE ($ed_scroll) only.  The header
# (Save/title/Show-on-Map/Extended) is a fixed strip owned by right_panel.  Here:
# stretch the free-text controls to the zone width, let the shared winTreeBase
# walker position the rows, drop the Extended block in-line below them when open,
# and set $ed_scroll's VIRTUAL height so a scrollbar appears WITHIN the zone
# (never touching the detail zone).  _layoutZones then places the three zones.
sub _layoutOcpnEditor
{
	my ($this, $fields) = @_;
	my $sc = $this->{ed_scroll} or return;
	# Reset the scroll to top BEFORE repositioning.  Child positions are then
	# unambiguous (no stale scroll offset), which is what makes COLLAPSE lay out
	# correctly -- otherwise, having scrolled down into the open Extended block,
	# collapsing left the rows shifted off-view (blanks above Name, fields below
	# Icon unreachable).
	$sc->Scroll(0, 0);

	# ALWAYS reserve the vertical-scrollbar width so the content width is identical
	# whether or not the bar is showing -- otherwise opening Extended (which adds
	# the bar) resizes Name/Comment WIDER, sliding them under it.  Width comes from
	# right_panel (scrollbar-free), not $ed_scroll's client size (which shrinks when
	# its own bar appears).
	my $VSB = 18;
	my $zw  = $this->{right_panel}->GetClientSize()->GetWidth(); $zw = 100 if $zw < 100;
	my $sw  = $zw - $VSB;

	# stretch the free-text controls to the (scrollbar-reserved) content width
	my $cw = $sw - $this->{_ed_ctrl_x} - $this->{_ed_margin}; $cw = 80 if $cw < 80;
	$_->SetSize($cw, $this->{_ed_ctrl_h})
		for grep { $_ } @{$this}{qw(ed_name ed_from ed_to)};
	# comment is a 2-line multi-line editor -- taller than the 1-line controls
	$this->{ed_comment}->SetSize($cw, 2 * $this->{_ed_row_h} - 2)
		if $this->{ed_comment};

	winTreeBase::_layoutEditor($this, $fields);   # positions rows in $ed_scroll, sets _editor_height
	my $content_h = $this->{_editor_height} // 0;

	# Extended toggle is in the fixed header (shown only for waypoints).  When open,
	# a compact centered "EXTENDED FIELDS" seam sits right after the last field,
	# then the panel drops in-line below it, all inside the scroll zone.
	if ($this->{_ext_show})
	{
		$this->{ed_ext_toggle}->Show(1);
		if ($this->{_ext_open})
		{
			if (my $sep = $this->{ed_ext_sep})
			{
				my $sep_y = $content_h - ($this->{_ed_bottom_pad} // 0) + 2;
				$sep->Move([$this->{_ed_margin}, $sep_y]);
				$sep->SetSize($sw, 16);   # compact: no empty space above/below the text
				$sep->Show(1);
				$content_h = $sep_y + 16 + 3;
			}
			my $eh = $this->{_ext_full_h} || 150;
			$this->{ed_ext_panel}->Move([0, $content_h]);
			$this->{ed_ext_panel}->SetSize($sw, $eh);
			$this->{ed_ext_panel}->Show(1);
			$content_h += $eh;
		}
		else
		{
			$this->{ed_ext_sep}->Show(0)   if $this->{ed_ext_sep};
			$this->{ed_ext_panel}->Show(0);
		}
	}
	else
	{
		$this->{ed_ext_toggle}->Show(0);
		$this->{ed_ext_sep}->Show(0)   if $this->{ed_ext_sep};
		$this->{ed_ext_panel}->Show(0);
	}

	$sc->SetVirtualSize($sw, $content_h);
	_layoutZones($this);
}


# _layoutZones -- place the three fixed zones in right_panel: header strip (top,
# fixed height), editor scroll zone (fixed height, the only scroller), detail
# TextCtrl (fills the rest).  The zone heights are constants, so toggling Extended
# never moves the detail zone -- the editor zone just scrolls internally.
sub _layoutZones
{
	my ($this) = @_;
	my $rp = $this->{right_panel} or return;
	my $sc = $this->{ed_scroll}   or return;
	my $dt = $this->{detail}      or return;
	my $ss = $rp->GetClientSize();
	my $w  = $ss->GetWidth();  $w = 60 if $w < 60;
	my $h  = $ss->GetHeight(); $h = 60 if $h < 60;

	my $hh = $this->{_ocpn_header_h}    // 0;
	my $zh = $this->{_ocpn_edit_zone_h} // 200;
	# never starve the detail zone: cap the editor zone if the pane is short
	my $maxzh = $h - $hh - $OCPN_MIN_DETAIL;
	$zh = $maxzh if $zh > $maxzh;
	$zh = 40 if $zh < 40;

	$sc->SetSize(0, $hh, $w, $zh);
	my $dtop = $hh + $zh;
	my $dh   = $h - $dtop; $dh = 0 if $dh < 0;
	$dt->SetSize(0, $dtop, $w, $dh);
}

# The shared winTreeBase walker calls _resizeRightPanel after positioning rows;
# override it (the base stacks detail under the editor in ONE panel -- not our
# model) to just re-place our three zones.
sub _resizeRightPanel { _layoutZones($_[0]); }

# EVT_SIZE hook (name kept for the new() binding): re-fit the editor zone (which
# re-lays the rows, restretches the controls, and re-places the three zones).
sub _resizeOcpnRightPanel { _layoutOcpnEditor($_[0], $_[0]->{_ed_fields} || []); }

sub _onExtToggle
{
	my ($this, $event) = @_;
	$this->{_ext_open} = $this->{_ext_open} ? 0 : 1;
	$this->{ed_ext_toggle}->SetLabel($this->{_ext_open} ? 'Extended v' : 'Extended >');
	_layoutOcpnEditor($this, $this->{_ed_fields} || []);
}

# _clearEditor -- also hide the Extended expander, then defer to the base.
sub _clearEditor
{
	my ($this) = @_;
	$this->{_ext_show} = 0;
	$this->{_ext_open} = 0;
	if ($this->{ed_ext_toggle}) { $this->{ed_ext_toggle}->Show(0); $this->{ed_ext_toggle}->SetLabel('Extended >'); }
	$this->{ed_ext_panel}->Show(0) if $this->{ed_ext_panel};
	$this->SUPER::_clearEditor();
	# collapse the editor-zone scroll (no stale scrollbar from a prior Extended-open)
	if (my $sc = $this->{ed_scroll})
	{
		$sc->Scroll(0, 0);
		$sc->SetVirtualSize($sc->GetClientSize()->GetWidth(), $this->{_editor_height} // 0);
	}
}


#---------------------------------
# winTreeBase abstract overrides
#---------------------------------

sub _wpDataSource    { 'ocpn' }
sub _groupHasComment { 0 }

sub _wpLatLon
{
	my ($this, $wp) = @_;
	return (($wp->{lat}//0)+0, ($wp->{lon}//0)+0);
}

sub _wpColor { 'FF888888' }

sub _trackColorABGR
{
	my ($this, $track) = @_;
	my $cidx = defined($track->{color}) ? ($track->{color} + 0) : 0;
	return $E80_ROUTE_COLOR_ABGR[$cidx] // 'FF888888';
}

sub _getVisible         { getOCPNVisible($_[1]) }
sub _setVisible         { setOCPNVisible($_[1], $_[2]) }
sub _clearAllVisible    { clearAllOCPNVisible() }
sub _getAllVisibleUUIDs { getAllOCPNVisibleUUIDs() }
sub _batchRemoveVisible { batchRemoveOCPNVisible($_[1]) }

sub _routeWpts
{
	my ($this, $r) = @_;
	return map { { lat => ($_->{lat}//0)+0, lon => ($_->{lon}//0)+0, name => $_->{name} // '' } }
	       @{$r->{wpts} // []};
}

sub _groupMemberWpts
{
	# OpenCPN has no named groups; My Waypoints is the only container and its
	# members are the standalone marks.  Returned only for completeness (the
	# base calls this for 'group' nodes, which this pane never builds).
	my ($this, $data) = @_;
	return map { [$_->{uuid}, $_] }
	       grep { $_->{uuid} } @{$data->{wpts} // []};
}

sub _myWaypoints
{
	my ($this) = @_;
	my $db = $this->{_db} or return {};
	my $wps = $db->{waypoints} // {};
	return { map { $_ => $wps->{$_} } grep { $wps->{$_}{is_standalone} } keys %$wps };
}

sub _allWaypoints
{
	my ($this) = @_;
	my $db = $this->{_db} or return {};
	return $db->{waypoints} // {};
}

sub _allRoutes
{
	my ($this) = @_;
	my $db = $this->{_db} or return {};
	return $db->{routes} // {};
}

sub _allTracks
{
	my ($this) = @_;
	my $db = $this->{_db} or return {};
	return $db->{tracks} // {};
}


# Override _buildTrackFeature: OpenCPN track points are already plain decoded
# {lat,lon,ts} (protocol sec 11) -- NOT the FSH/E80 mod003 raw-encoded form the
# base's non-'db' branch would run through decodeTrackPoint.  So build the map
# feature directly from the decoded points, like the base's is_db branch.
sub _buildTrackFeature
{
	my ($this, $uuid, $track) = @_;
	my $pts = ref $track->{points} eq 'ARRAY' ? $track->{points} : [];
	return undef if !@$pts;
	my (@ts, $timed);
	for my $pt (@$pts)
	{
		my $t = ($pt->{ts} // 0) > 0 ? $pt->{ts} + 0 : undef;
		$timed = 1 if defined $t;
		push @ts, $t;
	}
	return {
		type       => 'Feature',
		properties => {
			uuid        => $uuid,
			name        => $track->{name} // '',
			obj_type    => 'track',
			data_source => 'ocpn',
			color       => $this->_trackColorABGR($track),
			point_count => scalar(@$pts) + 0,
			depth_cm    => [ map { undef } @$pts ],
			ts          => \@ts,
			track_kind  => $timed ? 'timed' : 'stock',
		},
		geometry   => { type => 'LineString',
			coordinates => [map { [($_->{lon}//0)+0, ($_->{lat}//0)+0] } @$pts] },
	};
}


#---------------------------------
# right-click context menu (navOps 'ocpn' panel)
#---------------------------------

sub onTreeRightClick
{
	my ($this, $event) = @_;
	my $item = $event->GetItem();
	return if !$item->IsOk();
	my $item_data = $this->{tree}->GetItemData($item);
	return if !$item_data;
	my $node = $item_data->GetData();
	return if ref $node ne 'HASH';

	if (!$this->{tree}->IsSelected($item))
	{
		$this->{tree}->UnselectAll();
		$this->{tree}->SelectItem($item, 1);
	}

	$this->{_right_click_node} = $node;
	my $menu = _buildContextMenu($this, $node);
	$this->PopupMenu($menu, [-1, -1]);
}


sub _buildContextMenu
{
	my ($this, $right_click_node) = @_;
	my $tree = $this->{tree};

	my @nodes;
	for my $item ($tree->GetSelections())
	{
		my $d = $tree->GetItemData($item);
		next if !$d;
		my $n = $d->GetData();
		push @nodes, $n if ref $n eq 'HASH';
	}
	$this->{_context_nodes} = \@nodes;

	my $menu = buildContextMenu('ocpn', $right_click_node, @nodes);

	# Rename... on a homogeneous waypoint/route/track selection (N=1 OK).
	if (isRenameHomogeneous('ocpn', @nodes))
	{
		$menu->AppendSeparator() if $menu->GetMenuItemCount() > 0;
		$menu->Append($CTX_CMD_RENAME, 'Rename...');
	}

	# Multi Edit on 2+ eligible (waypoint/route/track) items.
	my $n_eligible = 0;
	for my $n (@nodes)
	{
		my $t = $n->{type} // '';
		$n_eligible++ if $t eq 'waypoint' || $t eq 'route' || $t eq 'track';
	}
	if ($n_eligible >= 2)
	{
		$menu->AppendSeparator() if $menu->GetMenuItemCount() > 0;
		$menu->Append($CTX_CMD_MULTI_EDIT, "Multi Edit ($n_eligible items)...");
	}

	my $type = $right_click_node->{type} // '';
	if ($type ne 'root')
	{
		$menu->AppendSeparator() if $menu->GetMenuItemCount() > 0;
		$menu->Append($CTX_CMD_SHOW_MAP, 'Show on Map');
		$menu->Append($CTX_CMD_HIDE_MAP, 'Hide on Map');
		if ($type eq 'waypoint' || $type eq 'track' || $type eq 'route')
		{
			$menu->Append($CTX_CMD_FIND_THIS, 'Find This...');
		}
	}
	return $menu;
}


#---------------------------------
# Rename + Multi-Edit (bulk mutation -> outbound update commands)
#---------------------------------

sub _onRename
{
	my ($this, $event) = @_;
	my @nodes = @{$this->{_context_nodes} // []};
	onRenameOCPN($this, @nodes);
}


sub _onMultiEdit
{
	my ($this, $event) = @_;
	my @nodes = @{$this->{_context_nodes} // []};
	# openForSelection fetches current values, runs the dialog, and calls
	# _ocpnCommit (which enqueues the update commands).  It returns the list of
	# touched uuids; the pane refreshes from the plugin echo, so nothing else to
	# do here.
	winMultiEditor::openForSelection($this, \@nodes, _ocpnDescriptor());
}


sub _ocpnDescriptor
{
	# OpenCPN multi-edit: bulk comment (marks + routes) and sym (marks).  No
	# wp_type, no length limit.  The color row is shown as a palette index for
	# UI parity but is NOT pushed (OpenCPN marks have no palette color and the
	# wire carries none), so _ocpnCommit ignores color.
	return {
		fetch       => \&_ocpnFetch,
		commit      => \&_ocpnCommit,
		color_row   => 'palette_index',
		has_wp_type => 0,
		has_sym     => 1,
		comment_max => undef,
	};
}


sub _ocpnFetch
{
	my ($items) = @_;
	my $db = navOCPN::shapedDb();
	for my $it (@$items)
	{
		my $ot  = $it->{obj_type};
		my $rec = $ot eq 'waypoint' ? $db->{waypoints}{$it->{uuid}}
		        : $ot eq 'route'    ? $db->{routes}{$it->{uuid}}
		        : $ot eq 'track'    ? $db->{tracks}{$it->{uuid}}
		        :                     undef;
		next if !$rec;
		$it->{color} = 0;   # OpenCPN has no palette color
		if ($ot eq 'waypoint')
		{
			$it->{comment} = $rec->{comment} // '';
			$it->{sym}     = ($rec->{sym} // 0) + 0;
		}
		elsif ($ot eq 'route')
		{
			$it->{comment} = $rec->{comment} // '';
		}
	}
}


sub _ocpnCommit
{
	my ($items, $changes) = @_;
	my $db = navOCPN::shapedDb();
	my (@push, @touched);
	for my $it (@$items)
	{
		my $ot  = $it->{obj_type};
		my $rec = $ot eq 'waypoint' ? $db->{waypoints}{$it->{uuid}}
		        : $ot eq 'route'    ? $db->{routes}{$it->{uuid}}
		        : $ot eq 'track'    ? $db->{tracks}{$it->{uuid}}
		        :                     undef;
		next if !$rec;
		my %newrec = %$rec;
		my $dirty  = 0;
		if (exists $changes->{comment} && $ot ne 'track')
		{
			$newrec{comment} = $changes->{comment};
			$dirty = 1;
		}
		if (exists $changes->{sym} && $ot eq 'waypoint')
		{
			$newrec{sym} = $changes->{sym} + 0;
			delete $newrec{icon};   # re-derive icon from the new sym on push
			$dirty = 1;
		}
		next if !$dirty;
		my $item = navOps::_snapshotOCPNNode($db, { type => $ot, uuid => $it->{uuid}, data => \%newrec });
		push @push,    $item if $item;
		push @touched, $it->{uuid};
	}
	navOCPN::pushItems(\@push, 'add') if @push;
	return \@touched;
}


sub _onNmOpsCmd
{
	my ($this, $event) = @_;
	my $cmd_id      = $event->GetId();
	my $right_click = $this->{_right_click_node} // {};
	my @nodes       = @{$this->{_context_nodes} // []};
	onContextMenuCommand($cmd_id, 'ocpn', $right_click, $this->{tree}, @nodes);
}


#---------------------------------
# show / hide on map
#---------------------------------

sub _onTreeActivated
{
	my ($this, $event) = @_;
	_onShowHideOCPNMap($this, 1);
}

sub _onShowMap
{
	my ($this, $event) = @_;
	_onShowHideOCPNMap($this, 1);
}

sub _onHideMap
{
	my ($this, $event) = @_;
	_onShowHideOCPNMap($this, 0);
}

sub _onShowHideOCPNMap
{
	my ($this, $new_visible) = @_;
	my $tree = $this->{tree};

	my @items = $tree->GetSelections();
	return if !@items;

	for my $item (@items)
	{
		my $d = $tree->GetItemData($item);
		next if !$d;
		my $node = $d->GetData();
		next if ref $node ne 'HASH';
		$this->_applyNodeVisibility($item, $node, $new_visible);
	}

	$this->_refreshAncestorStates($_) for @items;
	openMapBrowser() if $new_visible && !isBrowserConnected();
}


sub _onFindThis
{
	my ($this, $event) = @_;
	my $node = $this->{_right_click_node} // {};
	my $type = $node->{type} // '';
	return if $type ne 'waypoint' && $type ne 'track' && $type ne 'route';
	my $uuid = $node->{uuid};
	return if !$uuid;
	my $db = $this->{_db};
	return if !$db;

	my %args = (
		frame    => $this->{frame},
		source   => 'ocpn',
		uuid     => $uuid,
		obj_type => $type,
		name     => ($node->{data} // {})->{name} // '',
	);

	if ($type eq 'waypoint')
	{
		my $wp = $node->{data} // {};
		$args{lat}  = ($wp->{lat} // 0) + 0;
		$args{lon}  = ($wp->{lon} // 0) + 0;
		$args{bbox} = { min_lat => $args{lat}, max_lat => $args{lat},
		                min_lon => $args{lon}, max_lon => $args{lon} };
		$args{hierarchy_path} = 'OpenCPN/Waypoints';
		$args{npts} = 1;
	}
	elsif ($type eq 'track')
	{
		my $t   = $db->{tracks}{$uuid};
		my $pts = $t ? ($t->{points} // []) : [];
		$args{points} = $pts;
		$args{npts}   = scalar @$pts;
		$args{bbox}   = navMatch::bboxOfPoints($pts);
		$args{hierarchy_path} = 'OpenCPN/Tracks';
	}
	elsif ($type eq 'route')
	{
		my $r = $db->{routes}{$uuid};
		my @pts;
		if ($r)
		{
			for my $w (@{$r->{wpts} // []})
			{
				push @pts, { lat => ($w->{lat}//0)+0, lon => ($w->{lon}//0)+0 };
			}
		}
		$args{points} = \@pts;
		$args{npts}   = scalar @pts;
		$args{bbox}   = navMatch::bboxOfPoints(\@pts);
		$args{hierarchy_path} = 'OpenCPN/Routes';
	}

	winFind::openForSubject(%args);
}


1;
