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
use Pub::Utils qw(display warning error);
use Pub::HTTP::Response;
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
# pollView() - the version view navMate returns on every GET / POST
#------------------------------------------------------------
# ok is a JSON BOOL (sec 2A: "ok is a JSON bool everywhere"); commands is
# ALWAYS present, [] when empty.

sub pollView
{
	lock($state_lock);
	return {
		ok         => JSON::PP::true,
		navmate_dt => $navmate_dt + 0,
		ocpn_dt    => $ocpn_dt + 0,
		commands   => _commands(),
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

	my $ocdb    = _loadOcdb();
	my $summary = nmOCPNDirectOps::ingestInventory($ocdb, $body);
	_storeOcdb($ocdb);
	$last_ingest_json = encode_json($summary);   # persist marks_in/distinct for readback

	# Consume results[]: an ok ack retires the matching pending command (by
	# guid+op).  This does NOT bump navmate_dt -- retiring an ack is not a new
	# canonical mutation, and neither is the ingest above -- so an echoed object
	# reappearing in marks[] can never re-mint a command (the echo invariant).
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
	return { ok => JSON::PP::true, reset => JSON::PP::true };
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


1;
