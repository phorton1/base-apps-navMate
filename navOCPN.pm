#------------------------------------------------------------------------
# navOCPN.pm
#------------------------------------------------------------------------
# navMate's IN-MEMORY representation of the OpenCPN spoke (the oESeries plugin).
# navMate is the HTTP SERVER; oESeries is a polling HTTP CLIENT.  This module sits
# under the /api/ocpn endpoint in navServer.pm.
#
# RUDIMENTARY v0 (2026-07-04): no version-number scheme yet.  It can:
#   - remember the DT the oESeries client last sent WITH a real inventory,
#   - regurgitate that DT (plus a placeholder navMate DT of 0) on every poll, and
#   - stash the last inventory payload for readback / verification.
# In-memory only -- nothing is persisted to navMate.db (a live spoke projection,
# like navFSH / winE80).  Only a user PASTE would move data into the canonical DB
# (not built here).
#
# Two DTs of the sync design (see C:\src\OpenCPN\oESeries\readme.md sec 4):
#   ocpn_dt    - the DT the client last sent with a real inventory (0 = none yet).
#                Remembered + echoed so the client can detect steady state.
#   navmate_dt - navMate's own version token.  HARDCODED 0 (epoch / 1970) until the
#                deferred db_version gate is built (navMate memory
#                navmate_db_version_counter.md); there is no navMate->OpenCPN push
#                direction yet.

package navOCPN;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display warning error);

our $dbg_ocpn = 0;			# 0 = log received inventories; raise to quiet

our $ocpn_dt      :shared = 0;		# client DT last received WITH an inventory
our $navmate_dt   :shared = 0;		# navMate's token: always 0 until the db_version gate
our $last_payload :shared = '';		# last inventory POST body (JSON text)
our $last_recv_ts :shared = 0;
our $recv_count   :shared = 0;


#------------------------------------------------------------
# pollView() - the version view navMate returns on every call
#------------------------------------------------------------

sub pollView
{
	my ($odt, $ndt);
	{ lock($ocpn_dt); $odt = $ocpn_dt; $ndt = $navmate_dt; }
	return { ok => 1, navmate_dt => $ndt, ocpn_dt => $odt };
}


#------------------------------------------------------------
# receiveInventory($body) - oESeries sent an inventory hashref
#     { dt => <client dt>, waypoints => [ ... ] }
# Remember the client dt, stash the payload, log it, return the poll view.
#------------------------------------------------------------

sub receiveInventory
{
	my ($body) = @_;
	my $dt  = defined($body->{dt}) ? $body->{dt} : 0;
	my $wps = (ref($body->{waypoints}) eq 'ARRAY') ? $body->{waypoints} : [];
	my $enc = eval { encode_json($body) } // '';

	{
		lock($ocpn_dt);
		$ocpn_dt      = $dt;
		$last_payload = $enc;
		$last_recv_ts = time();
		$recv_count++;
	}

	display($dbg_ocpn, 0, sprintf(
		"navOCPN: received inventory dt=%s (count=%d waypoints=%d)",
		$dt, $recv_count, scalar(@$wps)));

	return pollView();
}


#------------------------------------------------------------
# dumpState() - full readback for verification (GET /api/ocpn?dump=1)
#------------------------------------------------------------

sub dumpState
{
	my ($odt, $ndt, $payload, $ts, $cnt);
	{
		lock($ocpn_dt);
		$odt     = $ocpn_dt;
		$ndt     = $navmate_dt;
		$payload = $last_payload;
		$ts      = $last_recv_ts;
		$cnt     = $recv_count;
	}
	my $h = ($payload && length $payload) ? eval { decode_json($payload) } : undef;
	return {
		ok         => 1,
		navmate_dt => $ndt,
		ocpn_dt    => $odt,
		recv_count => $cnt,
		last_recv  => $ts,
		payload    => $h,
	};
}


1;
