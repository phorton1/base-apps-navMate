#!/usr/bin/perl
#---------------------------------------------
# _testOEServer.pm   (leading _ = test infra, like _fixtures / _results)
#---------------------------------------------
# Headless harness for the OpenCPN (oESeries) spoke.  A THIN Pub::HTTP server
# that mounts the REAL /api/ocpn endpoint over the REAL navOCPN + nmOCPNDirectOps
# + navIdentity code -- it re-implements NOTHING, so passing it proves the actual
# serialization / ingest / reconcile, not a mock.  No wx, no NET stack, no
# canonical-DB writes.
#
# Run:   /c/Perl/bin/perl.exe -I/base _testOEServer.pm --port 9999
#        (capture stdout+stderr to a file; Pub::Utils emits console escapes)
#
# Endpoints:
#   GET  /api/ocpn            - poll view { ok, navmate_dt, ocpn_dt, commands }
#   GET  /api/ocpn?dump=1     - structured ocdb readback (asserts read this)
#   POST /api/ocpn            - ingest a sec-2A inventory into the in-memory ocdb
#   POST /debug/reset         - zero the spoke (clear_e80 analog)
#   GET  /debug/project?limit=N - project N real dev-DB waypoints (READ-ONLY) to a
#                               ready-to-POST sec-2A inventory { dt, marks, ... }
#   GET  /debug/health        - { ok, port, db_path, db_ok }
#
# Two modes (json_and_test_oe.md Goal B):
#   Mode 1 (no OpenCPN, mine): I POST fixtures / projected rows and read ?dump=1.
#   Mode 2 (real plugin, bench): the oESeries plugin polls this at 127.0.0.1:port.

package testOEServer;
use strict;
use warnings;
use threads;
use threads::shared;
use Getopt::Long;
use DBI;
use JSON::PP;
use Pub::Utils;
use Pub::HTTP::Response qw(json_response);
use n_defs;
use navPrefs qw(init_prefs getPref $PREF_DATABASE_PATH);
use navDB;
use navIdentity;
use nmOCPNDirectOps;
use navOCPN;
use base qw(Pub::HTTP::ServerBase);

my $SQLITE_OPEN_READONLY = 0x00000001;   # DBD::SQLite OPEN_READONLY


#---------------------------------------------
# request dispatch
#---------------------------------------------

sub handle_request
{
	my ($this, $client, $request) = @_;
	my $uri    = $request->{uri}    // '';
	my $method = $request->{method} // 'GET';
	my $params = $request->{params} || {};

	if ($uri eq '/api/ocpn')
	{
		if ($method eq 'POST')
		{
			my $h = $request->getPostJSON();
			return navOCPN::jsonResponse($request, { ok => JSON::PP::false, error => 'missing or invalid JSON body' }) if !$h;
			return navOCPN::jsonResponse($request, navOCPN::receiveInventory($h));
		}
		return navOCPN::jsonResponse($request, $params->{dump}
			? navOCPN::dumpState()
			: navOCPN::pollView());
	}
	elsif ($uri eq '/debug/reset')
	{
		return navOCPN::jsonResponse($request, navOCPN::resetState());
	}
	elsif ($uri eq '/debug/enqueue')
	{
		# M3 outbound driver: enqueue hub->plugin commands + bump navmate_dt, so
		# Mode-1 can exercise the commands[] path without the real db_version
		# counter.  Body: { commands:[<command>...] } or a single command object.
		my $h = $request->getPostJSON();
		return navOCPN::jsonResponse($request, { ok => JSON::PP::false, error => 'need JSON body' }) if !$h;
		my $cmds = (ref($h) eq 'HASH' && ref($h->{commands}) eq 'ARRAY') ? $h->{commands} : $h;
		return navOCPN::jsonResponse($request, navOCPN::enqueueCommands($cmds));
	}
	elsif ($uri eq '/debug/project')
	{
		my $limit = int($params->{limit} // 10);
		$limit = 1   if $limit < 1;
		$limit = 500 if $limit > 500;
		return navOCPN::jsonResponse($request, _projectFromDB($limit));
	}
	elsif ($uri eq '/debug/health')
	{
		my $path = getPref($PREF_DATABASE_PATH) // '';
		return navOCPN::jsonResponse($request, {
			ok      => JSON::PP::true,
			port    => $this->{HTTP_PORT} + 0,
			db_path => $path,
			db_ok   => ($path && -f $path) ? JSON::PP::true : JSON::PP::false,
		});
	}
	return navOCPN::jsonResponse($request, { ok => JSON::PP::false, error => "unknown endpoint: $uri" });
}


#---------------------------------------------
# _projectFromDB($limit) - real dev-DB waypoints -> a sec-2A inventory
#---------------------------------------------
# READ-ONLY: opens the dev navMate.db with SQLITE_OPEN_READONLY so the harness
# can never mutate the live database.  Best-effort: any failure returns an error
# object (Mode-1 core asserts do not depend on this; they drive fixtures).

sub _projectFromDB
{
	my ($limit) = @_;
	my $path = getPref($PREF_DATABASE_PATH);
	return { ok => JSON::PP::false, error => 'no DATABASE_PATH' } if !$path;
	return { ok => JSON::PP::false, error => "db not found: $path" } if !-f $path;

	my $dbh = eval {
		DBI->connect("dbi:SQLite:dbname=$path", '', '', {
			RaiseError        => 0,
			PrintError        => 0,
			sqlite_open_flags => $SQLITE_OPEN_READONLY,
		});
	};
	return { ok => JSON::PP::false, error => "db open failed: ".($DBI::errstr // '?') } if !$dbh;

	my $rows = eval {
		$dbh->selectall_arrayref(
			"SELECT uuid, name, comment, lat, lon, created_ts ".
			"FROM waypoints ORDER BY uuid LIMIT ?",
			{ Slice => {} }, $limit);
	};
	my $err = $dbh->errstr;
	$dbh->disconnect();
	return { ok => JSON::PP::false, error => "query failed: ".($err // '?') } if !$rows;

	my $marks = nmOCPNDirectOps::projectDBMarksToWire($rows, undef);
	return {
		ok          => JSON::PP::true,
		dt          => time(),
		marks       => $marks,
		routes      => [],
		tracks      => [],
		results     => [],
		source_rows => scalar(@$rows),
	};
}


#---------------------------------------------
# main
#---------------------------------------------

my $port = 9999;
GetOptions('port=i' => \$port) or die "bad args\n";

setStandardTempDir('navMate');
setStandardDataDir('navMate');
init_prefs();

my $server = testOEServer->new({
	HTTP_PORT           => $port,
	HTTP_MAX_THREADS    => 4,
	HTTP_KEEP_ALIVE     => 0,
	HTTP_DEBUG_QUIET_RE => '\/(api\/ocpn|debug)',
});

display(0, 0, "testOEServer: listening on 127.0.0.1:$port (db=".(getPref($PREF_DATABASE_PATH)//'?').")");
$server->start();

# stay alive; the detached server + worker threads do the work
while (1) { sleep(1); }

1;
