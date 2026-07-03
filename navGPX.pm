#!/usr/bin/perl
#-----------------------------------------------------------------------
# navGPX.pm -- import and export .gpx (and .gdb) files for navMate
#-----------------------------------------------------------------------
# Supported formats:
#   .gpx  -- parsed / written directly
#   .gdb  -- import only, converted to GPX via gpsbabel, then parsed
#
# Import routes: each rtept becomes a full waypoint in the collection; the
# route record references those waypoints via route_waypoints. Same model
# as navMate's native routes.
#
# Export flattens an arbitrary node's subtree into GPX's three flat buckets
# (wpt / rte / trk) -- navMate's collection hierarchy is NOT carried; the
# user re-files on the way back in, as with every other spoke.
#
# Round-trip identity: every exported object carries its navMate uuid both
# as a <navmate:uuid> extension and, encoded via the prefix trick, as a
# synthesized <opencpn:guid> (which OpenCPN preserves byte-for-byte, unlike
# unknown extensions). On import those tags are consumed so waypoints are
# reused rather than duplicated and route points rejoin by reference.
#
# gpsbabel is optional. If not found, .gdb import returns an error.
# Default path: C:/Program Files/GPSBabel/gpsbabel.exe

package navGPX;
use strict;
use warnings;
use Exporter 'import';
use POSIX qw(mktime strftime);
use XML::Simple qw(:strict);
use Pub::Utils qw(display warning error);
use n_defs;
use navDB;

our @EXPORT = qw(import_gps_file export_gps_subtree find_gpsbabel);


#-----------------------------------------------------------------------
# Identity: navMate 8-byte uuid  <->  synthesized 128-bit OpenCPN GUID
#-----------------------------------------------------------------------
# A navMate uuid is 16 lower-hex chars (8 bytes / 64 bits). An OpenCPN GUID
# is 128 bits, 36-char hyphenated 8-4-4-4-12. We embed the 64-bit uuid in a
# valid RFC-4122-v4-shaped GUID, routing the id AROUND the fixed version
# (byte 6 high nibble) and variant (byte 8 top 2 bits) so it survives
# byte-for-byte AND stays reversible with zero storage.
#
#   G1(8) = uuid[0:8]
#   G2(4) = MAGIC[0:4]
#   G3(4) = '4' . MAGIC[4:7]     (version 4)
#   G4(4) = '8' . MAGIC[7:10]    (variant 10xx)
#   G5(12)= uuid[8:16] . MAGIC[10:14]
#
# MAGIC = ascii("navMate") = 6e61764d617465 -- a 56-bit recognizer that is
# vanishingly unlikely to collide with a real (random) OpenCPN GUID.

my $NM_GUID_MAGIC = '6e61764d617465';   # "navMate"

sub navUuidToOcpnGuid
{
	my ($u) = @_;
	return undef if !defined $u || $u !~ /^[0-9a-fA-F]{16}$/;
	$u = lc $u;
	my $m = $NM_GUID_MAGIC;
	return substr($u,0,8) . '-'
		. substr($m,0,4) . '-'
		. '4' . substr($m,4,3) . '-'
		. '8' . substr($m,7,3) . '-'
		. substr($u,8,8) . substr($m,10,4);
}

sub ocpnGuidToNavUuid
{
	my ($g) = @_;
	return undef if !defined $g;
	$g = lc $g;
	return undef if $g !~ /^([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})$/;
	my ($g1,$g2,$g3,$g4,$g5) = ($1,$2,$3,$4,$5);
	my $m = $NM_GUID_MAGIC;
	return undef unless $g2          eq substr($m,0,4);
	return undef unless substr($g3,1,3) eq substr($m,4,3);
	return undef unless substr($g4,1,3) eq substr($m,7,3);
	return undef unless substr($g5,8,4) eq substr($m,10,4);
	return $g1 . substr($g5,0,8);
}

my $GPSBABEL_DEFAULT = 'C:/Program Files/GPSBabel/gpsbabel.exe';


sub find_gpsbabel
{
	return -f $GPSBABEL_DEFAULT ? $GPSBABEL_DEFAULT : undef;
}


sub _parse_iso8601
{
	my ($s) = @_;
	return undef unless defined $s;
	return undef unless $s =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/;
	return mktime($6, $5, $4, $3, $2-1, $1-1900);
}


# Return the <extensions> child of a parsed wpt/rte/rtept/trk node as a
# hashref (XML::Simple gives a hashref for a single block, arrayref if the
# source unexpectedly repeats it). Foreign extensions we do not model are
# simply left untouched here.
sub _extNode
{
	my ($node) = @_;
	my $ext = $node->{extensions};
	return {} if !defined $ext;
	$ext = $ext->[0] if ref($ext) eq 'ARRAY';
	return (ref($ext) eq 'HASH') ? $ext : {};
}

sub _extText
{
	my ($ext, $key) = @_;
	my $v = $ext->{$key};
	$v = $v->{content} if ref($v) eq 'HASH';   # element carried attributes
	return (defined $v && $v ne '') ? $v : undef;
}

# Recover the navMate uuid for a node: prefer the explicit <navmate:uuid>
# extension; fall back to decoding a navMate-synthesized <opencpn:guid>
# (which survives an OpenCPN detour when the extension does not).
sub _identUuid
{
	my ($ext) = @_;
	my $u = _extText($ext, 'navmate:uuid');
	return lc $u if defined $u && $u =~ /^[0-9a-fA-F]{16}$/;
	my $g = _extText($ext, 'opencpn:guid');
	return defined $g ? ocpnGuidToNavUuid($g) : undef;
}

# Pull the navMate per-item attributes we model out of a node's extensions.
sub _identAttrs
{
	my ($ext) = @_;
	my %a;
	for my $k (qw(wp_type sym depth_cm temp_k ts_source))
	{
		my $v = _extText($ext, "navmate:$k");
		$a{$k} = $v if defined $v;
	}
	return \%a;
}


sub _parse_gpx_text
{
	my ($text) = @_;
	my $xml = XML::Simple->new(
		ForceArray => ['trk','trkseg','trkpt','wpt','rte','rtept'],
		KeyAttr    => []);
	my $gpx = eval { $xml->XMLin($text) };
	if ($@)
	{
		warning(0,0,"navGPX::_parse_gpx_text XML parse error: $@");
		return undef;
	}

	my @tracks;
	for my $trk (@{$gpx->{trk} // []})
	{
		my @pts;
		for my $seg (@{$trk->{trkseg} // []})
		{
			for my $pt (@{$seg->{trkpt} // []})
			{
				push @pts, {
					lat => $pt->{lat} + 0,
					lon => $pt->{lon} + 0,
					ts  => _parse_iso8601($pt->{time}),
				};
			}
		}
		next unless @pts;
		my $ext = _extNode($trk);
		push @tracks, {
			name     => $trk->{name} // 'Track',
			points   => \@pts,
			nav_uuid => _identUuid($ext),
		};
	}

	my @waypoints;
	for my $wpt (@{$gpx->{wpt} // []})
	{
		my $ext = _extNode($wpt);
		push @waypoints, {
			name     => $wpt->{name} // 'Waypoint',
			lat      => $wpt->{lat} + 0,
			lon      => $wpt->{lon} + 0,
			ts       => _parse_iso8601($wpt->{time}),
			comment  => $wpt->{desc} // $wpt->{cmt} // '',
			nav_uuid => _identUuid($ext),
			attrs    => _identAttrs($ext),
		};
	}

	my @routes;
	for my $rte (@{$gpx->{rte} // []})
	{
		my @pts;
		for my $pt (@{$rte->{rtept} // []})
		{
			my $pext = _extNode($pt);
			push @pts, {
				name     => $pt->{name} // 'WP',
				lat      => $pt->{lat} + 0,
				lon      => $pt->{lon} + 0,
				comment  => $pt->{desc} // $pt->{cmt} // '',
				nav_uuid => _identUuid($pext),
				attrs    => _identAttrs($pext),
			};
		}
		next unless @pts;
		my $ext = _extNode($rte);
		push @routes, {
			name     => $rte->{name} // 'Route',
			points   => \@pts,
			nav_uuid => _identUuid($ext),
		};
	}

	return { tracks => \@tracks, waypoints => \@waypoints, routes => \@routes };
}


sub _leaf_name
{
	my ($file_path) = @_;
	my $base = (split /[\/\\]/, $file_path)[-1];
	$base =~ s/\.(gpx|gdb)$//i;
	return $base;
}


# Insert or reuse a waypoint honoring round-trip identity.  Returns the DB
# uuid to reference.  $seen maps a recovered navMate uuid to the uuid used
# in this import, so a route point rejoins an already-imported standalone
# waypoint by reference instead of creating a duplicate.  A tagged uuid that
# already exists in the DB is reused as-is (never re-inserted); an untagged
# (foreign) point mints a fresh uuid, exactly as before.
sub _resolveWaypoint
{
	my ($dbh, $wpt, $coll_uuid, $seen) = @_;
	my $nu = $wpt->{nav_uuid};
	my $ax = $wpt->{attrs} || {};

	if (defined $nu)
	{
		return $seen->{$nu} if $seen->{$nu};
		if (getWaypoint($dbh, $nu))
		{
			$seen->{$nu} = $nu;
			return $nu;
		}
	}

	my %arg = (
		name            => $wpt->{name},
		lat             => $wpt->{lat},
		lon             => $wpt->{lon},
		comment         => $wpt->{comment},
		wp_type         => $ax->{wp_type},
		sym             => $ax->{sym},
		depth_cm        => $ax->{depth_cm},
		temp_k          => $ax->{temp_k},
		created_ts      => $wpt->{ts} // 0,
		ts_source       => $ax->{ts_source} // (defined($wpt->{ts}) ? 'gdb' : 'import'),
		source          => undef,
		collection_uuid => $coll_uuid);
	$arg{uuid} = $nu if defined $nu;

	my $uuid = insertWaypoint($dbh, %arg);
	$seen->{$nu} = $uuid if defined $nu;
	return $uuid;
}


sub import_gps_file
{
	my ($dbh, $file_path, $coll_uuid) = @_;

	my $gpx_text;
	my $tmp_file;

	if ($file_path =~ /\.gpx$/i)
	{
		open my $fh, '<', $file_path
			or return { error => "Cannot open $file_path: $!" };
		local $/;
		$gpx_text = <$fh>;
		close $fh;
	}
	elsif ($file_path =~ /\.gdb$/i)
	{
		my $gbs = find_gpsbabel();
		if (!$gbs)
		{
			return { error => "gpsbabel not found at $GPSBABEL_DEFAULT -- .gdb import unavailable" };
		}
		$tmp_file = ($ENV{TEMP} // $ENV{TMP} // 'C:/Windows/Temp') . "/navmate_gps_import_$$.gpx";
		my $cmd = qq{"$gbs" -i gdb -f "$file_path" -o gpx -F "$tmp_file" 2>NUL};
		my $rc  = system($cmd);
		if ($rc || !-f $tmp_file)
		{
			unlink $tmp_file if $tmp_file;
			return { error => "gpsbabel failed (rc=$rc) for $file_path" };
		}
		open my $fh, '<', $tmp_file
			or do { unlink $tmp_file; return { error => "Cannot read gpsbabel output: $!" } };
		local $/;
		$gpx_text = <$fh>;
		close $fh;
		unlink $tmp_file;
	}
	else
	{
		return { error => "Unsupported file type: $file_path" };
	}

	my $parsed = _parse_gpx_text($gpx_text);
	if (!$parsed)
	{
		return { error => "Failed to parse GPX from $file_path" };
	}

	my @waypoints = @{$parsed->{waypoints}};
	my @routes    = @{$parsed->{routes}};
	my @tracks    = @{$parsed->{tracks}};

	my $leaf = _leaf_name($file_path);
	my $file_branch = insertCollection($dbh, $leaf, $coll_uuid, $NODE_TYPE_BRANCH, '');
	return { error => "Failed to create file branch '$leaf'" } if !$file_branch;

	my $groups_branch;
	if (@waypoints || @routes)
	{
		$groups_branch = insertCollection($dbh, 'Groups', $file_branch, $NODE_TYPE_BRANCH, '');
	}

	# Standalone waypoints first, so route points below can rejoin them.
	my %seen;
	if (@waypoints)
	{
		my $my_wpts = insertCollection($dbh, 'My Waypoints', $groups_branch, $NODE_TYPE_GROUP, '');
		for my $wpt (@waypoints)
		{
			_resolveWaypoint($dbh, $wpt, $my_wpts, \%seen);
		}
	}

	my @route_groups;
	for my $rte (@routes)
	{
		my $rg = insertCollection($dbh, $rte->{name}, $groups_branch, $NODE_TYPE_GROUP, '');
		my @wp_uuids;
		for my $pt (@{$rte->{points}})
		{
			push @wp_uuids, _resolveWaypoint($dbh, $pt, $rg, \%seen);
		}
		push @route_groups, { route => $rte, wp_uuids => \@wp_uuids };
	}

	if (@routes)
	{
		my $routes_branch = insertCollection($dbh, 'Routes', $file_branch, $NODE_TYPE_BRANCH, '');
		for my $rg (@route_groups)
		{
			my $rte = $rg->{route};
			my $ru  = $rte->{nav_uuid};
			my $route_uuid = (defined $ru && !getRoute($dbh, $ru))
				? insertRouteUUID($dbh, $ru, $rte->{name}, undef, '', $routes_branch)
				: insertRoute($dbh, $rte->{name}, undef, '', $routes_branch);
			my $rp_pos = 0;
			for my $wp_uuid (@{$rg->{wp_uuids}})
			{
				appendRouteWaypoint($dbh, $route_uuid, $wp_uuid, $rp_pos);
				$rp_pos++;
			}
		}
	}

	if (@tracks)
	{
		my $tracks_branch = insertCollection($dbh, 'Tracks', $file_branch, $NODE_TYPE_BRANCH, '');
		for my $trk (@tracks)
		{
			my @pts   = @{$trk->{points}};
			my @times = sort { $a <=> $b } grep { defined $_ } map { $_->{ts} } @pts;
			my $ts_start  = $times[0];
			my $ts_end    = $times[-1];
			my $ts_source = defined $ts_start ? 'gdb' : 'import';
			my $tu = $trk->{nav_uuid};
			my %targ = (
				name            => $trk->{name},
				ts_start        => $ts_start // 0,
				ts_end          => $ts_end,
				ts_source       => $ts_source,
				point_count     => scalar @pts,
				collection_uuid => $tracks_branch);
			$targ{uuid} = $tu if defined $tu && !getTrack($dbh, $tu);
			my $uuid = insertTrack($dbh, %targ);
			insertTrackPoints($dbh, $uuid, \@pts);
		}
	}

	my $n_wpts   = scalar @waypoints;
	my $n_routes = scalar @routes;
	my $n_tracks = scalar @tracks;
	display(0,0,"navGPX: imported $n_tracks tracks, $n_wpts waypoints, $n_routes routes into branch '$leaf' from $file_path");
	return { tracks => $n_tracks, waypoints => $n_wpts, routes => $n_routes, branch => $leaf };
}


#-----------------------------------------------------------------------
# EXPORT
#-----------------------------------------------------------------------
# Flattens the subtree rooted at $root_uuid into GPX's three flat buckets.
# The collection hierarchy is deliberately NOT carried -- every descendant
# waypoint/route/track lands at top level and the user re-files on import,
# as with the E80 and FSH spokes.  Each object carries its navMate uuid as
# both a <navmate:uuid> extension and a synthesized <opencpn:guid>.

sub _esc
{
	my ($t) = @_;
	return '' if !defined $t;
	$t =~ s/&/&amp;/g;
	$t =~ s/</&lt;/g;
	$t =~ s/>/&gt;/g;
	$t =~ s/"/&quot;/g;
	return $t;
}

sub _isoEpoch
{
	my ($epoch) = @_;
	return undef if !defined $epoch || $epoch <= 0;
	return strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($epoch));
}

# Only emit a waypoint <time> when the timestamp is a real observation, not
# a synthetic import/nav placeholder.
sub _realTs
{
	my ($ts_source) = @_;
	my $s = $ts_source // '';
	return ($s ne '' && $s ne 'import' && $s ne 'nav');
}

sub _gpxExt
{
	my ($pad, $uuid, %attr) = @_;
	my $s = "$pad<extensions>\n";
	if (defined $uuid && $uuid ne '')
	{
		my $guid = navUuidToOcpnGuid($uuid);
		$s .= "$pad  <opencpn:guid>$guid</opencpn:guid>\n" if defined $guid;
		$s .= "$pad  <navmate:uuid>$uuid</navmate:uuid>\n";
	}
	for my $k (qw(wp_type sym))
	{
		$s .= "$pad  <navmate:$k>$attr{$k}</navmate:$k>\n" if defined $attr{$k};
	}
	for my $k (qw(depth_cm temp_k))
	{
		$s .= "$pad  <navmate:$k>$attr{$k}</navmate:$k>\n" if defined $attr{$k} && $attr{$k} != 0;
	}
	$s .= "$pad  <navmate:ts_source>" . _esc($attr{ts_source}) . "</navmate:ts_source>\n"
		if defined $attr{ts_source} && $attr{ts_source} ne '';
	$s .= "$pad</extensions>\n";
	return $s;
}

sub _emitWpt
{
	my ($w) = @_;
	my $s  = qq{  <wpt lat="$w->{lat}" lon="$w->{lon}">\n};
	$s .= "    <name>" . _esc($w->{name}) . "</name>\n";
	$s .= "    <desc>" . _esc($w->{comment}) . "</desc>\n"
		if defined $w->{comment} && $w->{comment} ne '';
	my $iso = _realTs($w->{ts_source}) ? _isoEpoch($w->{created_ts}) : undef;
	$s .= "    <time>$iso</time>\n" if defined $iso;
	$s .= _gpxExt("    ", $w->{uuid},
		wp_type   => $w->{wp_type},
		sym       => $w->{sym},
		depth_cm  => $w->{depth_cm},
		temp_k    => $w->{temp_k},
		ts_source => $w->{ts_source});
	$s .= "  </wpt>\n";
	return $s;
}

sub _emitRte
{
	my ($dbh, $r) = @_;
	my $wps = getRouteWaypoints($dbh, $r->{uuid});
	my $s   = "  <rte>\n";
	$s .= "    <name>" . _esc($r->{name}) . "</name>\n";
	$s .= "    <desc>" . _esc($r->{comment}) . "</desc>\n"
		if defined $r->{comment} && $r->{comment} ne '';
	$s .= _gpxExt("    ", $r->{uuid});
	for my $p (@{$wps // []})
	{
		my $full = getWaypoint($dbh, $p->{uuid}) || $p;
		$s .= qq{    <rtept lat="$full->{lat}" lon="$full->{lon}">\n};
		$s .= "      <name>" . _esc($full->{name}) . "</name>\n";
		$s .= _gpxExt("      ", $full->{uuid},
			wp_type   => $full->{wp_type},
			sym       => $full->{sym},
			depth_cm  => $full->{depth_cm},
			temp_k    => $full->{temp_k},
			ts_source => $full->{ts_source});
		$s .= "    </rtept>\n";
	}
	$s .= "  </rte>\n";
	return $s;
}

sub _emitTrk
{
	my ($dbh, $t) = @_;
	my $pts = getTrackPoints($dbh, $t->{uuid});
	my $s   = "  <trk>\n";
	$s .= "    <name>" . _esc($t->{name}) . "</name>\n";
	$s .= _gpxExt("    ", $t->{uuid});
	$s .= "    <trkseg>\n";
	for my $p (@{$pts // []})
	{
		$s .= qq{      <trkpt lat="$p->{lat}" lon="$p->{lon}">\n};
		my $iso = _isoEpoch($p->{ts});
		$s .= "        <time>$iso</time>\n" if defined $iso;
		$s .= "      </trkpt>\n";
	}
	$s .= "    </trkseg>\n";
	$s .= "  </trk>\n";
	return $s;
}

sub _collectSubtree
{
	my ($dbh, $coll_uuid, $wpts, $rtes, $trks) = @_;

	my $objs = getCollectionObjects($dbh, $coll_uuid);
	for my $o (@{$objs // []})
	{
		my $t = $o->{obj_type};
		if    ($t eq 'waypoint') { my $w = getWaypoint($dbh, $o->{uuid}); push @$wpts, $w if $w; }
		elsif ($t eq 'route')    { my $r = getRoute($dbh, $o->{uuid});    push @$rtes, $r if $r; }
		elsif ($t eq 'track')    { my $k = getTrack($dbh, $o->{uuid});    push @$trks, $k if $k; }
	}

	my $kids = getCollectionChildren($dbh, $coll_uuid);
	for my $c (@{$kids // []})
	{
		_collectSubtree($dbh, $c->{uuid}, $wpts, $rtes, $trks);
	}
}

sub _writeGPX
{
	my ($dbh, $path, $wpts, $rtes, $trks) = @_;
	my $fh;
	if (!open($fh, '>:encoding(UTF-8)', $path))
	{
		error("navGPX: cannot write $path: $!");
		return 0;
	}
	print $fh qq{<?xml version="1.0" encoding="UTF-8"?>\n};
	print $fh qq{<gpx version="1.1" creator="navMate"\n};
	print $fh qq{     xmlns="http://www.topografix.com/GPX/1/1"\n};
	print $fh qq{     xmlns:navmate="http://phorton.com/navmate/gpx/1"\n};
	print $fh qq{     xmlns:opencpn="http://www.opencpn.org">\n};
	print $fh _emitWpt($_)        for @$wpts;
	print $fh _emitRte($dbh, $_)  for @$rtes;
	print $fh _emitTrk($dbh, $_)  for @$trks;
	print $fh qq{</gpx>\n};
	close $fh;
	return 1;
}

sub export_gps_subtree
{
	my ($path, $root_uuid) = @_;
	if (!defined $root_uuid || $root_uuid eq '')
	{
		error("navGPX: export_gps_subtree requires a root uuid");
		return 0;
	}
	my $dbh = connectDB();

	my (@wpts, @rtes, @trks);
	my $coll = getCollection($dbh, $root_uuid);
	if ($coll)
	{
		_collectSubtree($dbh, $coll->{uuid}, \@wpts, \@rtes, \@trks);
	}
	else
	{
		my $wp = getWaypoint($dbh, $root_uuid);
		my $rt = $wp ? undef : getRoute($dbh, $root_uuid);
		my $tr = ($wp || $rt) ? undef : getTrack($dbh, $root_uuid);
		if    ($wp) { push @wpts, $wp; }
		elsif ($rt) { push @rtes, $rt; }
		elsif ($tr) { push @trks, $tr; }
		else
		{
			disconnectDB($dbh);
			error("navGPX: export root uuid '$root_uuid' not found");
			return 0;
		}
	}

	my $ok = _writeGPX($dbh, $path, \@wpts, \@rtes, \@trks);
	disconnectDB($dbh);
	display(0,0,"navGPX: exported " . scalar(@trks) . " tracks, "
		. scalar(@wpts) . " waypoints, " . scalar(@rtes) . " routes to $path") if $ok;
	return $ok;
}

1;
