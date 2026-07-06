#!/usr/bin/perl
#---------------------------------------------
# navOpsOCPN.pm
#---------------------------------------------
# OpenCPN-spoke operations for the navMate context menu -- the fourth spoke
# (sibling to navOpsE80 / navOpsFSH).  Continues package navOps (loaded via
# require from navOps.pm).
#
# WHAT MAKES OCPN DIFFERENT FROM E80/FSH
# --------------------------------------
# OpenCPN is a REMOTE, poll-driven spoke: navMate is the HTTP server and the
# oESeries plugin is the client.  The hub cannot push synchronously, so an
# OUTBOUND operation (a paste/push of hub objects INTO the OpenCPN spoke, or a
# delete of OpenCPN objects) does NOT mutate a local hash -- it ENQUEUES a
# sec-2A commands[] batch (navOCPN::pushItems) that the plugin fetches, applies,
# and echoes back on its next inventory POST.  The winOCPN pane then refreshes
# from that echo.  So these executors are thin: they hand canonical clip items
# to navOCPN and return; the round-trip completes asynchronously.
#
# The INBOUND direction (an OpenCPN object pasted INTO navMate.db) reuses the
# generic _pasteDB path unchanged -- navOps._snapshotOCPNNode below produces the
# same canonical clip items every spoke produces, so _pushFromOCPN just delegates
# to _pushFromE80.
#
# UUID FORM: unlike FSH (dashed-upper), the ocdb is already keyed by navMate
# no-dash lowercase uuids (navIdentity mints them), so there is NO seam
# conversion -- direct lookup, like E80.
#
# NO TRUNCATION / NO NAME-UNIQUENESS GATE: OpenCPN strings are unbounded and
# objects are upsert-by-GUID (protocol sec 9), so the OpenCPN spoke is the
# gentlest -- the collision and truncation gates simply do not apply.  The only
# surviving gates are navMate-internal structural legality (navClipboard).

package navOps;	# continued ...
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils qw(display warning error);
use Pub::WX::Dialogs;
use navOCPN;
use nmDialogs;
use n_defs;
use n_utils;


our $dbg_ocpn_ops = 0;


#----------------------------------------------------
# _ocpnDb -- the ocdb reshaped to canonical record form
#----------------------------------------------------
# One projection (navOCPN::shapedDb) feeds the winOCPN pane AND this snapshot
# path, so they never drift.

sub _ocpnDb
{
	return navOCPN::shapedDb();
}


#----------------------------------------------------
# snapshot: OpenCPN tree node -> canonical clip item
#----------------------------------------------------
# The ocdb records are already canonical (no-dash uuid, decimal lat/lon, sym,
# comment), so the snapshot is a straight package -- no conversion.  Emits the
# SAME envelope shapes every spoke does, which is why _pushFromOCPN can delegate
# to _pushFromE80 and _pasteDB is source-agnostic.

sub _ocpnWpClipData
{
	my ($d) = @_;
	$d //= {};
	return { %$d };
}


sub _snapshotOCPNNode
{
	my ($db, $node) = @_;
	my $t    = $node->{type} // '';
	my $uuid = $node->{uuid};
	my $d    = $node->{data} // {};

	if ($t eq 'route_point')
	{
		return {
			type       => 'route_point',
			uuid       => $uuid,
			route_uuid => $node->{route_uuid},
			data       => _ocpnWpClipData($d),
		};
	}

	if ($t eq 'waypoint')
	{
		return { type => 'waypoint', uuid => $uuid, data => _ocpnWpClipData($d) };
	}

	if ($t eq 'my_waypoints')
	{
		# Standalone marks only (pure route-vertices are not browsable
		# waypoints, sec 5) -- surfaced as a synthetic group, like FSH.
		my $wps = $db->{waypoints} // {};
		my @members;
		for my $u (sort keys %$wps)
		{
			next if !$wps->{$u}{is_standalone};
			push @members, { type => 'waypoint', uuid => $u, data => _ocpnWpClipData($wps->{$u}) };
		}
		return {
			type    => 'group',
			uuid    => undef,
			data    => { name => 'My Waypoints' },
			members => \@members,
		};
	}

	if ($t eq 'route')
	{
		# Resolve each member to its FULL mark record (richer than the route's
		# thin wpt list) so an inbound paste materializes complete waypoints.
		my $wps = $db->{waypoints} // {};
		my @rps;
		my $pos = 0;
		for my $wp (@{$d->{wpts} // []})
		{
			my $full = $wps->{$wp->{uuid} // ''} // $wp;
			push @rps, {
				type       => 'route_point',
				uuid       => $wp->{uuid},
				route_uuid => $uuid,
				position   => $pos++,
				data       => _ocpnWpClipData($full),
			};
		}
		return { type => 'route', uuid => $uuid, data => { %$d }, route_points => \@rps };
	}

	if ($t eq 'track')
	{
		return { type => 'track', uuid => $uuid, data => { %$d } };
	}

	warning(0, 0, "_snapshotOCPNNode: unhandled node type=$t");
	return undef;
}


#----------------------------------------------------
# OUTBOUND executors -- paste/push hub objects INTO OpenCPN
#----------------------------------------------------
# All of these funnel to navOCPN::pushItems, which projects the canonical items
# to a sec-2A commands[] batch (manifestation XOR + full-embed routes live in
# nmOCPNDirectOps) and enqueues it.  The plugin applies + echoes; winOCPN
# refreshes from the echo.  Position/anchor is meaningless for OpenCPN (no
# ordering among marks), so paste-before/after collapse to a plain add.

sub _pasteOCPN
{
	my ($cmd_id, $right_click_node, $tree, $items, $cb) = @_;
	return if !$items || !@$items;
	navOCPN::pushItems($items, 'add');
}


sub _pushToOCPN
{
	# DB (or spoke) selection -> "Push to OCPN".  Items are already canonical
	# clip items resolved by _doPush; add == upsert on the plugin side.
	my ($right_click_node, $tree, $items) = @_;
	return if !$items || !@$items;
	navOCPN::pushItems($items, 'add');
}


sub _pushFromOCPN
{
	# OpenCPN selection -> "Push to DB".  Canonical clip items make sources
	# interchangeable, so delegate to the shared spoke->DB writer (identical to
	# _pushFromFSH).
	my ($right_click_node, $tree, $items) = @_;
	navOps::_pushFromE80($right_click_node, $tree, $items);
}


#----------------------------------------------------
# delete / cut  -- remove OpenCPN objects (enqueue delete commands)
#----------------------------------------------------

sub _deleteOCPN
{
	my ($cmd_id, $right_click_node, $tree, @nodes) = @_;
	my $db = _ocpnDb();
	my @items = grep { $_ } map { _snapshotOCPNNode($db, $_) } @nodes;
	return if !@items;
	navOCPN::pushItems(\@items, 'delete');
}


# Cross-spoke cut cleanup: after a CUT-paste whose SOURCE was 'ocpn', the pasted
# object must be removed from OpenCPN.  A delete command needs only the guid,
# which pushItems projects from the (nav-form) uuid -- so a minimal item does it.

sub _cutOCPNWaypoint
{
	my ($uuid, $tree) = @_;
	return if !$uuid;
	navOCPN::pushItems([{ type => 'waypoint', uuid => $uuid, data => {} }], 'delete');
}

sub _cutOCPNGroup
{
	# OpenCPN has no groups; a "group" cut resolves to deleting its member
	# marks.  navOps passes the group's nav uuid, but OpenCPN has no group
	# object to delete -- nothing to do at the spoke (members are cut
	# individually by _cutOCPNWaypoint).  Kept for dispatch symmetry.
	my ($uuid, $tree) = @_;
	return;
}

sub _cutOCPNRoute
{
	my ($uuid, $tree) = @_;
	return if !$uuid;
	navOCPN::pushItems([{ type => 'route', uuid => $uuid, data => {} }], 'delete');
}

sub _cutOCPNTrack
{
	my ($uuid, $tree) = @_;
	return if !$uuid;
	navOCPN::pushItems([{ type => 'track', uuid => $uuid, data => {} }], 'delete');
}


#----------------------------------------------------
# New -- author a new mark / route directly in OpenCPN
#----------------------------------------------------
# navMate MINTS the object (navMate-origin 0x4e uuid -> synthesized reversible
# guid) and pushes an add command; the plugin creates it and echoes it back.
# OpenCPN has no groups, so only New Waypoint / New Route (navClipboard gates
# the menu accordingly).

sub _newOCPNWaypoint
{
	my ($node, $tree) = @_;
	my $data = nmDialogs::showNewWaypoint($tree);
	return if !defined $data;

	my $lat = parseLatLon($data->{lat});
	my $lon = parseLatLon($data->{lon});
	if (!(defined $lat && defined $lon))
	{
		okDialog($tree,
			"Could not parse Latitude or Longitude.\n"
			. "Use decimal degrees (9.3617 N) or degrees and minutes (9 21.702 N).",
			"New Waypoint");
		return;
	}

	my $nav_uuid = _newNavUUID();
	return if !$nav_uuid;

	navOCPN::pushItems([{ type => 'waypoint', uuid => $nav_uuid, data => {
		name    => $data->{name}    // '',
		comment => $data->{comment} // '',
		lat     => $lat + 0,
		lon     => $lon + 0,
		sym     => $data->{sym} // 0,
	} }], 'add');
}


sub _newOCPNRoute
{
	my ($node, $tree) = @_;
	my $data = nmDialogs::showNewRoute($tree);
	return if !defined $data;

	my $nav_uuid = _newNavUUID();
	return if !$nav_uuid;

	# A new OpenCPN route starts empty; the user adds points by pasting
	# waypoints into it (or the route is built up on the OpenCPN side).
	navOCPN::pushItems([{
		type         => 'route',
		uuid         => $nav_uuid,
		data         => { name => $data->{name} // '', comment => $data->{comment} // '' },
		route_points => [],
	}], 'add');
}


1;
