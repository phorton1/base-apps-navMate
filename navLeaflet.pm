#!/usr/bin/perl
#---------------------------------------------
# navLeaflet.pm
#---------------------------------------------
# Dispatches track/route-edit commands posted from the Leaflet map client.
# Called from nmFrame::onIdle on the Wx thread.
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

package navLeaflet;
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Pub::Utils qw(display warning error);
use nmResources qw($WIN_DATABASE $WIN_E80 $WIN_FSH);

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


my %STORE_WIN = ( db => $WIN_DATABASE, e80 => $WIN_E80, fsh => $WIN_FSH );

# Map waypoint dialog (POST /waypoint/save): op=create|update, store=db|e80|fsh.
# Routes to the store's pane, which runs preflight + write and RETURNS a result
# hash; we relay { seq, ok, msg } to the browser via the result slot.
sub dispatchWaypointSave
{
	my ($main_win, $edit_json) = @_;
	my $edit = eval { decode_json($edit_json) };
	if ($@) { warning(0,0,"navLeaflet: dispatchWaypointSave bad JSON: $@"); return; }

	my $op    = $edit->{op}    // '';
	my $store = $edit->{store} // 'db';
	display($dbg_nl,0,"navLeaflet::dispatchWaypointSave op=$op store=$store");

	my $pane   = $main_win->findPane($STORE_WIN{$store} // $WIN_DATABASE);
	my $result;
	if ($pane && $pane->can('onLeafletWaypointSave'))
	{
		$result = $pane->onLeafletWaypointSave($edit);
	}
	else
	{
		warning(0,0,"navLeaflet: dispatchWaypointSave - no '$store' pane");
		$result = { ok => 0, msg => "The $store window is not open" };
	}
	$result = { ok => 1 } if !$result || ref $result ne 'HASH';
	$result->{seq} = $edit->{seq} // 0;
	navServer::setWaypointResult(encode_json($result));
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
