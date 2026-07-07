#------------------------------------------------------------------------
# navOCPN.pm
#------------------------------------------------------------------------
# navMate's IN-MEMORY representation of the OpenCPN spoke (the oESeries plugin) --
# "the ocdb".  navMate is the HTTP SERVER; oESeries is a polling HTTP CLIENT.
# This module sits under the /api/ocpn endpoint in navServer.pm and is exercised
# headlessly by _testOEServer.pm.
#
# LAYERING (mirrors the E80 spoke: Pub::Ray wire -> nmE80DirectOps -> winE80):
#   navIdentity      - the uuid<->GUID codec + foreign-GUID reconcile
#   nmOCPNDirectOps  - PURE wire<->ocdb<->DB transforms (ingest / project)
#   navOCPN (here)   - the shared ocdb state, its lock, serialization, the DTs,
#                      and the command queue; the accessors winOCPN will use
#
# THREADING: the HTTP server runs a worker-thread pool (HTTP_MAX_THREADS), so
# the ocdb must be reachable across threads.  Rather than fight nested
# threads::shared, the canonical ocdb is held as a single shared JSON scalar
# ($ocdb_json) guarded by one lock ($state_lock); each op decodes a plain hash,
# mutates it, and re-encodes.  At the marks/routes scale of this spoke that is
# trivial and keeps the direct-ops logic pure and testable.
#
# Two DTs (protocol.md sec 3):
#   ocpn_dt    - the DT the client last sent WITH a real inventory (0 = none).
#   navmate_dt - navMate's own token.  HARDCODED 0 until the deferred db_version
#                counter (Phase 2 / M3); there is no outbound push before then.
#
# ECHO INVARIANT (sec 2A): ingestInventory writes ONLY this in-memory ocdb, never
# canonical navMate.db, so navmate_dt never advances on an inbound inventory and
# no command is minted from an echo.  The loop cannot ping-pong -- broken by
# construction at the spoke/canonical boundary.

package navOCPN;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display warning error $data_dir);
use Pub::HTTP::Response;
use navDB qw(symForIcon);
use nmOCPNDirectOps;

our $dbg_ocpn = 0;			# 0 = log received inventories; raise to quiet

my $state_lock    :shared;			# the single mutex guarding all state below
my $ocdb_json     :shared = '';		# serialized ocdb (see nmOCPNDirectOps for shape)
my $commands_json :shared = '[]';	# pending hub->plugin commands (M3); [] for now
our $ocpn_dt      :shared = 0;		# client DT last received WITH an inventory
our $navmate_dt   :shared = 0;		# navMate's token: 0 until the db_version gate (M3)
my $last_recv_ts  :shared = 0;
my $recv_count    :shared = 0;
my $last_ingest_json :shared = '';	# the last ingest summary (marks_in vs distinct etc.)
my $last_results_json :shared = '';	# the last POSTed results[] (incl diag data) for asserts

# Symbol channel (protocol sec 7 / co-design Turn 25).  Every POST carries an
# icon_hash (SHA-256 over the plugin's foreign non-nm: icon name set).  HASH-FIRST
# / FETCH-ON-DEMAND: we only ever hold the hash; when it names a library we don't
# have on disk yet we raise want_icons in the poll view, and the plugin's next
# POST carries the full ocpn_icons[] which we cache to disk (the OpenCPN-icon
# library, keyed by hash, under $data_dir).  Persistent across resets; the disk
# cache is the durable library, these vars are just the live channel state.
my $icon_hash    :shared = '';		# last icon_hash the plugin reported ('' = none yet)
my $want_icons   :shared = 0;		# ask the plugin to include ocpn_icons[] next POST
my $icon_forced  :shared = 0;		# a /debug/want_icons force (sticky until icons arrive)

# Wire self-versioning (protocol.md "Versioning", spec 1.0).  Each side announces
# the contract IT speaks in its own envelope -- navMate in the GET poll view, the
# plugin in its POST.  MAJOR.MINOR string; MINOR = upward-compatible additive,
# MAJOR = breaking.  ABSENT == "1.0" baseline (so a pre-versioning plugin reads as
# 1.0 and nothing breaks).  SOFT floor: warn once if the peer's MAJOR is below the
# minimum, but NEVER gate -- co-dev must survive a version skew.
our $PROTOCOL_VERSION   = '1.0';	# the contract navMate speaks
my  $PROTOCOL_MIN_MAJOR = 1;		# minimum peer MAJOR before we warn
my  $peer_protocol   :shared = '';	# the plugin's last-announced protocol_version
my  $peer_ver_warned :shared = 0;	# warn-once latch (re-armed on a version change)

sub _verMajor
{
	my ($v) = @_;
	return 1 if !defined $v || $v eq '';   # absent == 1.0 baseline
	return ($v =~ /^(\d+)/) ? int($1) : 1;
}


#------------------------------------------------------------
# jsonResponse($request, $data) - encode an /api/ocpn response as STANDARD JSON
#------------------------------------------------------------
# The OpenCPN wire is consumed by the plugin's nlohmann parser, which needs
# real JSON: booleans as true/false and strings as \uXXXX / UTF-8 -- NOT Pub's
# my_encode_json (json_response), which renders booleans as "1" and HTML-entity-
# encodes non-ASCII (&#28207;).  We pre-encode with JSON::PP in ascii mode (pure
# ASCII \uXXXX -- unambiguous over HTTP, and nlohmann parses it) and hand the
# byte string to Response->new, which passes a non-ref content through verbatim.
# canonical => stable key order for clean diffs/asserts.

sub jsonResponse
{
	my ($request, $data) = @_;
	my $body = JSON::PP->new->ascii->canonical->encode($data);
	return Pub::HTTP::Response->new($request, $body, 200, 'application/json');
}


#------------------------------------------------------------
# ocdb load / store  (caller MUST hold $state_lock)
#------------------------------------------------------------

sub _loadOcdb
{
	return nmOCPNDirectOps::blankOcdb() if !$ocdb_json || $ocdb_json eq '';
	my $h = eval { decode_json($ocdb_json) };
	return (ref($h) eq 'HASH') ? $h : nmOCPNDirectOps::blankOcdb();
}

sub _storeOcdb
{
	my ($ocdb) = @_;
	$ocdb_json = encode_json($ocdb);
}

sub _commands
{
	my $c = eval { decode_json($commands_json) };
	return (ref($c) eq 'ARRAY') ? $c : [];
}


#------------------------------------------------------------
# symbol channel -- the persistent OpenCPN-icon disk cache (sec 7)
#------------------------------------------------------------
# The durable icon library lives under $data_dir/ocpn_icons/<hash>.json -- one
# file per distinct icon set, keyed by the plugin's icon_hash.  navMate NEVER
# reads OpenCPN's filesystem (the plugin may be on another machine); the library
# is built solely from what crosses the wire (the ocpn_icons[] fetch).  The hash
# is a SHA-256 hex string from the plugin; we validate it as hex before ever
# using it as a filename (no path-injection from the wire).

sub _validHash { return (defined $_[0] && $_[0] =~ /^[0-9a-fA-F]{16,128}$/) ? 1 : 0; }

sub _iconCacheDir
{
	my $dir = "$data_dir/ocpn_icons";
	mkdir($dir) if !-d $dir;
	return $dir;
}

sub _iconCachePath { return _iconCacheDir()."/$_[0].json"; }

sub _iconCacheHas
{
	my ($hash) = @_;
	return (_validHash($hash) && -f _iconCachePath($hash)) ? 1 : 0;
}

sub _iconCacheStore
{
	my ($hash, $icons) = @_;
	if (!_validHash($hash))
	{
		warning(0,0,"navOCPN: refusing to cache icons under non-hex hash '".($hash//'')."'");
		return 0;
	}
	my $rec = {
		icon_hash   => "$hash",
		received_ts => time(),
		count       => scalar(@$icons),
		icons       => $icons,
	};
	my $path = _iconCachePath($hash);
	if (open(my $fh, '>', $path))
	{
		binmode($fh);
		print $fh encode_json($rec);
		close($fh);
		display($dbg_ocpn,0,"navOCPN: cached ".scalar(@$icons)." OpenCPN icons for hash $hash");
		return 1;
	}
	warning(0,0,"navOCPN: could not write icon cache $path: $!");
	return 0;
}

sub _iconCacheLoad
{
	my ($hash) = @_;
	return undef if !_iconCacheHas($hash);
	open(my $fh, '<', _iconCachePath($hash)) or return undef;
	binmode($fh);
	local $/;
	my $raw = <$fh>;
	close($fh);
	return eval { decode_json($raw) };
}


#------------------------------------------------------------
# _processIconChannel($body) -- run the hash gate on a POST  (caller holds lock)
#------------------------------------------------------------
# Ingest-first: if this POST actually carried ocpn_icons[], cache the library
# under its hash and the request is satisfied.  Otherwise track the reported hash
# and raise want_icons on a cache MISS (or while a /debug force is live), so the
# plugin's next POST brings the library.  A cache HIT stays quiet -- only the hash
# rides, never the payload (fetch-on-demand).

sub _processIconChannel
{
	my ($body) = @_;
	my $hash  = defined($body->{icon_hash}) ? "$body->{icon_hash}" : '';
	my $icons = (ref($body->{ocpn_icons}) eq 'ARRAY') ? $body->{ocpn_icons} : undef;

	if ($icons && @$icons)   # the library arrived
	{
		my $key = ($hash ne '') ? $hash : $icon_hash;
		_iconCacheStore($key, $icons);
		$icon_hash   = $hash if $hash ne '';
		$want_icons  = 0;
		$icon_forced = 0;
		return;
	}

	return if $hash eq '';   # a bare ack/poll POST with no symbol traffic
	$icon_hash  = $hash;
	$want_icons = ($icon_forced || !_iconCacheHas($hash)) ? 1 : 0;
}

# _iconChannelState() -- structured channel state (caller holds lock)
sub _iconChannelState
{
	my $lib = _iconCacheHas($icon_hash) ? _iconCacheLoad($icon_hash) : undef;
	return {
		icon_hash  => "$icon_hash",
		want_icons => ($want_icons ? JSON::PP::true : JSON::PP::false),
		forced     => ($icon_forced ? JSON::PP::true : JSON::PP::false),
		cached     => ($lib ? JSON::PP::true : JSON::PP::false),
		icon_count => ($lib ? ($lib->{count} + 0) : 0),
	};
}


#------------------------------------------------------------
# pollView() - the version view navMate returns on every GET / POST
#------------------------------------------------------------
# ok is a JSON BOOL (sec 2A: "ok is a JSON bool everywhere"); commands is
# ALWAYS present, [] when empty.

sub pollView
{
	lock($state_lock);
	return {
		ok         => JSON::PP::true,
		protocol_version => $PROTOCOL_VERSION,   # the contract navMate speaks (self-announce)
		navmate_dt => $navmate_dt + 0,
		ocpn_dt    => $ocpn_dt + 0,
		commands   => _commands(),
		# symbol channel (sec 7): true = include ocpn_icons[] in your next POST.
		want_icons => ($want_icons ? JSON::PP::true : JSON::PP::false),
	};
}


#------------------------------------------------------------
# receiveInventory($body) - a POSTed sec-2A inventory
#     { dt, marks:[...], routes:[...], tracks:[...], results:[...] }
# Ingest into the ocdb (in-memory only), remember the client dt, and return the
# poll view.  Returns the view PLUS an 'ingest' summary the harness asserts on.
#------------------------------------------------------------

sub receiveInventory
{
	my ($body) = @_;
	lock($state_lock);

	my $dt = defined($body->{dt}) ? $body->{dt} + 0 : 0;

	# Wire self-versioning: record the plugin's announced protocol_version (absent
	# == 1.0 baseline) and soft-floor-warn ONCE if its MAJOR is below our minimum.
	# Never gate -- a version skew must not blank the pane.
	my $pv = (defined($body->{protocol_version}) && $body->{protocol_version} ne '')
		? "$body->{protocol_version}" : '1.0';
	$peer_ver_warned = 0 if $pv ne $peer_protocol;   # re-arm the latch on a change
	$peer_protocol   = $pv;
	if (_verMajor($pv) < $PROTOCOL_MIN_MAJOR && !$peer_ver_warned)
	{
		warning(0,0,"navOCPN: OpenCPN plugin speaks protocol $pv; navMate needs ".
			"$PROTOCOL_MIN_MAJOR.x -- some features may not work, please update the plugin");
		$peer_ver_warned = 1;
	}

	my $ocdb    = _loadOcdb();
	my $summary = nmOCPNDirectOps::ingestInventory($ocdb, $body);
	_storeOcdb($ocdb);
	$last_ingest_json = encode_json($summary);   # persist marks_in/distinct for readback

	# Consume results[]: an ok ack retires the matching pending command (by
	# guid+op).  This does NOT bump navmate_dt -- retiring an ack is not a new
	# canonical mutation, and neither is the ingest above -- so an echoed object
	# reappearing in marks[] can never re-mint a command (the echo invariant).
	# Symbol channel (sec 7): run the icon_hash gate / ingest any ocpn_icons[]
	# BEFORE building the view, so want_icons in THIS response already reflects a
	# just-satisfied fetch (icons in this POST) or a fresh miss (new hash).
	_processIconChannel($body);

	my $acked = _consumeResults($body->{results});
	# Preserve the last NON-EMPTY results[] -- the plugin re-POSTs several times
	# (results batch, then echo, then steady-state) and the later POSTs carry an
	# empty results[]; don't let them clobber the diag/ack data we need to assert.
	$last_results_json = encode_json($body->{results})
		if ref($body->{results}) eq 'ARRAY' && @{$body->{results}};

	$ocpn_dt      = $dt;
	$last_recv_ts = time();
	$recv_count++;

	display($dbg_ocpn, 0, sprintf(
		"navOCPN: ingested dt=%s (count=%d marks_in=%d total=%d minted=%d)",
		$dt, $recv_count, $summary->{marks_in}, $summary->{marks_total},
		$summary->{guids_minted}));

	my $view = pollView();
	$view->{ingest}       = $summary;
	$view->{acked}        = $acked;
	return $view;
}


#------------------------------------------------------------
# enqueueCommands($cmds) - queue hub->plugin commands (M3 outbound)
#------------------------------------------------------------
# Appends one command (hashref) or a batch (arrayref) to the pending queue and
# bumps navmate_dt -- the version token that makes the plugin's next GET fetch
# the batch (sec 3, two-DT gate).  In production the bump is trigger-driven by
# the db_version counter on a user PASTE into the OCPN spoke; the harness calls
# this directly (POST /debug/enqueue) to drive the outbound path in Mode-1
# without the real counter.

sub enqueueCommands
{
	my ($cmds) = @_;
	$cmds = [$cmds]  if ref($cmds) eq 'HASH';
	$cmds = []       if ref($cmds) ne 'ARRAY';
	lock($state_lock);
	my $cur = _commands();
	push @$cur, @$cmds;
	$commands_json = encode_json($cur);
	$navmate_dt = $navmate_dt + 1 if @$cmds;   # single-minter, strictly increasing
	return {
		ok         => JSON::PP::true,
		navmate_dt => $navmate_dt + 0,
		queued     => scalar(@$cmds),
		pending    => scalar(@$cur),
	};
}


#------------------------------------------------------------
# pushItems($items, $op) - project canonical clip items -> commands -> queue
#------------------------------------------------------------
# The outbound entry point navOps calls: a PASTE/PUSH of hub objects INTO the
# OpenCPN spoke.  Delegates the projection + manifestation XOR to
# nmOCPNDirectOps::buildCommandsForItems (passing the ocdb guid map so a foreign
# object round-trips its original opaque guid), then enqueues the batch (which
# bumps navmate_dt so the plugin's next GET fetches it).  $op: 'add' (default,
# upsert) or 'delete'.  Returns the enqueue summary.

sub pushItems
{
	my ($items, $op) = @_;
	$op ||= 'add';
	my $map;
	{
		lock($state_lock);
		my $ocdb = _loadOcdb();
		$map = $ocdb->{map};   # a decoded (non-shared) copy -- safe to extend
	}
	# Merge the PERSISTED foreign-guid map (protocol sec 4): an OpenCPN object
	# pasted into navMate.db and pushed back AFTER the plugin forgot it (so it is
	# no longer in the in-memory ocdb map) still re-emits its original opaque
	# guid.  The ocdb map wins on conflict (it is the live truth).
	my $dbh = navDB::connectDB();
	if ($dbh)
	{
		my $dbmap = navDB::loadOCPNGuidMap($dbh);
		navDB::disconnectDB($dbh);
		$map->{rev}{$_} //= $dbmap->{rev}{$_} for keys %{$dbmap->{rev} || {}};
		$map->{fwd}{$_} //= $dbmap->{fwd}{$_} for keys %{$dbmap->{fwd} || {}};
	}
	my $cmds = nmOCPNDirectOps::buildCommandsForItems($items, $map, $op);
	return enqueueCommands($cmds);
}


#------------------------------------------------------------
# pushFieldUpdate($nav_type, $uuid, \%changed) - a field-level edit -> update cmd
#------------------------------------------------------------
# The winOCPN inline-editor Save path (sec 8): enqueue an 'update' carrying ONLY
# the fields the user changed, so the plugin's read-modify-write leaves every
# untouched OpenCPN-only field at its live value.  $changed is in wire shape
# (description not comment; B fields flat, range_rings nested); [R] fields and
# undefs are dropped by buildUpdateCommand.  Projects uuid->guid via the merged
# ocdb+DB map exactly as pushItems, so a foreign object re-emits its opaque guid.

sub pushFieldUpdate
{
	my ($nav_type, $uuid, $changed) = @_;
	return { ok => JSON::PP::false, error => 'no fields' }
		if ref($changed) ne 'HASH' || !%$changed;
	return { ok => JSON::PP::false, error => 'no uuid' } if !defined $uuid || $uuid eq '';

	my $map;
	{
		lock($state_lock);
		my $ocdb = _loadOcdb();
		$map = $ocdb->{map};
	}
	my $dbh = navDB::connectDB();
	if ($dbh)
	{
		my $dbmap = navDB::loadOCPNGuidMap($dbh);
		navDB::disconnectDB($dbh);
		$map->{rev}{$_} //= $dbmap->{rev}{$_} for keys %{$dbmap->{rev} || {}};
		$map->{fwd}{$_} //= $dbmap->{fwd}{$_} for keys %{$dbmap->{fwd} || {}};
	}
	my $cmd = nmOCPNDirectOps::buildUpdateCommand($nav_type, $uuid, $map, $changed);
	return enqueueCommands([$cmd]);
}


#------------------------------------------------------------
# _consumeResults($results) - retire acked commands  (caller holds lock)
#------------------------------------------------------------

sub _consumeResults
{
	my ($results) = @_;
	return 0 if ref($results) ne 'ARRAY' || !@$results;
	my %acked;
	my $any_diag_ack = 0;
	for my $r (@$results)
	{
		next if !$r->{ok};
		$acked{ ($r->{guid} // '') . '|' . ($r->{op} // '') } = 1;
		$any_diag_ack = 1 if ($r->{op} // '') eq 'diag';
	}
	return 0 if !%acked && !$any_diag_ack;
	# Mutations retire on an exact guid|op match.  Diag is non-mutating and
	# one-shot: sec 2A allows its result guid to be "*" or absent, so retire ANY
	# pending diag command when a diag ack arrives (never leave it re-delivering).
	my $cur = _commands();
	my @keep = grep {
		my $is_diag = (($_->{op} // '') eq 'diag');
		!( $acked{ ($_->{guid} // '') . '|' . ($_->{op} // '') }
		   || ($is_diag && $any_diag_ack) );
	} @$cur;
	my $retired = scalar(@$cur) - scalar(@keep);
	$commands_json = encode_json(\@keep) if $retired;
	return $retired;
}


#------------------------------------------------------------
# dumpState() - structured readback for asserts (GET /api/ocpn?dump=1)
#------------------------------------------------------------
# The autonomous-peer readback surface: the whole decoded ocdb (marks by uuid,
# the guid reconcile map, counts) plus the DTs and receive stats.  This is my
# side's analog of the plugin's diag channel.

sub dumpState
{
	lock($state_lock);
	my $ocdb = _loadOcdb();
	return {
		ok         => JSON::PP::true,
		protocol_version => $PROTOCOL_VERSION,
		peer_protocol    => "$peer_protocol",
		navmate_dt => $navmate_dt + 0,
		ocpn_dt    => $ocpn_dt + 0,
		recv_count => $recv_count + 0,
		last_recv  => $last_recv_ts + 0,
		counts     => {
			marks  => scalar(keys %{$ocdb->{marks}  || {}}),
			routes => scalar(keys %{$ocdb->{routes} || {}}),
			tracks => scalar(keys %{$ocdb->{tracks} || {}}),
		},
		marks    => $ocdb->{marks}  || {},
		routes   => $ocdb->{routes} || {},
		tracks   => $ocdb->{tracks} || {},
		map      => $ocdb->{map}    || { fwd => {}, rev => {}, counter => 0 },
		commands => _commands(),
		icon_channel => _iconChannelState(),
		last_ingest  => ($last_ingest_json  ? eval { decode_json($last_ingest_json)  } : undef),
		last_results => ($last_results_json ? eval { decode_json($last_results_json) } : []),
	};
}


#------------------------------------------------------------
# resetState() - zero the spoke (the clear_e80 analog; POST /debug/reset)
#------------------------------------------------------------

sub resetState
{
	lock($state_lock);
	$ocdb_json        = '';
	$commands_json    = '[]';
	$last_ingest_json = '';
	$ocpn_dt       = 0;
	$navmate_dt    = 0;
	$last_recv_ts  = 0;
	$recv_count    = 0;
	# Clear the live symbol-channel state (re-evaluated on the next POST); the
	# on-disk icon library is DURABLE and deliberately NOT deleted here -- reset
	# is the clear_e80 analog for the spoke inventory, not the icon library.
	$icon_hash    = '';
	$want_icons   = 0;
	$icon_forced  = 0;
	$peer_protocol   = '';
	$peer_ver_warned = 0;
	return { ok => JSON::PP::true, reset => JSON::PP::true };
}


#------------------------------------------------------------
# protocol-version accessors (winOCPN surface, sec Versioning)
#------------------------------------------------------------

sub protocolVersion { return $PROTOCOL_VERSION; }

sub peerProtocolVersion
{
	lock($state_lock);
	return "$peer_protocol";
}


#------------------------------------------------------------
# symbol-channel accessors (harness driver + winOCPN, phase b)
#------------------------------------------------------------
# setWantIcons($on): force (or clear) the fetch request independent of cache
# state -- the harness POSTs /debug/want_icons to capture the full ocpn_icons[]
# even when the library is already cached.  Sticky until the icons actually
# arrive (see _processIconChannel).
sub setWantIcons
{
	my ($on) = @_;
	$on = defined($on) ? ($on ? 1 : 0) : 1;
	lock($state_lock);
	$want_icons  = $on;
	$icon_forced = $on;
	return { ok => JSON::PP::true, want_icons => ($want_icons ? JSON::PP::true : JSON::PP::false) };
}

sub iconChannelState
{
	lock($state_lock);
	return _iconChannelState();
}

# currentIconHash -- the live vocabulary hash ('' = none yet); winOCPN reloads
# its picker when this changes.
sub currentIconHash
{
	lock($state_lock);
	return "$icon_hash";
}

# loadIconLibrary($hash): the cached ocpn_icons[] record for a hash (defaults to
# the live icon_hash) -- winOCPN's symbol picker reads its images/names here.
sub loadIconLibrary
{
	my ($hash) = @_;
	lock($state_lock);
	$hash = $icon_hash if !defined $hash || $hash eq '';
	return _iconCacheLoad($hash);
}


#------------------------------------------------------------
# accessors (winOCPN / navOps, later milestones)
#------------------------------------------------------------

sub getMarks
{
	lock($state_lock);
	my $ocdb = _loadOcdb();
	return [ map { $ocdb->{marks}{$_} } sort keys %{$ocdb->{marks} || {}} ];
}

sub getRoutes
{
	lock($state_lock);
	my $ocdb = _loadOcdb();
	return [ map { $ocdb->{routes}{$_} } sort keys %{$ocdb->{routes} || {}} ];
}

sub getTracks
{
	lock($state_lock);
	my $ocdb = _loadOcdb();
	return [ map { $ocdb->{tracks}{$_} } sort keys %{$ocdb->{tracks} || {}} ];
}


#------------------------------------------------------------
# getSharedVersion() - a monotonic "ocdb changed" counter for the pane clock
#------------------------------------------------------------
# Bumped once per inventory POST (receiveInventory increments $recv_count).
# nmFrame's onIdle polls this and calls winOCPN->refresh() on change, exactly
# as the E80 pane refreshes off b_sock::getVersion.

sub getSharedVersion
{
	lock($state_lock);
	return $recv_count + 0;
}


#------------------------------------------------------------
# shapedDb() - the ocdb reshaped into the winTreeBase/navOps record form
#------------------------------------------------------------
# Central projection of the raw ocdb (marks/routes/tracks keyed by uuid) into
# the SAME record shape winE80/winFSH use, so the winOCPN pane, its feature
# builders, and navOps' snapshot/paste all consume one canonical form:
#   waypoints => { uuid => { uuid,name,comment,lat,lon,sym,color,guid,origin,
#                            icon,is_standalone,b } }   # b = OpenCPN B superset
#   routes    => { uuid => { uuid,name,comment,color,guid,origin,
#                            wpts=>[ {uuid,name,lat,lon} ] } }
#   tracks    => { uuid => { uuid,name,color,guid,origin,points=>[{lat,lon,ts}],cnt } }
# Route wpts are resolved against the marks map; sym is derived from the raw
# icon via the hub's icon<->sym table (navDB).  Pure route-vertices stay in
# waypoints (routes resolve them) but carry is_standalone=0 so callers can
# exclude them from "My Waypoints".

sub shapedDb
{
	my $marks  = getMarks()  || [];
	my $routes = getRoutes() || [];
	my $tracks = getTracks() || [];

	my %wps;
	for my $m (@$marks)
	{
		next if !defined $m->{uuid};
		$wps{$m->{uuid}} = {
			uuid          => $m->{uuid},
			name          => $m->{name}        // '',
			comment       => $m->{description}  // '',
			lat           => ($m->{lat} // 0) + 0,
			lon           => ($m->{lon} // 0) + 0,
			icon          => $m->{icon}         // '',
			sym           => navDB::symForIcon($m->{icon}),
			color         => 0,
			guid          => $m->{guid}         // '',
			origin        => $m->{origin}       // 'ocpn',
			is_standalone => defined($m->{is_standalone}) ? $m->{is_standalone} : 1,
			# the OpenCPN category-B superset, carried opaquely (winOCPN shows it
			# read-only, phase b; navOps persists it to spoke_shadow.data, phase c).
			b             => (ref($m->{b}) eq 'HASH') ? $m->{b} : {},
		};
	}

	my %rts;
	for my $r (@$routes)
	{
		next if !defined $r->{uuid};
		my @wpts;
		for my $p (sort { ($a->{position}//0) <=> ($b->{position}//0) } @{$r->{points} || []})
		{
			my $wp = $wps{$p->{wp_uuid} // ''};
			push @wpts, $wp ? {
				uuid => $wp->{uuid}, name => $wp->{name}, lat => $wp->{lat}, lon => $wp->{lon},
			} : { uuid => $p->{wp_uuid} // '', name => '', lat => 0, lon => 0 };
		}
		$rts{$r->{uuid}} = {
			uuid    => $r->{uuid},
			name    => $r->{name}        // '',
			comment => $r->{description}  // '',
			color   => 0,
			guid    => $r->{guid}         // '',
			origin  => $r->{origin}       // 'ocpn',
			wpts    => \@wpts,
			b       => (ref($r->{b}) eq 'HASH') ? $r->{b} : {},   # from/to/visible/active[R]
		};
	}

	my %trks;
	for my $t (@$tracks)
	{
		next if !defined $t->{uuid};
		my @pts = map { { lat => ($_->{lat}//0)+0, lon => ($_->{lon}//0)+0, ts => int($_->{ts}//0) } }
		          @{$t->{points} || []};
		$trks{$t->{uuid}} = {
			uuid   => $t->{uuid},
			name   => $t->{name}   // '',
			color  => 0,
			guid   => $t->{guid}   // '',
			origin => $t->{origin} // 'ocpn',
			points => \@pts,
			cnt    => scalar(@pts),
			b      => (ref($t->{b}) eq 'HASH') ? $t->{b} : {},   # from/to
		};
	}

	return { waypoints => \%wps, routes => \%rts, tracks => \%trks };
}


1;
