#!/usr/bin/perl
#-------------------------------------------------------------------
# opencpn_push.pm
#-------------------------------------------------------------------
# Push a GPX file INTO a running OpenCPN via its REST receiver
# (the navMate -> OpenCPN "outbound" direction; navMate is the CLIENT).
#
# This is the direction that is actually robust: we drive the whole
# exchange to OpenCPN's own server on 127.0.0.1:8443 -- none of the
# Send-to-peer GUI / mDNS / Portable- mess applies.
#
# UPSERT SEMANTICS (verified in rest_server.cpp HandleRoute/Track/Waypoint):
# a POST with force=1 does REPLACE-by-GUID -- if the GUID already exists
# OpenCPN deletes the old object and inserts the incoming one. NO duplicate,
# GUID preserved, full fidelity (rebuilt from the full GPX, not a lossy
# struct). So re-pushing the same GPX is idempotent; pushing an edited GPX
# (same GUIDs) updates in place.
#
# PAIRING (one-time): OpenCPN's receiver requires a pincode pair per source.
#   api_key = substr( sha256_hex( sprintf("%04d",$pin) ), 0, 12 )   (>=5.9)
# Flow is two steps the first time (run the .pm directly; the shell binds it to perl):
#   1)  _experiments\opencpn_push.pm <file.gpx>
#         -> triggers OpenCPN to POP A PIN DIALOG showing a 4-digit PIN
#   2)  _experiments\opencpn_push.pm <file.gpx> <PIN>
#         -> pairs, caches the key, and pushes
# After that the key is cached, so plain `... <file.gpx>` just pushes.
#
# TLS: OpenCPN's client sets no-verify, and so do we (curl -k) -- any cert.
#-------------------------------------------------------------------

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

my $HOST    = '127.0.0.1:8443';                          # OpenCPN's own REST server (8444 if OpenCPN is "portable")
my $SOURCE  = 'navMate';                                 # OpenCPN keys the stored api_key by this source name
my $KEYFILE = 'C:/_temp/base-apps-navMate/opencpn_push_key.txt';
my $DUMMY   = '0123456789abc';                           # >=10 chars -> OpenCPN stores the modern Hash(pin), not CompatHash

my $gpx = $ARGV[0];
my $pin = $ARGV[1];                                       # optional; supply on the pairing step

die "usage: opencpn_push.pm <file.gpx> [pin]\n" if !$gpx;
die "no such file: $gpx\n" if !-f $gpx;


#---------------------------------------
# helpers
#---------------------------------------

sub curl_get
{
    my ($path) = @_;
    return `curl -sk --max-time 8 "https://$HOST$path"`;
}

sub result_of
{
    my ($json) = @_;
    return $json =~ /"result"\s*:\s*(\d+)/ ? $1 : undef;
}

sub key_for_pin
{
    my ($p) = @_;
    return substr( sha256_hex( sprintf("%04d",$p) ), 0, 12 );
}

sub load_key
{
    return '' if !open(my $fh,'<',$KEYFILE);
    my $k = <$fh>;
    close $fh;
    $k = '' if !defined $k;
    $k =~ s/\s+//g;
    return $k;
}

sub save_key
{
    my ($k) = @_;
    if (open(my $fh,'>',$KEYFILE)) { print $fh $k; close $fh; }
}


#---------------------------------------
# 1) sanity: version
#---------------------------------------

my $ver = curl_get("/api/get-version");
$ver = '' if !defined $ver;
die "no response from OpenCPN at $HOST (is it running with the REST server enabled?)\n"
    if $ver !~ /version/;
print "get-version: $ver\n";


#---------------------------------------
# 2) obtain a usable api key
#---------------------------------------

my $key = load_key();

if (defined $pin)
{
    # PAIR: user has read the PIN off OpenCPN's dialog (from a prior trigger run).
    # OpenCPN already stored Hash(pin) for our source; prove we know it.
    $key = key_for_pin($pin);
    my $r = result_of(curl_get("/api/ping?source=$SOURCE&apikey=$key"));
    if (defined($r) && $r == 0)
    {
        save_key($key);
        print "paired (pin $pin) -> key $key  [cached]\n";
    }
    else
    {
        die "pairing failed for pin '$pin' (result=".(defined $r ? $r : '?').").\n".
            "Run without a pin first to make OpenCPN show a fresh PIN, then re-run with THAT pin.\n";
    }
}
elsif (!$key)
{
    # TRIGGER: no cached key and no pin -> ping with the dummy to make OpenCPN
    # generate a pincode and pop its dialog. Then the user re-runs with the pin.
    my $r = result_of(curl_get("/api/ping?source=$SOURCE&apikey=$DUMMY"));
    if (defined($r) && $r == 0)
    {
        $key = $DUMMY;                                    # already paired to the dummy somehow; just use it
        print "already paired (dummy)\n";
    }
    else
    {
        print "\nOpenCPN should now be showing a PIN dialog (result=".(defined $r ? $r : '?').").\n";
        print "Read the 4-digit PIN, then re-run:\n";
        print "    _experiments\\opencpn_push.pm \"$gpx\" <PIN>\n";
        exit 0;
    }
}
else
{
    print "using cached key $key\n";
}


#---------------------------------------
# 3) push the GPX (force=1 -> replace-by-GUID)
#---------------------------------------

my $url  = "https://$HOST/api/rx_object?source=$SOURCE&apikey=$key&force=1";
my $resp = `curl -sk --max-time 20 -X POST -H "Content-Type: application/gpx+xml" --data-binary "\@$gpx" "$url"`;
$resp = '' if !defined $resp;
print "rx_object: $resp\n";

my $rr = result_of($resp);
if (defined($rr) && $rr == 0)
{
    print "PUSH OK  (force=1 => replace-by-GUID, no duplicate)\n";
}
elsif (defined($rr) && $rr == 5)
{
    unlink $KEYFILE;                                      # stale key -> drop cache so next run re-pairs
    print "PUSH needs pairing (result=5). Cached key cleared.\n";
    print "Re-run without a pin to get a fresh PIN, then with the PIN.\n";
}
else
{
    print "PUSH result=".(defined $rr ? $rr : '?')." (see rx_object body above)\n";
}
