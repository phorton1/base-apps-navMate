#!/usr/bin/perl
#-------------------------------------------------------------------
# opencpn_rest.pm
#-------------------------------------------------------------------
# A standalone HTTPS "OpenCPN peer receiver" spike.
#
# It impersonates an OpenCPN instance just enough that a REAL OpenCPN
# can "Send to peer" a waypoint / route / track AT us as full-fidelity
# GPX -- which we DUMP so we can see exactly what OpenCPN sends on the
# wire (opencpn:style, gpxx:DisplayColor, the three link tables, etc).
#
# It implements the three endpoints of the OpenCPN REST receiver
# contract (source-verified in oe's peer_client.cpp / pincode.cpp):
#
#   GET  /api/get-version                  -> {"version":"5.12.4"}
#   GET  /api/ping?source=..&apikey=..     -> {"result":N}
#                                             5 = NewPinRequested
#                                             0 = NoError (paired)
#   POST /api/rx_object?source=..&apikey=..&force=1
#                                          -> body IS the GPX; save it;
#                                             reply {"result":0}
#
# Pincode (pincode.cpp:57):
#   api_key = substr( sha256_hex( sprintf("%04d",$pin) ), 0, 12 )
#
# The sender does NOT verify TLS (CURLOPT_SSL_VERIFYPEER/HOST = 0), so
# any self-signed cert works -- we reuse the inventory cert/key pair.
#
# Discovery (mDNS) is NOT needed: OpenCPN's Send-to-peer accepts a
# manually typed ip:port.  Point OpenCPN at  this-machine-ip:<PORT>.
#
# RUN (from cmd.exe, in this folder or anywhere):
#     perl _experiments\opencpn_rest.pm             # listens on 8444
#     perl _experiments\opencpn_rest.pm 9000        # override the port
#
# 'use lib' below puts C:\base on @INC so the Pub:: tree resolves.
#-------------------------------------------------------------------

package ocpnPeerReceiver;
use strict;
use warnings;
use lib '/base';
use threads;
use threads::shared;
use Digest::SHA qw(sha256_hex);
use Pub::Utils;
use Pub::HTTP::ServerBase;
use Pub::HTTP::Response;
use base qw(Pub::HTTP::ServerBase);


#---------------------------------------
# configuration
#---------------------------------------

# default 8444, NOT 8443 -- OpenCPN's own REST server binds 8443, so on the
# same machine 8443 would collide and we'd fail to listen.  Override via ARGV.

my $PORT       = $ARGV[0] || 8444;
my $DUMP_DIR   = 'C:/_temp/base-apps-navMate';
my $SSL_CERT   = 'C:/base_data/_ssl/inventory.crt';
my $SSL_KEY    = 'C:/base_data/_ssl/inventory.key';

# PROMISCUOUS: skip the PIN handshake entirely -- /api/ping always
# answers NoError(0) so OpenCPN proceeds straight to sending the object.
# This is the fastest path to "just show me what OpenCPN sends".
# Set to 0 to exercise the real 4-digit PIN pairing flow instead.

my $PROMISCUOUS = 1;

# The PIN we "display" for OpenCPN's user to type (PROMISCUOUS==0 only).
# Fixed so we can precompute the expected api_key without any RNG.

my $PIN          = 1234;
my $EXPECTED_KEY = substr( sha256_hex( sprintf("%04d",$PIN) ), 0, 12 );

# NewPinRequested / NoError result codes (inferred from oe's switch order)

my $RESULT_NO_ERROR         = 0;
my $RESULT_NEW_PIN_REQUESTED = 5;

# the version string we claim (any >= 5.9 satisfies the sender)

my $CLAIM_VERSION = '5.12.4';

my $rx_count = 0;		# number of objects received this run


#---------------------------------------
# constructor
#---------------------------------------

sub new
{
	my ($class) = @_;
	my $this = $class->SUPER::new({

		HTTP_PORT           => $PORT,

		HTTP_SSL            => 1,
		HTTP_SSL_CERT_FILE  => $SSL_CERT,
		HTTP_SSL_KEY_FILE   => $SSL_KEY,

		# nominal, chatty debug: one line per request/response

		HTTP_DEBUG_SERVER   => 0,
		HTTP_DEBUG_REQUEST  => 0,
		HTTP_DEBUG_RESPONSE => 1,

		# we serve no static files -- every request falls through
		# to our handle_request() below

		HTTP_DEFAULT_LOCATION => '',
	});

	bless $this,$class;
	return $this;
}


#---------------------------------------
# a literal-JSON response
#---------------------------------------
# Passing a SCALAR string (not a ref) with content_type 'application/json'
# is delivered VERBATIM -- Response->new only runs my_encode_json() on a
# HASH/ARRAY ref (Response.pm:230).  So these tiny fixed bodies bypass
# Pub's encoder, which would otherwise emit &#NNN; / "1" booleans that the
# sender's JSON parser would choke on.

sub json_literal
{
	my ($request,$str) = @_;
	return Pub::HTTP::Response->new($request,$str,200,'application/json');
}


#---------------------------------------
# handle_request
#---------------------------------------

sub handle_request
{
	my ($this,$client,$request) = @_;

	my $uri    = $request->{uri};
	my $method = $request->{method};
	my $params = $request->{params} || {};

	display(0,0,"==== $method $uri ====");
	display_hash(0,1,"params",$params) if %$params;

	#-------------------------------------------
	# GET /api/get-version
	#-------------------------------------------

	if ($uri eq '/api/get-version')
	{
		display(0,1,"-> version $CLAIM_VERSION");
		return json_literal($request,"{\"version\":\"$CLAIM_VERSION\"}");
	}

	#-------------------------------------------
	# GET /api/ping
	#-------------------------------------------

	elsif ($uri eq '/api/ping')
	{
		if ($PROMISCUOUS)
		{
			display(0,1,"-> PROMISCUOUS NoError(0) (pairing skipped)");
			return json_literal($request,
				"{\"result\":$RESULT_NO_ERROR,\"version\":\"$CLAIM_VERSION\"}");
		}

		my $key = $params->{apikey} || '';
		if ($key eq $EXPECTED_KEY)
		{
			display(0,1,"-> key MATCHES -> NoError(0)");
			return json_literal($request,
				"{\"result\":$RESULT_NO_ERROR,\"version\":\"$CLAIM_VERSION\"}");
		}

		warning(0,1,"-> unknown key '$key' -> NewPinRequested($RESULT_NEW_PIN_REQUESTED)");
		warning(0,1,"   *** TYPE THIS PIN INTO OpenCPN:  ".sprintf("%04d",$PIN)." ***");
		return json_literal($request,
			"{\"result\":$RESULT_NEW_PIN_REQUESTED,\"version\":\"$CLAIM_VERSION\"}");
	}

	#-------------------------------------------
	# POST /api/rx_object  -- the payload
	#-------------------------------------------

	elsif ($uri eq '/api/rx_object')
	{
		my $gpx = $request->{content};
		$gpx = '' if !defined($gpx);
		$rx_count++;

		my @t = localtime();
		my $stamp = sprintf("%04d%02d%02d_%02d%02d%02d",
			$t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
		my $filename = "$DUMP_DIR/ocpn_rx_${stamp}_$rx_count.gpx";

		display(0,1,"RECEIVED object #$rx_count  ".length($gpx)." bytes");
		printVarToFile(1,$filename,$gpx,1);
		display(0,1,"saved -> $filename");

		# echo the raw GPX to the console so it is right here in the log

		display(0,1,"---------------- BEGIN GPX ----------------");
		print $gpx."\n";
		display(0,1,"----------------- END GPX -----------------");

		return json_literal($request,"{\"result\":$RESULT_NO_ERROR}");
	}

	#-------------------------------------------
	# anything else -- log it loudly, we want to
	# know about every request OpenCPN makes
	#-------------------------------------------

	warning(0,0,"UNHANDLED $method $uri");
	return json_literal($request,"{\"result\":$RESULT_NO_ERROR}");
}



#---------------------------------------
# main
#---------------------------------------

package main;
use Pub::Utils;		# re-import display()/display_hash()/etc into package main

# NOTE: $PORT, $SSL_CERT, $DUMP_DIR, $PROMISCUOUS, $PIN above are file-scoped
# 'my' lexicals -- a 'package' statement does NOT open a new lexical scope, so
# they remain directly visible here (do NOT package-qualify them).

display(0,0,"-------------------------------------------------------");
display(0,0,"opencpn_rest starting on https port $PORT");
display(0,0,"  cert  = $SSL_CERT");
display(0,0,"  dump  = $DUMP_DIR");
display(0,0,"  mode  = ".($PROMISCUOUS ?
	"PROMISCUOUS (no pairing)" :
	"PIN pairing (pin=".sprintf("%04d",$PIN).")"));
display(0,0,"-------------------------------------------------------");
display(0,0,"In OpenCPN: Send to peer -> add peer at  <this-ip>:$PORT");
display(0,0,"Ctrl-C to stop.");
display(0,0,"-------------------------------------------------------");

my $server = ocpnPeerReceiver->new();
$server->start();

# keep the main thread alive; the server runs on its own thread(s)

while (1)
{
	sleep(1);
}


1;
