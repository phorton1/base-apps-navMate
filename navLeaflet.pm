#!/usr/bin/perl
#---------------------------------------------
# navLeaflet.pm
#---------------------------------------------
# Owns the Leaflet map-edit feature: it dispatches the edit commands posted by
# the map client AND performs the store write + map render for them.  Called
# from nmFrame::onIdle on the Wx thread.
#
# WAYPOINT edits (POST /waypoint/save: create|update|delete, store=db|e80|fsh)
# are done HERE, pane-free.  A waypoint stays clickable on the map after its
# source window is closed, so Edit / Move / Delete must work with no window
# open; only the tree refresh is conditional on the pane being open.  The
# per-store create/modify/delete orchestration lived in navOpsE80/navOpsFSH
# (and inline in winDatabase) and was moved here -- the navOps clipboard layer
# carries no Leaflet code.  It still owns the shared spoke PRIMITIVES (name
# conflict, record build, route-ref, uuid mint); we call into them in place.
#
# Track ops (via POST /track/edit):
#   update  - replace all points of an existing track
#   split   - split a track at a vertex index; second segment gets new_name
#   join    - merge two db tracks at chosen vertices; second track is deleted
#
# Route ops (via POST /route/edit, db-only):
#   full_update - rewrite all route_waypoints; create new WPs for uuid=null entries
#   split       - split route at vertex index; second route gets new_name
#   create      - create new route with all-new waypoints
#
# Track/route edits still route through the pane (findPane); decoupling those
# the way waypoints are decoupled is a separate, deferred pass.

package navLeaflet;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP qw(decode_json encode_json);
use Pub::Utils qw(display warning error);
use n_defs;
use n_utils qw(@E80_ROUTE_COLOR_ABGR);
use nmResources qw($WIN_DATABASE $WIN_E80 $WIN_FSH);
use navServer qw(addRenderFeatures removeRenderFeatures);
use navVisibility;
use navDB;
use navFSH;
use navOps;

my $dbg_nl = 1;

BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(dispatchTrackEdit dispatchRouteEdit dispatchWaypointSave publishMapDest);
}


sub dispatchTrackEdit
{
	my ($main_win, $edit_json) = @_;
	my $edit = eval { decode_json($edit_json) };
	if ($@) { warning(0,0,"navLeaflet: bad JSON: $@"); return; }

	my $op     = $edit->{op}     // '';
	my $source = $edit->{source} // '';
	display($dbg_nl,0,"navLeaflet::dispatchTrackEdit op=$op source=$source");

	if ($source eq 'db')
	{
		my $database = $main_win->findPane($WIN_DATABASE);
		if ($database)
		{
			$database->onLeafletTrackEdit($edit);
		}
		else
		{
			warning(0,0,"navLeaflet: dispatchTrackEdit - no DATABASE pane");
		}
	}
	elsif ($source eq 'fsh')
	{
		my $fsh = $main_win->findPane($WIN_FSH);
		if ($fsh)
		{
			$fsh->onLeafletTrackEdit($edit);
		}
		else
		{
			warning(0,0,"navLeaflet: dispatchTrackEdit - no FSH pane");
		}
	}
	else
	{
		warning(0,0,"navLeaflet: unknown source '$source'");
	}
}


sub dispatchRouteEdit
{
	my ($main_win, $edit_json) = @_;
	my $edit = eval { decode_json($edit_json) };
	if ($@) { warning(0,0,"navLeaflet: bad JSON: $@"); return; }

	my $op  = $edit->{op}  // '';
	display($dbg_nl,0,"navLeaflet::dispatchRouteEdit op=$op");

	my $database = $main_win->findPane($WIN_DATABASE);
	if ($database)
	{
		$database->onLeafletRouteEdit($edit);
	}
	else
	{
		warning(0,0,"navLeaflet: dispatchRouteEdit - no DATABASE pane");
	}
}


# Map waypoint dialog (POST /waypoint/save): op=create|update|delete, store=db|e80|fsh.
# The store write + map render run pane-free; the source window, when open, is
# only refreshed afterwards so its tree mirrors the change.  We relay
# { seq, ok, msg } to the browser via the result slot.
sub dispatchWaypointSave
{
	my ($main_win, $edit_json) = @_;
	my $edit = eval { decode_json($edit_json) };
	if ($@) { warning(0,0,"navLeaflet: dispatchWaypointSave bad JSON: $@"); return; }

	my $op    = $edit->{op}    // '';
	my $store = $edit->{store} // 'db';
	display($dbg_nl,0,"navLeaflet::dispatchWaypointSave op=$op store=$store");

	my $result =
		  $store eq 'e80' ? _e80WaypointSave($edit)
		: $store eq 'fsh' ? _fshWaypointSave($edit)
		: $store eq 'db'  ? _dbWaypointSave($edit)
		:                   { ok => 0, msg => "unknown store '$store'" };
	$result = { ok => 1 } if !$result || ref $result ne 'HASH';

	# Mirror the edit in the source window's tree, if it happens to be open.
	# Harmless (and skipped) when the window is closed -- the map render above
	# already stands on its own.
	_refreshStorePanes($main_win, $store) if $result->{ok};

	my %resp = ( seq => ($edit->{seq} // 0), ok => ($result->{ok} ? 1 : 0) );
	$resp{msg} = $result->{msg} if defined $result->{msg};
	navServer::setWaypointResult(encode_json(\%resp));
}


sub _refreshStorePanes
{
	my ($main_win, $store) = @_;
	if ($store eq 'db')
	{
		$_->refresh() for $main_win->_findDatabasePanes();
	}
	elsif ($store eq 'e80')
	{
		my $p = $main_win->findPane($WIN_E80);
		$p->refresh() if $p;
	}
	elsif ($store eq 'fsh')
	{
		my $p = $main_win->findPane($WIN_FSH);
		$p->refresh() if $p;
	}
}


#---------------------------------
# E80 waypoint save (write + map render)
#---------------------------------

sub _e80WaypointSave
{
	my ($edit) = @_;
	my $op = $edit->{op} // '';
	if ($op eq 'create')
	{
		return _mapCreateE80Waypoint(
			name       => $edit->{name},
			lat        => $edit->{lat},
			lon        => $edit->{lon},
			sym        => $edit->{sym},
			group_uuid => $edit->{group_uuid});
	}
	elsif ($op eq 'update')
	{
		my $res = _mapModifyE80Waypoint(
			uuid => $edit->{uuid},
			name => $edit->{name},
			sym  => $edit->{sym},
			lat  => $edit->{lat},
			lon  => $edit->{lon});
		if ($res->{ok} && $res->{wp} && getE80Visible($res->{uuid}))
		{
			removeRenderFeatures('e80', [$res->{uuid}]);
			addRenderFeatures([_buildSpokeWpFeature('e80', $res->{uuid}, $res->{wp})], 1);   # quiet
		}
		_repushSpokeRoutes('e80', $res->{routes}) if $res->{ok};   # Move: routes follow
		return $res;
	}
	elsif ($op eq 'delete')
	{
		my $res = _mapDeleteE80Waypoint(uuid => $edit->{uuid});
		removeRenderFeatures('e80', [$res->{uuid}]) if $res->{ok};
		return $res;
	}
	return { ok => 0, msg => "unknown op '$op'" };
}


#---------------------------------
# FSH waypoint save (write + map render)
#---------------------------------

sub _fshWaypointSave
{
	my ($edit) = @_;
	my $op = $edit->{op} // '';
	if ($op eq 'create')
	{
		return _mapCreateFSHWaypoint(
			name       => $edit->{name},
			lat        => $edit->{lat},
			lon        => $edit->{lon},
			sym        => $edit->{sym},
			group_uuid => $edit->{group_uuid});
	}
	elsif ($op eq 'update')
	{
		my $res = _mapModifyFSHWaypoint(
			uuid => $edit->{uuid},
			name => $edit->{name},
			sym  => $edit->{sym},
			lat  => $edit->{lat},
			lon  => $edit->{lon});
		if ($res->{ok} && $res->{wp} && getFSHVisible($res->{uuid}))
		{
			removeRenderFeatures('fsh', [$res->{uuid}]);
			addRenderFeatures([_buildSpokeWpFeature('fsh', $res->{uuid}, $res->{wp})], 1);   # quiet
		}
		_repushSpokeRoutes('fsh', $res->{routes}) if $res->{ok};   # Move: routes follow
		return $res;
	}
	elsif ($op eq 'delete')
	{
		my $res = _mapDeleteFSHWaypoint(uuid => $edit->{uuid});
		removeRenderFeatures('fsh', [$res->{uuid}]) if $res->{ok};
		return $res;
	}
	return { ok => 0, msg => "unknown op '$op'" };
}


#---------------------------------
# DB waypoint save (write + map render).  create makes a new waypoint at the
# clicked lat/lon in the resolved collection (paste-after the anchor leaf if
# one was selected); update rewrites name/wp_type/sym/color (+ position on a
# Move) on an existing db waypoint; delete removes it (rejected if a route
# uses it).  Render + the %rendered_uuids ledger ride winDatabase's own
# pane-free push/pull helpers.
#---------------------------------

sub _dbWaypointSave
{
	my ($edit) = @_;
	my $op  = $edit->{op} // '';
	my $dbh = navDB::connectDB();
	return { ok => 0, msg => 'Database not available' } if !$dbh;

	my $result = { ok => 1 };
	if ($op eq 'create')
	{
		my $coll_uuid = $edit->{collection_uuid} // '';
		if (!$coll_uuid)
		{
			navDB::disconnectDB($dbh);
			return { ok => 0, msg => 'No destination collection selected' };
		}

		# paste-after position within the (mixed-type) collection if a leaf was
		# the selected anchor; otherwise append (insertWaypoint's fallback).
		my $position;
		my $anchor_uuid = $edit->{anchor_uuid} // '';
		my %atable = (waypoint => 'waypoints', route => 'routes', track => 'tracks');
		my $atable  = $atable{$edit->{anchor_type} // ''};
		if ($anchor_uuid && $atable)
		{
			my $anchor_pos = navDB::getPositionByAnchor($dbh, $anchor_uuid, $atable);
			if (defined $anchor_pos)
			{
				my $next_pos = winDatabase::_nextCollItemPos($dbh, $coll_uuid, $anchor_pos);
				$position = defined($next_pos) ? ($anchor_pos + $next_pos) / 2 : $anchor_pos + 1;
			}
		}

		my $uuid = navDB::insertWaypoint($dbh,
			name            => $edit->{name} // '',
			lat             => ($edit->{lat} // 0) + 0,
			lon             => ($edit->{lon} // 0) + 0,
			wp_type         => (defined $edit->{wp_type} ? $edit->{wp_type} + 0 : $WP_TYPE_NAV),
			(defined $edit->{sym} ? (sym => $edit->{sym} + 0) : ()),
			color           => $edit->{color},        # undef -> _normalizeColor -> white
			depth_cm        => 0,
			created_ts      => time(),
			ts_source       => 'nav',
			source          => 'navMate',
			collection_uuid => $coll_uuid,
			(defined $position ? (position => $position) : ()));

		navVisibility::setDbVisible($uuid, 1);    # new waypoint starts visible (checkbox on)
		winDatabase::_pushObjToLeaflet($dbh, undef, { uuid => $uuid, obj_type => 'waypoint' }, undef, 1);
	}
	elsif ($op eq 'update')
	{
		my $uuid = $edit->{uuid} // '';
		my $wp   = $uuid ? navDB::getWaypoint($dbh, $uuid) : undef;
		if (!$wp)
		{
			navDB::disconnectDB($dbh);
			return { ok => 0, msg => "Waypoint not found ($uuid)" };
		}
		navDB::updateWaypoint($dbh, $uuid,
			name       => (defined $edit->{name}    ? $edit->{name}        : $wp->{name}),
			comment    => $wp->{comment},
			lat        => (defined $edit->{lat}     ? $edit->{lat} + 0     : $wp->{lat}),
			lon        => (defined $edit->{lon}     ? $edit->{lon} + 0     : $wp->{lon}),
			wp_type    => (defined $edit->{wp_type} ? $edit->{wp_type} + 0 : $wp->{wp_type}),
			sym        => (defined $edit->{sym}     ? $edit->{sym} + 0     : $wp->{sym}),
			color      => (defined $edit->{color}   ? $edit->{color}       : $wp->{color}),
			depth_cm   => $wp->{depth_cm},
			temp_k     => $wp->{temp_k},
			created_ts => $wp->{created_ts},
			ts_source  => $wp->{ts_source},
			source     => $wp->{source});

		winDatabase::_pushObjToLeaflet($dbh, undef, { uuid => $uuid, obj_type => 'waypoint' }, undef, 1);
		# Map "Move Waypoint" changes geometry, so any rendered route that
		# references this waypoint must be re-pushed to follow it (DB routes are
		# reference-built; a name/sym/color edit never needed this).
		if (defined $edit->{lat} || defined $edit->{lon})
		{
			for my $r (@{navDB::getWaypointRoutes($dbh, $uuid)})
			{
				next if !$winDatabase::rendered_uuids{$r->{route_uuid}};
				winDatabase::_pushObjToLeaflet($dbh, undef, { uuid => $r->{route_uuid}, obj_type => 'route' }, undef, 1);
			}
		}
	}
	elsif ($op eq 'delete')
	{
		my $uuid = $edit->{uuid} // '';
		my $wp   = $uuid ? navDB::getWaypoint($dbh, $uuid) : undef;
		if (!$wp)
		{
			navDB::disconnectDB($dbh);
			return { ok => 0, msg => "Waypoint not found ($uuid)" };
		}
		if (navDB::getWaypointRouteRefCount($dbh, $uuid) > 0)
		{
			navDB::disconnectDB($dbh);
			return { ok => 0, msg => "'" . ($wp->{name} // 'Waypoint')
				. "' is used by a route -- remove it from the route first" };
		}
		navDB::deleteWaypoint($dbh, $uuid);
		navVisibility::setDbVisible($uuid, 0);
		winDatabase::_pullFromLeaflet(undef, $uuid);
	}
	else
	{
		$result = { ok => 0, msg => "unknown op '$op'" };
	}
	navDB::disconnectDB($dbh);
	return $result;
}


#---------------------------------
# Spoke (E80 / FSH) map render -- pane-free mirror of the winTreeBase feature
# builders, so an edit renders whether or not the source window is open.  (DB
# uses winDatabase's own pane-free _pushObjToLeaflet / _pullFromLeaflet.)
#---------------------------------

sub _buildSpokeWpFeature
{
	my ($store, $uuid, $wp) = @_;
	my ($lat, $lon) = ($store eq 'e80')
		? ((($wp->{lat}//0)+0)/1e7, (($wp->{lon}//0)+0)/1e7)
		: (($wp->{lat}//0)+0,        ($wp->{lon}//0)+0);
	my $color = ($store eq 'e80') ? ($wp->{color} // 'FF888888') : 'FF888888';
	return {
		type       => 'Feature',
		properties => {
			uuid        => $uuid,
			name        => $wp->{name}    // '',
			obj_type    => 'waypoint',
			data_source => $store,
			wp_type     => $wp->{wp_type} // $WP_TYPE_NAV,
			sym         => $wp->{sym}     // 0,
			color       => $color,
			lat         => $lat,
			lon         => $lon,
		},
		geometry   => { type => 'Point', coordinates => [$lon, $lat] },
	};
}


sub _spokeRouteWpts
{
	my ($store, $r) = @_;
	if ($store eq 'fsh')
	{
		return map { { lat => ($_->{lat}//0)+0, lon => ($_->{lon}//0)+0, name => $_->{name} // '' } }
		       @{$r->{wpts} // []};
	}
	# e80: the route carries a uuid list resolved against the live wpmgr waypoints
	my $wpmgr = navOps::_wpmgr();
	my $wps   = $wpmgr ? ($wpmgr->{waypoints} // {}) : {};
	my @pts;
	for my $uuid (@{$r->{uuids} // []})
	{
		my $wp = $wps->{$uuid};
		push @pts, {
			lat  => (($wp->{lat}//0)+0)/1e7,
			lon  => (($wp->{lon}//0)+0)/1e7,
			name => $wp->{name} // '',
		} if $wp && defined($wp->{lat}) && defined($wp->{lon});
	}
	return @pts;
}


sub _buildSpokeRouteFeature
{
	my ($store, $uuid, $r) = @_;
	my @wpts = _spokeRouteWpts($store, $r);
	return undef if !@wpts;
	my $cidx  = defined($r->{color}) ? ($r->{color} + 0) : 0;
	my $color = $E80_ROUTE_COLOR_ABGR[$cidx] // 'FF888888';
	return {
		type       => 'Feature',
		properties => {
			uuid        => $uuid,
			name        => $r->{name}  // '',
			obj_type    => 'route',
			data_source => $store,
			color       => $color,
			wp_count    => scalar(@wpts) + 0,
			rp_names    => [map { $_->{name} } @wpts],
		},
		geometry   => { type => 'LineString',
			coordinates => [map { [$_->{lon}, $_->{lat}] } @wpts] },
	};
}


sub _repushSpokeRoutes
{
	# A Map "Move Waypoint" changes geometry; any visible route referencing the
	# moved waypoint is re-pushed so its polyline follows.  $route_uuids comes
	# from _mapModify*Waypoint.  addRenderFeatures upserts by source:uuid.
	my ($store, $route_uuids) = @_;
	return if !$route_uuids || !@$route_uuids;
	my $all_routes = _spokeRoutes($store);
	my @features;
	for my $r_uuid (@$route_uuids)
	{
		next if !_spokeVisible($store, $r_uuid);
		my $r = $all_routes->{$r_uuid} or next;
		my $f = _buildSpokeRouteFeature($store, $r_uuid, $r);
		push @features, $f if $f;
	}
	addRenderFeatures(\@features) if @features;
}


sub _spokeRoutes
{
	my ($store) = @_;
	if ($store eq 'fsh')
	{
		my $db = $navFSH::fsh_db;
		return $db ? ($db->{routes} // {}) : {};
	}
	my $wpmgr = navOps::_wpmgr();
	return $wpmgr ? ($wpmgr->{routes} // {}) : {};
}


sub _spokeVisible
{
	my ($store, $uuid) = @_;
	return ($store eq 'fsh') ? getFSHVisible($uuid) : getE80Visible($uuid);
}


#---------------------------------
# E80 store ops.  Moved out of navOpsE80 (Leaflet feature code does not belong
# in the navOps clipboard layer); they call navOps' shared E80 spoke primitives
# in place -- "calling into the beast is fine; growing a wart on it is not".
#---------------------------------

sub _mapCreateE80Waypoint
{
	my (%a) = @_;
	my $wpmgr = navOps::_wpmgr();
	return { ok => 0, msg => 'Connect an ESeries plotter first' } if !$wpmgr;

	my $name = $a{name} // '';
	return { ok => 0, msg => 'Waypoint needs a name' } if $name eq '';
	if (my $c = navOps::_checkE80NameConflict($wpmgr, $name, {}, 'waypoints'))
	{
		return { ok => 0, msg => "A waypoint named '$name' already exists on the ESeries plotter" };
	}

	my $uuid = navOps::_newNavUUID();
	return { ok => 0, msg => 'Could not allocate a uuid' } if !$uuid;

	$wpmgr->createWaypoint({
		name    => $name,
		uuid    => $uuid,
		lat     => ($a{lat} // 0) + 0,
		lon     => ($a{lon} // 0) + 0,
		sym     => (defined $a{sym} ? $a{sym} + 0 : (navDB::symForWpType($WP_TYPE_NAV) // 0)),
		ts      => time(),
		comment => '',
	});
	my $group_uuid = $a{group_uuid} // '';
	if ($group_uuid && $wpmgr->{groups}{$group_uuid})
	{
		my $group = $wpmgr->{groups}{$group_uuid};
		my @new   = (@{$group->{uuids} // []}, $uuid);
		$wpmgr->modifyGroup({ uuid => $group_uuid, members => \@new });
	}
	navVisibility::setE80Visible($uuid, 1);   # new waypoint starts visible
	return { ok => 1, uuid => $uuid };
}


sub _mapModifyE80Waypoint
{
	my (%a) = @_;
	my $wpmgr = navOps::_wpmgr();
	return { ok => 0, msg => 'Connect an ESeries plotter first' } if !$wpmgr;

	my $uuid = $a{uuid} // '';
	my $wp   = $uuid ? $wpmgr->{waypoints}{$uuid} : undef;
	return { ok => 0, msg => 'That waypoint is no longer on the ESeries plotter' } if !$wp;

	my $name = $a{name} // '';
	return { ok => 0, msg => 'Waypoint needs a name' } if $name eq '';
	if (lc($name) ne lc($wp->{name} // ''))   # a rename must stay unique
	{
		if (my $c = navOps::_checkE80NameConflict($wpmgr, $name, {}, 'waypoints'))
		{
			return { ok => 0, msg => "A waypoint named '$name' already exists on the ESeries plotter" };
		}
	}

	# lat/lon together = a Move (decimal degrees; modifyWaypoint scales + redoes
	# north/east).  Map "Move Waypoint" always sends both, never one alone.
	$wpmgr->modifyWaypoint({
		uuid => $uuid,
		name => $name,
		(defined $a{sym} ? (sym => $a{sym} + 0) : ()),
		((defined $a{lat} && defined $a{lon}) ? (lat => $a{lat} + 0, lon => $a{lon} + 0) : ()),
	});
	# Only a move (lat/lon) shifts route geometry; a name/sym edit leaves the
	# referencing routes unchanged, so don't bother re-pushing them.
	my @routes = (defined $a{lat} && defined $a{lon}) ? navOps::_e80WPRoutes($wpmgr, $uuid) : ();
	return { ok => 1, uuid => $uuid, wp => $wpmgr->{waypoints}{$uuid}, routes => \@routes };
}


sub _mapDeleteE80Waypoint
{
	my (%a) = @_;
	my $wpmgr = navOps::_wpmgr();
	return { ok => 0, msg => 'Connect an ESeries plotter first' } if !$wpmgr;

	my $uuid = $a{uuid} // '';
	my $wp   = $uuid ? $wpmgr->{waypoints}{$uuid} : undef;
	return { ok => 0, msg => 'That waypoint is no longer on the ESeries plotter' } if !$wp;

	my @routes = navOps::_e80WPRoutes($wpmgr, $uuid);
	if (@routes)
	{
		return { ok => 0, msg => "'" . ($wp->{name} // 'Waypoint')
			. "' is used by a route -- remove it from the route first" };
	}

	navOps::_e80DeleteWP($wpmgr, $uuid);
	navVisibility::setE80Visible($uuid, 0);
	return { ok => 1, uuid => $uuid };
}


#---------------------------------
# FSH store ops.  Moved out of navOpsFSH; call navOps' shared FSH spoke
# primitives in place.  A move propagates into each referencing route's
# embedded waypoint copy (FSH routes are denormalized, not uuid references).
#---------------------------------

sub _mapCreateFSHWaypoint
{
	my (%a) = @_;
	my $db = navOps::_fshDb();
	return { ok => 0, msg => 'No FSH file is loaded' } if !$db;

	my $name = $a{name} // '';
	return { ok => 0, msg => 'Waypoint needs a name' } if $name eq '';
	my %pending_names;
	if (my $c = navOps::_checkFSHNameConflict($db, $name, \%pending_names, 'waypoints'))
	{
		return { ok => 0, msg => "FSH already has a waypoint named '$name'" };
	}

	my $uuid = navOps::_newNavUUID();
	return { ok => 0, msg => 'Could not allocate a uuid' } if !$uuid;

	my $rec = navOps::_buildFSHWpRecord({
		uuid    => $uuid,
		name    => $name,
		comment => '',
		lat     => ($a{lat} // 0) + 0,
		lon     => ($a{lon} // 0) + 0,
		sym     => (defined $a{sym} ? $a{sym} + 0 : (navDB::symForWpType($WP_TYPE_NAV) // 0)),
		date    => 0,
		time    => 0,
	});

	my $group_uuid = $a{group_uuid} // '';
	if ($group_uuid && $db->{groups}{$group_uuid})
	{
		my $grp = $db->{groups}{$group_uuid};
		my @new = (@{$grp->{wpts} // []}, $rec);
		$grp->{wpts} = shared_clone(\@new);
	}
	else
	{
		$db->{waypoints}{$rec->{uuid}} = $rec;
	}
	navVisibility::setFSHVisible($uuid, 1);   # new waypoint starts visible
	navFSH::markDirty();
	return { ok => 1, uuid => $uuid };
}


sub _mapModifyFSHWaypoint
{
	my (%a) = @_;
	my $db = navOps::_fshDb();
	return { ok => 0, msg => 'No FSH file is loaded' } if !$db;

	my $uuid = $a{uuid} // '';
	my $wp   = $uuid ? $db->{waypoints}{$uuid} : undef;
	if (!$wp && $uuid)
	{
		GROUP: for my $g (values %{$db->{groups} // {}})
		{
			for my $w (@{$g->{wpts} // []})
			{
				if (($w->{uuid} // '') eq $uuid) { $wp = $w; last GROUP; }
			}
		}
	}
	return { ok => 0, msg => 'That waypoint is no longer in the FSH file' } if !$wp;

	my $name = $a{name} // '';
	return { ok => 0, msg => 'Waypoint needs a name' } if $name eq '';
	if (lc($name) ne lc($wp->{name} // ''))   # a rename must stay unique
	{
		if (my $c = navOps::_checkFSHNameConflict($db, $name, {}, 'waypoints'))
		{
			return { ok => 0, msg => "FSH already has a waypoint named '$name'" };
		}
	}

	$wp->{name} = $name;
	$wp->{sym}  = (defined $a{sym} ? $a{sym} + 0 : ($wp->{sym} // 0));

	# Map "Move Waypoint": set lat/lon (+ north/east), then propagate the new
	# position into every route's embedded copy of this waypoint -- FSH routes
	# carry denormalized waypoint records, not uuid references, so they would not
	# follow on their own.
	my @routes;
	if (defined $a{lat} && defined $a{lon})
	{
		navOps::_fshSetWpLatLon($wp, $a{lat}, $a{lon});
		@routes = navOps::_fshWPRoutes($db, $uuid);
		for my $r_uuid (@routes)
		{
			for my $rwp (@{$db->{routes}{$r_uuid}{wpts} // []})
			{
				navOps::_fshSetWpLatLon($rwp, $a{lat}, $a{lon})
					if ($rwp->{uuid} // '') eq $uuid;
			}
		}
	}
	return { ok => 1, uuid => $uuid, wp => $wp, routes => \@routes };
}


sub _mapDeleteFSHWaypoint
{
	my (%a) = @_;
	my $db = navOps::_fshDb();
	return { ok => 0, msg => 'No FSH file is loaded' } if !$db;

	my $uuid = $a{uuid} // '';
	return { ok => 0, msg => 'Waypoint not found' } if !$uuid;

	my @routes = navOps::_fshWPRoutes($db, $uuid);
	if (@routes)
	{
		return { ok => 0, msg => "That waypoint is used by a route -- remove it from the route first" };
	}

	delete $db->{waypoints}{$uuid};
	for my $grp (values %{$db->{groups} // {}})
	{
		my @new_wpts = grep { ($_->{uuid} // '') ne $uuid } @{$grp->{wpts} // []};
		$grp->{wpts} = shared_clone(\@new_wpts);
	}
	navVisibility::setFSHVisible($uuid, 0);
	return { ok => 1, uuid => $uuid };
}


# Publish the current map-create destination for /api/dest.  Resolves against the
# ACTIVE pane (db/e80/fsh) via the winTreeBase virtual resolveMapDestination.
# Runs every onIdle on the wx thread (it owns the tree); the HTTP thread can
# only read the published JSON, never the live wx selection.
sub publishMapDest
{
	my ($main_win) = @_;
	my $pane = $main_win->getCurrentPane();
	my $dest = ($pane && $pane->can('resolveMapDestination'))
		? $pane->resolveMapDestination()
		: { ok => 0, count => 0, reason => 'no_pane' };
	navServer::setMapDestSelection(encode_json($dest));
}


1;
