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
	my $right_panel = Wx::Panel->new($this, -1);
	$right_panel->SetBackgroundColour(
		Wx::SystemSettings::GetColour(wxSYS_COLOUR_BTNFACE));
	$this->{right_panel} = $right_panel;

	my $ED_MARGIN      = 8;
	my $ED_LABEL_W     = 60;
	my $ED_COL_GAP     = 8;
	my $ED_CTRL_X      = $ED_MARGIN + $ED_LABEL_W + $ED_COL_GAP;
	my $ED_CTRL_H      = 23;
	my $ED_ROW_GAP     = 2;
	my $ED_ROW_H       = $ED_CTRL_H + $ED_ROW_GAP;
	my $ED_HEADER_SIZE = $ED_MARGIN + $ED_ROW_H;
	my $ED_TITLE_W     = 80;
	my $ED_VIS_X       = $ED_CTRL_X + $ED_TITLE_W + 8;
	$this->{_ed_ctrl_x}      = $ED_CTRL_X;
	$this->{_ed_ctrl_h}      = $ED_CTRL_H;
	$this->{_ed_margin}      = $ED_MARGIN;
	$this->{_ed_header_size} = $ED_HEADER_SIZE;
	$this->{_ed_row_h}       = $ED_ROW_H;
	$this->{_ed_bottom_pad}  = $ED_ROW_H;

	my $ey = sub { $ED_HEADER_SIZE + $_[0] * $ED_ROW_H };

	$this->{ed_save} = Wx::Button->new($right_panel, -1, 'Save',
		[$ED_MARGIN, $ED_MARGIN], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_save}->Enable(0);

	$this->{ed_title} = Wx::StaticText->new($right_panel, -1, '',
		[$ED_CTRL_X, $ED_MARGIN], [$ED_TITLE_W, $ED_CTRL_H]);
	$this->{ed_title}->SetFont(
		Wx::Font->new(-1, wxFONTFAMILY_DEFAULT, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_BOLD));

	$this->{ed_visible} = Wx::CheckBox->new($right_panel, -1, 'Visible',
		[$ED_VIS_X, $ED_MARGIN], [-1, $ED_CTRL_H], wxCHK_3STATE);
	$this->{ed_visible}->Show(0);

	$this->{ed_lbl_name} = Wx::StaticText->new($right_panel, -1, 'Name',
		[$ED_MARGIN, $ey->(0)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_name} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(0)], [200, $ED_CTRL_H]);

	$this->{ed_lbl_comment} = Wx::StaticText->new($right_panel, -1, 'Comment',
		[$ED_MARGIN, $ey->(1)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_comment} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(1)], [200, $ED_CTRL_H]);

	$this->{ed_lbl_lat} = Wx::StaticText->new($right_panel, -1, 'Lat',
		[$ED_MARGIN, $ey->(2)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lat} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(2)], [110, $ED_CTRL_H]);
	$this->{ed_lat_ddm} = Wx::StaticText->new($right_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(2)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_lon} = Wx::StaticText->new($right_panel, -1, 'Lon',
		[$ED_MARGIN, $ey->(3)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lon} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(3)], [110, $ED_CTRL_H]);
	$this->{ed_lon_ddm} = Wx::StaticText->new($right_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(3)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_sym} = Wx::StaticText->new($right_panel, -1, 'Sym',
		[$ED_MARGIN, $ey->(4)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_sym} = makeSymComboBox($right_panel,
		[$ED_CTRL_X, $ey->(4)], [240, $ED_CTRL_H]);

	$this->{_ed_field_widgets} = {
		name    => [ 'ed_lbl_name',    'ed_name',    []            ],
		comment => [ 'ed_lbl_comment', 'ed_comment', []            ],
		lat     => [ 'ed_lbl_lat',     'ed_lat',     ['ed_lat_ddm'] ],
		lon     => [ 'ed_lbl_lon',     'ed_lon',     ['ed_lon_ddm'] ],
		sym     => [ 'ed_lbl_sym',     'ed_sym',     []            ],
	};

	$this->{detail} = Wx::TextCtrl->new($right_panel, -1, '',
		wxDefaultPosition, wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{detail}->SetFont(
		Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL));

	EVT_SIZE($right_panel, sub {
		my ($panel, $event) = @_;
		$event->Skip();
		my $w = $panel->GetSize()->GetWidth();
		my $ctrl_w = $w - $this->{_ed_ctrl_x} - $this->{_ed_margin};
		$ctrl_w = 80 if $ctrl_w < 80;
		$this->{ed_name}->SetSize($ctrl_w, $this->{_ed_ctrl_h});
		$this->{ed_comment}->SetSize($ctrl_w, $this->{_ed_ctrl_h});
		winTreeBase::_resizeRightPanel($this);
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
	EVT_COMBOBOX($this, $this->{ed_sym},     $this->can('_onFieldChanged'));
	EVT_BUTTON($this,   $this->{ed_save},    \&_onSave);
	EVT_CHECKBOX($this, $this->{ed_visible}, $this->can('_onEdVisibleChanged'));

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
}


#---------------------------------
# refresh
#---------------------------------

sub refresh
{
	my ($this) = @_;
	display($dbg_wocpn, 0, "winOCPN::refresh");
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
	# OpenCPN has no named groups (sec 6); everything standalone lands under a
	# single "My Waypoints" node, kept parallel to winE80/winFSH so navOps sees
	# the same tree shape.  The header (kind=>'groups') is what the base
	# visibility walker toggles for "all waypoints".
	my ($this, $tree, $root, $db) = @_;
	my $wps = $db->{waypoints} // {};

	my $hdr = $tree->AppendItem($root, 'Groups', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'groups' }));

	my @uuids = grep { $wps->{$_}{is_standalone} }
	            sort { winTreeBase::_name_sort_key($wps->{$a}{name}) cmp winTreeBase::_name_sort_key($wps->{$b}{name}) }
	            keys %$wps;
	my $n     = scalar @uuids;
	my $label = $n ? "My Waypoints ($n)" : 'My Waypoints';
	my $mw    = $tree->AppendItem($hdr, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'my_waypoints' }));
	for my $uuid (@uuids)
	{
		my $wp   = $wps->{$uuid};
		my $item = $tree->AppendItem($mw, $wp->{name} ne '' ? $wp->{name} : $uuid, -1, -1,
			Wx::TreeItemData->new({ type => 'waypoint', uuid => $uuid, data => $wp }));
		$this->_setSwatch($item);
	}

	return $hdr;
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
	return $text;
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
	$text .= trackEndpointsText($track);
	$text .= "\n" . trackPointsText($points, variable => 1) if @$points;
	return $text;
}


#---------------------------------
# editor (OpenCPN-tailored)  -- Save enqueues an outbound update command
#---------------------------------
# Overrides the winTreeBase _loadEditor to show only OpenCPN-relevant fields
# (name/comment/lat/lon/sym for a mark; name/comment for a route; name for a
# track) -- OpenCPN marks carry no depth/temp/date/time and no E80 palette.

sub _loadEditor
{
	my ($this, $node) = @_;
	my $type = $node->{type} // '';
	my $uuid = $node->{uuid};
	my $data = $node->{data} // {};

	my $show_name    = ($type eq 'waypoint' || $type eq 'route' || $type eq 'track');
	my $show_comment = ($type eq 'waypoint' || $type eq 'route');
	my $show_latlon  = ($type eq 'waypoint');
	my $show_sym     = ($type eq 'waypoint');

	$this->{_edit_uuid}    = $uuid;
	$this->{_edit_type}    = $type;
	$this->{_editor_dirty} = 0;

	my $title = $type eq 'waypoint' ? 'Waypoint'
	          : $type eq 'route'    ? 'Route'
	          : $type eq 'track'    ? 'Track'
	          :                       '';
	$this->{ed_title}->SetLabel($title);

	my @fields;
	push @fields, 'name'    if $show_name;
	push @fields, 'comment' if $show_comment;
	push @fields, 'lat'     if $show_latlon;
	push @fields, 'lon'     if $show_latlon;
	push @fields, 'sym'     if $show_sym;
	winTreeBase::_layoutEditor($this, \@fields);

	$this->{_loading_editor} = 1;

	$this->{ed_name}->SetValue($data->{name}       // '') if $show_name;
	$this->{ed_comment}->SetValue($data->{comment} // '') if $show_comment;

	if ($show_latlon)
	{
		my ($lat, $lon) = $this->_wpLatLon($data);
		$this->{ed_lat}->SetValue(sprintf('%.6f', $lat));
		$this->{ed_lon}->SetValue(sprintf('%.6f', $lon));
		winTreeBase::_updateLatDDM($this);
		winTreeBase::_updateLonDDM($this);
	}

	$this->{ed_sym}->SetSelection(($data->{sym} // 0) + 0) if $show_sym;

	$this->{ed_visible}->Show(1);
	$this->{ed_visible}->Set3StateValue(
		$this->_getVisible($uuid // '') ? wxCHK_CHECKED : wxCHK_UNCHECKED);

	$this->{_loading_editor} = 0;
	$this->{ed_save}->Enable(0);
}


sub _onSave
{
	my ($this, $event) = @_;
	my $uuid = $this->{_edit_uuid};
	my $type = $this->{_edit_type} // '';
	return if !$uuid;
	my $db = $this->{_db} or return;

	my $item;
	if ($type eq 'waypoint')
	{
		my $lat = parseLatLon($this->{ed_lat}->GetValue());
		my $lon = parseLatLon($this->{ed_lon}->GetValue());
		if (!defined($lat) || !defined($lon))
		{
			warning(0, 0, "winOCPN: invalid lat/lon - save aborted");
			return;
		}
		my $orig    = $db->{waypoints}{$uuid} // {};
		my $new_sym = $this->{ed_sym}->GetSelection();
		$item = { type => 'waypoint', uuid => $uuid, data => {
			%$orig,
			name    => $this->{ed_name}->GetValue(),
			comment => $this->{ed_comment}->GetValue(),
			lat     => $lat + 0,
			lon     => $lon + 0,
			sym     => $new_sym,
		} };
		# Icon policy: if the user DIDN'T change the sym, preserve the mark's
		# original raw OpenCPN IconName verbatim (icon_name shadow -> emitted as
		# is).  If they DID change the sym, let nmOCPNDirectOps derive the icon
		# from the new sym (no icon_name shadow, so iconForSym applies).
		if ($new_sym == ($orig->{sym} // 0) && ($orig->{icon} // '') ne '')
		{
			$item->{data}{icon_name} = $orig->{icon};
		}
	}
	elsif ($type eq 'route')
	{
		my $orig = $db->{routes}{$uuid} // {};
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
		$item = {
			type => 'route', uuid => $uuid,
			data => { %$orig, name => $this->{ed_name}->GetValue(), comment => $this->{ed_comment}->GetValue() },
			route_points => \@rps,
		};
	}
	elsif ($type eq 'track')
	{
		my $orig = $db->{tracks}{$uuid} // {};
		$item = { type => 'track', uuid => $uuid, data => { %$orig, name => $this->{ed_name}->GetValue() } };
	}
	else
	{
		return;
	}

	# 'add' == upsert on the plugin (sec 8): an add of an existing GUID updates
	# it.  The plugin applies + re-POSTs, and the onIdle refresh clock rebuilds
	# the pane from the echo.  Update the mark's tree label now for responsiveness.
	navOCPN::pushItems([$item], 'add');
	$this->{tree}->SetItemText($this->{_edit_item}, $this->{ed_name}->GetValue())
		if $type eq 'waypoint' && $this->{_edit_item};

	$this->{ed_save}->Enable(0);
	$this->{_editor_dirty} = 0;
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
