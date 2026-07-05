#---------------------------------------------
# nmOCPNDirectOps.pm
#---------------------------------------------
# The direct-ops layer of the OpenCPN (oESeries) spoke -- the projection /
# ingest / reconcile logic between the sec-2A wire and navOCPN's in-memory ocdb,
# mirroring nmE80DirectOps for the E80 spoke.  PURE transforms over plain Perl
# hashes: navOCPN owns the shared state, the locking, and the serialization;
# this module owns "wire <-> ocdb <-> DB" field mapping and GUID reconciliation.
#
# So the SAME code the production /api/ocpn endpoint runs is what the
# _testOEServer.pm harness exercises -- passing the harness proves the real
# serialization, not a mock.
#
# The ocdb (a plain decoded hash; navOCPN serializes it into a shared scalar):
#   {
#     marks  => { <uuid> => { guid,name,lat,lon,description,icon,created_ts,origin } },
#     routes => { <uuid> => { ... } },     # M2
#     tracks => { <uuid> => { ... } },     # M2
#     map    => { fwd=>{<guid>=><uuid>}, rev=>{<uuid>=><guid>}, counter=>N },
#   }
#
# Milestone status: M1 = marks inbound + DB-mark projection.  routes/tracks
# (M2) and the commands[] outbound path (M3) extend this module in place.

package nmOCPNDirectOps;
use strict;
use warnings;
use navIdentity qw(ocpnGuidToNavUuid reconcileGuidToUuid projectUuidToGuid);

our $dbg = 0;


#-----------------------------------------------------------------------
# blankOcdb -- a fresh, empty ocdb
#-----------------------------------------------------------------------

sub blankOcdb
{
	return {
		marks  => {},
		routes => {},
		tracks => {},
		map    => { fwd => {}, rev => {}, counter => 0 },
	};
}


#-----------------------------------------------------------------------
# ingestInventory($ocdb, $body) -- a POSTed sec-2A inventory -> the ocdb
#-----------------------------------------------------------------------
# Idempotent by construction: reconcileGuidToUuid reuses an existing foreign
# mapping (never mints twice) and marks are keyed by uuid, so re-POSTing the
# same inventory updates in place -- no duplicate records, no duplicate map
# rows.  Returns a machine-readable ingest summary the harness asserts on.
#
# NOTE: this only ever writes the in-memory ocdb (a spoke projection); it NEVER
# writes canonical navMate.db -- that is a user PASTE (Phase 2 / navOps).  This
# is the structural guarantee behind the echo-round-trip invariant (sec 2A).

sub ingestInventory
{
	my ($ocdb, $body) = @_;
	$body ||= {};

	my $marks  = (ref($body->{marks})  eq 'ARRAY') ? $body->{marks}  : [];
	my $routes = (ref($body->{routes}) eq 'ARRAY') ? $body->{routes} : [];
	my $tracks = (ref($body->{tracks}) eq 'ARRAY') ? $body->{tracks} : [];
	my $counter_before = $ocdb->{map}{counter} // 0;

	# FULL-STATE REPLACE (protocol sec 12): the plugin POSTs its COMPLETE current
	# inventory each time, so the ocdb must MIRROR exactly that -- an object absent
	# from the POST was deleted in OpenCPN and must drop here too (a plain upsert
	# would leak deleted objects forever).  We rebuild the object stores from this
	# POST while KEEPING the persistent guid reconcile map, so a re-appearing guid
	# reuses its uuid and foreign mints are never lost.  Idempotent: re-POSTing the
	# same inventory yields the identical ocdb.
	my %prior_marks  = map { $_ => 1 } keys %{$ocdb->{marks}  || {}};
	my %prior_routes = map { $_ => 1 } keys %{$ocdb->{routes} || {}};
	my %prior_tracks = map { $_ => 1 } keys %{$ocdb->{tracks} || {}};
	$ocdb->{marks}  = {};
	$ocdb->{routes} = {};
	$ocdb->{tracks} = {};

	# ORDER MATTERS: marks first, so a route's bare-ref point (sec 2A: a member
	# that is a standalone mark rides in marks[]) resolves to the same uuid.
	my $n_foreign = 0;
	for my $m (@$marks)
	{
		next if !defined $m->{guid} || $m->{guid} eq '';
		my $uuid = reconcileGuidToUuid($m->{guid}, $ocdb->{map});
		next if !defined $uuid;
		my $foreign = defined(ocpnGuidToNavUuid($m->{guid})) ? 0 : 1;
		$n_foreign++ if $foreign;
		$ocdb->{marks}{$uuid} = _wireMarkToOcdb($m, $uuid, $foreign);
	}

	my $rsum = _ingestRoutes($ocdb, $routes);
	my $tsum = _ingestTracks($ocdb, $tracks);

	my $marks_new      = scalar(grep { !$prior_marks{$_}  }  keys %{$ocdb->{marks}});
	my $marks_removed  = scalar(grep { !exists $ocdb->{marks}{$_}  } keys %prior_marks);
	my $routes_new     = scalar(grep { !$prior_routes{$_} }  keys %{$ocdb->{routes}});
	my $routes_removed = scalar(grep { !exists $ocdb->{routes}{$_} } keys %prior_routes);
	my $tracks_new     = scalar(grep { !$prior_tracks{$_} }  keys %{$ocdb->{tracks}});
	my $tracks_removed = scalar(grep { !exists $ocdb->{tracks}{$_} } keys %prior_tracks);

	return {
		marks_in         => scalar(@$marks),
		marks_total      => scalar(keys %{$ocdb->{marks}}),
		marks_new        => $marks_new,
		marks_removed    => $marks_removed,
		marks_foreign_in => $n_foreign,
		routes_in        => scalar(@$routes),
		routes_total     => scalar(keys %{$ocdb->{routes}}),
		routes_new       => $routes_new,
		routes_removed   => $routes_removed,
		vertices_materialized => $rsum->{vertices_materialized},
		tracks_in         => scalar(@$tracks),
		tracks_total      => scalar(keys %{$ocdb->{tracks}}),
		tracks_new        => $tracks_new,
		tracks_removed    => $tracks_removed,
		guids_minted      => ($ocdb->{map}{counter} // 0) - $counter_before,
	};
}


#-----------------------------------------------------------------------
# _ingestRoutes -- sec-2A routes -> ocdb (mark-vs-vertex split, sec 5/8)
#-----------------------------------------------------------------------
# Every point carries guid+position.  A PURE VERTEX (GetFSStatus()==false)
# additionally embeds a full "mark" -- navMate has no anonymous vertices, so it
# is MATERIALIZED as a waypoint record (added to ocdb marks if not already
# present).  A BARE REF (standalone mark, its full object in marks[]) resolves
# to the same uuid the mark ingested to -- shared-point-to-one-uuid, no dup.
# The ocdb route holds an ordered ref list mirroring route_waypoints.

sub _ingestRoutes
{
	my ($ocdb, $routes) = @_;
	my ($n_new, $n_vertices) = (0, 0);
	for my $r (@$routes)
	{
		next if !defined $r->{guid} || $r->{guid} eq '';
		my $ruuid = reconcileGuidToUuid($r->{guid}, $ocdb->{map});
		next if !defined $ruuid;

		my @pts;
		my $plist = (ref($r->{points}) eq 'ARRAY') ? $r->{points} : [];
		for my $p (@$plist)
		{
			next if !defined $p->{guid} || $p->{guid} eq '';
			my $wpuuid = reconcileGuidToUuid($p->{guid}, $ocdb->{map});
			next if !defined $wpuuid;
			if (ref($p->{mark}) eq 'HASH')   # pure vertex -> materialize once
			{
				my $foreign = defined(ocpnGuidToNavUuid($p->{guid})) ? 0 : 1;
				$ocdb->{marks}{$wpuuid} = _wireMarkToOcdb($p->{mark}, $wpuuid, $foreign)
					if !exists $ocdb->{marks}{$wpuuid};
				$n_vertices++;
			}
			push @pts, { wp_uuid => $wpuuid, position => int($p->{position} // 0), guid => $p->{guid} };
		}
		@pts = sort { $a->{position} <=> $b->{position} } @pts;

		$n_new++ if !exists $ocdb->{routes}{$ruuid};
		my $foreign_r = defined(ocpnGuidToNavUuid($r->{guid})) ? 0 : 1;
		$ocdb->{routes}{$ruuid} = {
			guid        => $r->{guid},
			uuid        => $ruuid,
			name        => defined($r->{name})        ? $r->{name}        : '',
			description => defined($r->{description}) ? $r->{description} : '',
			origin      => $foreign_r ? 'ocpn' : 'navmate',
			points      => \@pts,
		};
	}
	return { routes_new => $n_new, vertices_materialized => $n_vertices };
}


#-----------------------------------------------------------------------
# _ingestTracks -- sec-2A tracks -> ocdb (flat, sec 11)
#-----------------------------------------------------------------------

sub _ingestTracks
{
	my ($ocdb, $tracks) = @_;
	my $n_new = 0;
	for my $t (@$tracks)
	{
		next if !defined $t->{guid} || $t->{guid} eq '';
		my $tuuid = reconcileGuidToUuid($t->{guid}, $ocdb->{map});
		next if !defined $tuuid;

		my @pts;
		my $plist = (ref($t->{points}) eq 'ARRAY') ? $t->{points} : [];
		my $pos = 0;
		for my $p (@$plist)
		{
			push @pts, {
				position => $pos++,
				lat      => defined($p->{lat}) ? $p->{lat} + 0 : 0,
				lon      => defined($p->{lon}) ? $p->{lon} + 0 : 0,
				ts       => int($p->{ts} // 0),
			};
		}
		$n_new++ if !exists $ocdb->{tracks}{$tuuid};
		my $foreign = defined(ocpnGuidToNavUuid($t->{guid})) ? 0 : 1;
		$ocdb->{tracks}{$tuuid} = {
			guid        => $t->{guid},
			uuid        => $tuuid,
			name        => defined($t->{name}) ? $t->{name} : '',
			origin      => $foreign ? 'ocpn' : 'navmate',
			point_count => scalar(@pts),
			points      => \@pts,
		};
	}
	return { tracks_new => $n_new };
}


#-----------------------------------------------------------------------
# _wireMarkToOcdb -- one sec-2A wire mark -> an ocdb mark record
#-----------------------------------------------------------------------
# lat/lon kept as full-precision numbers (the wire carries the raw double; sec
# 2A forbids rounding).  Strings default to '' (never undef) to mirror the P1
# "strings present, '' when empty" contract.

sub _wireMarkToOcdb
{
	my ($m, $uuid, $foreign) = @_;
	return {
		guid        => $m->{guid},
		uuid        => $uuid,
		name        => defined($m->{name})        ? $m->{name}        : '',
		lat         => defined($m->{lat}) ? $m->{lat} + 0 : 0,
		lon         => defined($m->{lon}) ? $m->{lon} + 0 : 0,
		description => defined($m->{description}) ? $m->{description} : '',
		icon        => defined($m->{icon})        ? $m->{icon}        : '',
		created_ts  => int($m->{created_ts} // 0),
		origin      => $foreign ? 'ocpn' : 'navmate',
	};
}


#-----------------------------------------------------------------------
# projectDBMarksToWire($rows, $map) -- DB waypoint rows -> sec-2A marks[]
#-----------------------------------------------------------------------
# The Mode-1 projector: takes navMate.db waypoint rows and emits the exact wire
# mark objects the plugin would.  navMate-origin uuids synthesize a reversible
# guid; a uuid already in the reconcile rev-map (a foreign object we ingested)
# re-emits its original opaque guid.
#
# icon: M1 emits '' (the sym->icon table is deferred, protocol sec 13); the
# marks floor proves identity + coordinates + strings.  description <- comment.
# $map may be undef (pure navMate-origin projection, table-free).

sub projectDBMarksToWire
{
	my ($rows, $map) = @_;
	$rows ||= [];
	my @marks;
	for my $r (@$rows)
	{
		next if !defined $r->{uuid};
		push @marks, {
			guid        => projectUuidToGuid($r->{uuid}, $map),
			name        => defined($r->{name})    ? $r->{name}    : '',
			lat         => defined($r->{lat}) ? $r->{lat} + 0 : 0,
			lon         => defined($r->{lon}) ? $r->{lon} + 0 : 0,
			description => defined($r->{comment}) ? $r->{comment} : '',
			icon        => '',
			created_ts  => int($r->{created_ts} // 0),
		};
	}
	return \@marks;
}


#-----------------------------------------------------------------------
# command builders -- ocdb/DB object -> a sec-2A commands[] entry (M3 outbound)
#-----------------------------------------------------------------------
# { op, type, guid, fields }.  fields = full mapped set for add, absent for
# delete.  A ROUTE command FULL-EMBEDS every point's mark (sec 2A inbound rule:
# AddPlugInRouteExV2 builds new RoutePoints per vertex; there is no add-by-ref).

sub buildMarkCommand
{
	my ($op, $mark) = @_;
	my $cmd = { op => $op, type => 'mark', guid => $mark->{guid} };
	if ($op ne 'delete')
	{
		$cmd->{fields} = {
			name        => defined($mark->{name})        ? $mark->{name}        : '',
			lat         => defined($mark->{lat}) ? $mark->{lat} + 0 : 0,
			lon         => defined($mark->{lon}) ? $mark->{lon} + 0 : 0,
			description => defined($mark->{description}) ? $mark->{description} : '',
			icon        => defined($mark->{icon})        ? $mark->{icon}        : '',
			created_ts  => int($mark->{created_ts} // 0),
		};
	}
	return $cmd;
}

sub buildRouteCommand
{
	my ($op, $route, $members) = @_;   # $members: uuid -> mark (for full-embed)
	my $cmd = { op => $op, type => 'route', guid => $route->{guid} };
	if ($op ne 'delete')
	{
		my @points;
		for my $p (@{$route->{points} || []})
		{
			my $m = $members->{$p->{wp_uuid}};
			push @points, {
				guid     => $p->{guid},
				position => int($p->{position} // 0),
				mark     => $m ? {
					guid        => $m->{guid},
					name        => $m->{name}        // '',
					lat         => ($m->{lat} // 0) + 0,
					lon         => ($m->{lon} // 0) + 0,
					description => $m->{description} // '',
					icon        => $m->{icon}        // '',
					created_ts  => int($m->{created_ts} // 0),
				} : undef,
			};
		}
		$cmd->{fields} = {
			name        => $route->{name}        // '',
			description => $route->{description} // '',
			points      => \@points,
		};
	}
	return $cmd;
}


1;
