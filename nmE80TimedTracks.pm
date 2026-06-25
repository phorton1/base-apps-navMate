#!/usr/bin/perl
#-------------------------------------------------------------------------
# nmE80TimedTracks.pm
#-------------------------------------------------------------------------
# navMate-side orchestration for the mod003 "timed track recording" toggle on a
# live E80.  mod003 firmware makes the on-device track recorder stamp each track
# point with a wall-clock time + true depth, UNLESS a single DATABASE item is set:
#
#     fid 0x05ff0001, enc 0x0054 (BOOL8) -- absent/0 = timed (default), nonzero = stock
#
# (See Pub::Ray e80_firmware/deployment/mod003.md, "The toggle".)  The mod only
# READS the item; navMate is the writer.  This module wraps Pub::Ray::NET::d_DB's
# blocking getItem/putItem so the wx main thread never blocks:
#
#   - interactive (menu): doToggle -> SingleChoiceDialog -> worker thread behind a
#     Pub::WX::ProgressDialog -> onIdle raises the result (mirrors nmE80DirectOps).
#   - headless (/api):    apiGet / apiSet run the blocking calls directly on the
#     HTTP thread, no dialogs.
#
# The DB service ($Pub::Ray::NET::d_DB::self_db) is declared :shared, so a spawned
# worker / the HTTP thread may drive it -- with the single-in-flight guard below
# (d_DB allows only one call in flight per socket).  navMate enables the service
# (db => 1) and suppresses its auto-subscription (HOW_INIT_DB = NONE) in navMate.pm.
#
# The UX is meaningful only on firmware that can record timed tracks, so the menu
# command and the interactive entry are gated on v5.73+ (from the RAYDP IDENT).

package nmE80TimedTracks;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils qw(display getAppFrame);
use Pub::WX::Dialogs;
use Pub::Ray::NET::c_RAYDP;
use Pub::Ray::NET::d_DB;

my $dbg = 0;

# the mod003 timed-track toggle DATABASE item
my $TIMED_FID   = 0x05ff0001;
my $TIMED_ENC   = 0x0054;        # BOOL8
my $MIN_VERSION = 5.73;          # earliest firmware that records timed tracks
my $DLG_TITLE   = 'Timed Track Recording';

# one d_DB call in flight at a time (the service allows only one per socket);
# also enforces the single-ProgressDialog discipline for the interactive path.
my $busy :shared = 0;

# interactive result pending: { progress, frame, want_value }.  Main-thread only;
# nmFrame::onIdle calls onIdle() which raises the result once the dialog closes.
my $pending;


#-------------------------------------------------------
# guard
#-------------------------------------------------------

sub _acquire
{
    lock($busy);
    return 0 if $busy;
    $busy = 1;
    return 1;
}

sub _release
{
    lock($busy);
    $busy = 0;
}

sub _isBusy
{
    lock($busy);
    return $busy;
}


#-------------------------------------------------------
# service + version
#-------------------------------------------------------

sub _db
    # The framework-connected DATABASE service (set by d_DB::init as $self_db,
    # declared :shared so a worker / HTTP thread may call getItem/putItem on it).
{
    return $Pub::Ray::NET::d_DB::self_db;
}


sub connectedUnitVersion
    # The firmware version (e.g. 5.73) of the E80 the DB service is connected to,
    # read from the RAYDP IDENT device record, or undef if there is no connected
    # DB unit.  With a single unit (the common case) the lone device record is used;
    # with several, the record is matched by the service's ip.
{
    my $db = _db();
    return undef if !$db || !$db->{connected};
    my $raydp = Pub::Ray::NET::c_RAYDP::getRayDP();
    return undef if !$raydp;
    my $devices = $raydp->{devices} || {};
    my @devs = values %$devices;
    return undef if !@devs;
    return $devs[0]->{version} if @devs == 1;
    my $ip = $db->{ip} // '';
    for my $dev (@devs)
    {
        return $dev->{version} if ($dev->{ip} // '') eq $ip;
    }
    return undef;
}


sub available
    # True iff the DB service is connected to a v5.73+ unit -- the only firmware
    # that records timed tracks, so the only case where the toggle is meaningful.
    # Used by nmFrame to enable/disable the menu command.
{
    my $v = connectedUnitVersion();
    return (defined($v) && $v >= $MIN_VERSION) ? 1 : 0;
}


#-------------------------------------------------------
# the d_DB transaction (read-before-write, confirm-by-read)
#-------------------------------------------------------

sub _readValue
    # ($value, $uuid, $err): the toggle's current value (0 if the item is absent,
    # which the firmware treats as the timed default) and the source uuid to feed
    # back to putItem for an UPDATE (undef if absent => a mint).  $err set on a
    # transport failure.  BLOCKS -- call off the wx main thread.
{
    my ($db) = @_;
    my $rec = $db->getItem($TIMED_FID);
    return (undef, undef, "DB read failed (no reply)") if defined($rec) && !ref($rec);
    return (0, undef, undef) if !defined($rec);             # not found => absent => 0 (timed)
    return ($rec->{value} // 0, $rec->{uuid}, undef);
}


sub _applyToggle
    # Worker core: set the toggle to $want_value (0 = enable timed, nonzero = stock),
    # read-before-write then confirm-by-read.  Writes the outcome into the (shared)
    # $progress hash: {error} on failure, else {result_enabled} (+ {result_nochange}
    # when it already held the wanted state).  BLOCKS -- call off the wx main thread.
{
    my ($want_value, $progress) = @_;
    my $db = _db();
    if (!$db || !$db->{connected})
    {
        $progress->{error} = "E80 DATABASE service is not connected";
        return;
    }

    my ($cur, $uuid, $err) = _readValue($db);
    if ($err)
    {
        $progress->{error} = $err;
        return;
    }

    my $want_enabled = ($want_value == 0) ? 1 : 0;
    my $cur_enabled  = ($cur == 0) ? 1 : 0;

    if ($cur_enabled == $want_enabled)
    {
        # already in the wanted state -- nothing to write (absent == 0 == enabled)
        $progress->{result_enabled}  = $want_enabled;
        $progress->{result_nochange} = 1;
        return;
    }

    # read-before-write: pass the existing source uuid to UPDATE it; omit (undef)
    # to MINT (the E80 assigns its own uuid on a first write).  Unacknowledged.
    if (!$db->putItem($TIMED_FID, $TIMED_ENC, $want_value, 1, $uuid))
    {
        $progress->{error} = "DB write failed";
        return;
    }

    # confirm by reading the value back (putItem is silent on success)
    my ($now, $now_uuid, $err2) = _readValue($db);
    if ($err2)
    {
        $progress->{error} = "write not confirmed: $err2";
        return;
    }
    my $now_enabled = ($now == 0) ? 1 : 0;
    if ($now_enabled != $want_enabled)
    {
        $progress->{error} = "write did not take (E80 still reads "
            . ($now_enabled ? "ENABLED" : "DISABLED") . ")";
        return;
    }
    display($dbg, 0, "nmE80TimedTracks: set timed-track recording -> "
        . ($now_enabled ? "ENABLED" : "DISABLED"));
    $progress->{result_enabled} = $now_enabled;
}


#-------------------------------------------------------
# interactive entry (menu)
#-------------------------------------------------------

sub doToggle
{
    my ($frame) = @_;
    $frame ||= getAppFrame();

    if (Pub::WX::ProgressDialog::isActive() || _isBusy())
    {
        okDialog($frame, "Another E80 operation is in progress -- please wait.", $DLG_TITLE);
        return;
    }

    my $db  = _db();
    my $ver = connectedUnitVersion();
    if (!$db || !$db->{connected} || !defined($ver))
    {
        okDialog($frame, "No E80 is connected on the DATABASE service.", $DLG_TITLE);
        return;
    }
    if ($ver < $MIN_VERSION)
    {
        okDialog($frame,
            "Timed-track recording requires the custom firmware v5.73 or later.\n\n"
            . "The connected E80 reports v$ver, which cannot record timed tracks.",
            $DLG_TITLE);
        return;
    }

    my @choices = (
        "Enable  -- the E80 stamps each track point with date/time and depth",
        "Disable -- the E80 records stock tracks (position + depth, no time)");
    my $dlg = Wx::SingleChoiceDialog->new($frame,
        "Timed-track recording on the connected E80 (v$ver):", $DLG_TITLE, \@choices);
    my $sel = ($dlg->ShowModal() == wxID_OK) ? $dlg->GetSelection() : -1;
    $dlg->Destroy();
    return if $sel < 0;

    my $want_value = ($sel == 0) ? 0 : 1;       # enable => 0 (timed), disable => 1 (stock)
    _launch($frame, $want_value);
}


sub _launch
    # Spawn the worker that runs the blocking d_DB transaction behind a
    # ProgressDialog, and arm the result that nmFrame::onIdle raises on close.
{
    my ($frame, $want_value) = @_;
    return if !_acquire();

    my $progress = Pub::WX::ProgressDialog::newProgressData(0, 1);   # workers=1: close on worker-done
    $progress->{active} = 1;

    my $dlg = Pub::WX::ProgressDialog->new($frame, "Updating E80 timed-track setting...", 1, $progress);
    if (!$dlg)
    {
        _release();
        return;
    }

    $pending = { progress => $progress, frame => $frame, want_value => $want_value };

    threads->create(sub {
        _applyToggle($want_value, $progress);
        $progress->{workers} = 0;       # success -> dialog auto-closes; {error} -> terminal
        _release();
    })->detach();
}


sub onIdle
    # Called from nmFrame::onIdle.  Raises the result once the ProgressDialog has
    # fully closed (mirrors nmE80DirectOps::onIdle).
{
    my ($frame) = @_;
    return if !$pending;
    return if Pub::WX::ProgressDialog::isActive();

    my $p = $pending;
    $pending = undef;
    return if $nmDialogs::suppress_confirm;

    my $progress = $p->{progress};
    my $f = $p->{frame} || $frame;
    if ($progress && ($progress->{error} // ''))
    {
        okDialog($f, "Could not change timed-track recording:\n\n$progress->{error}", $DLG_TITLE);
        return;
    }

    my $state = ($progress && $progress->{result_enabled}) ? "ENABLED" : "DISABLED";
    my $msg   = ($progress && $progress->{result_nochange})
        ? "Timed-track recording was already $state on the E80."
        : "Timed-track recording is now $state on the E80.";
    okDialog($f, $msg, $DLG_TITLE);
}


#-------------------------------------------------------
# headless entry (/api/timed_tracks)
#-------------------------------------------------------

sub apiGet
    # Read the current state, blocking on the calling (HTTP) thread.
    # { connected => 1, version, value, enabled } or { error }.
{
    return { error => 'another E80 operation is in progress' } if !_acquire();

    my $db  = _db();
    my $ver = connectedUnitVersion();
    if (!$db || !$db->{connected})
    {
        _release();
        return { error => 'E80 DATABASE service is not connected' };
    }

    my ($value, $uuid, $err) = _readValue($db);
    _release();
    return { error => $err } if $err;
    return {
        connected => 1,
        version   => $ver,
        value     => $value,
        enabled   => (($value == 0) ? 1 : 0),       # 0/absent => timed enabled
    };
}


sub apiSet
    # Set the toggle, blocking on the calling (HTTP) thread, no dialogs.
    # $enabled: 1 => timed recording ON (fid value 0), 0 => OFF / stock (value 1).
    # Gated on v5.73+ so we never mint the item on firmware that ignores it.
    # { ok => 1, version, enabled, nochange } or { error }.
{
    my ($enabled) = @_;
    return { error => 'missing enabled (0|1)' } if !defined($enabled);

    my $ver = connectedUnitVersion();
    return { error => 'E80 DATABASE service is not connected' } if !defined($ver);
    return { error => "connected E80 is v$ver; timed tracks need v$MIN_VERSION+" }
        if $ver < $MIN_VERSION;

    return { error => 'another E80 operation is in progress' } if !_acquire();
    my $want_value = $enabled ? 0 : 1;
    my $progress = {};
    _applyToggle($want_value, $progress);
    _release();

    return { error => $progress->{error} } if $progress->{error};
    return {
        ok       => 1,
        version  => $ver,
        enabled  => ($progress->{result_enabled} // 0),
        nochange => ($progress->{result_nochange} ? 1 : 0),
    };
}


1;
