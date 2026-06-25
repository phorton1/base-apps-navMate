#!/usr/bin/perl
#-------------------------------------------------------------------
# _e80Config_test.pl   <cmd>  <ip>  [folder]
#
# Parameterized gated test harness for the cleanroom e80Config library
# (e80Config.pm). Loads the library off the cleanroom folder
# and drives ONE high-level config-gestalt operation against a live E80,
# supplying the mutate-only shared $progress hash that navMate's wx
# ProgressDialog would otherwise provide. The library's own display() output
# (gated by $dbg_save / $dbg_clear / $dbg_restore = 0) shows the step-by-step.
#
#   cmd    = save | clear | restore
#   ip     = E80 address (e.g. 10.0.240.83 for E80-2)
#   folder = gestalt folder (required for save / restore; ignored for clear)
#
# EVERY command here touches the live unit; clear / restore WRITE it and reboot.
#   /c/Perl/bin/perl.exe -I/base _e80Config_test.pl save 10.0.240.83 ./e80-2_gestalt
#-------------------------------------------------------------------
use strict;
use warnings;
use threads;
use threads::shared;
use FindBin;
use lib $FindBin::Bin;                   # the co-located e80Config library
use e80Config;
use Pub::Utils qw(display warning error);

$| = 1;       # autoflush so the live progress dots appear as they happen

my ($cmd, $ip, $folder) = @ARGV;
defined($cmd) && defined($ip)
    or die "usage: _e80Config_test.pl <save|clear|restore> <ip> [folder]\n";
if ($cmd eq 'save' || $cmd eq 'restore')
{
    defined($folder) or die "$cmd requires a <folder> argument\n";
}
elsif ($cmd ne 'clear')
{
    die "unknown cmd '$cmd' (expected save | clear | restore)\n";
}

# the mutate-only progress hash the library expects (see reference-progress-shared-object)
my $progress = &threads::shared::share({});
$progress->{active}    = 1;
$progress->{total}     = 0;
$progress->{done}      = 0;
$progress->{cancelled} = 0;
$progress->{error}     = '';
$progress->{label}     = '';

display(0, 0, "e80Config test: $cmd  ip=$ip" . (defined($folder) ? "  folder=$folder" : ''));

# Run the (blocking) API call in a worker thread so the main thread can render live progress
# from the shared $progress the worker mutates. The session/socket is created and used entirely
# inside the worker (by the entry point), so nothing socket-ish crosses the thread boundary.
my $worker = threads->create(sub
{
    return e80Config::saveE80Config($ip, $folder, $progress)    if $cmd eq 'save';
    return e80Config::clearE80Config($ip, $progress)            if $cmd eq 'clear';
    return e80Config::restoreE80Config($ip, $folder, $progress) if $cmd eq 'restore';
    return 0;
});

# Live monitor (special exception to the display()-only rule): one "." per progress tick, a
# fresh CRLF line for each new label "message", lines kept to <= 80 columns.
my $LINEMAX   = 80;
my $lastdone  = 0;
my $lastlabel = '';
my $dots      = '';      # dots accumulated for the CURRENT phase line
my $started   = 0;

# repaint the current phase line in place (\r), padded to clear leftovers, kept under 80 columns
my $paint = sub
{
    my ($text) = @_;
    $text = substr($text, 0, $LINEMAX - 1);
    printf "\r%-*s", $LINEMAX - 1, $text;
};

# same phase  -> grow the dots / refresh the (N) count on ONE line (the bar moves, nothing freezes);
# new phase   -> commit the finished line with CRLF and start a fresh one.
my $render = sub
{
    my $label = $progress->{label} || '';
    my $done  = $progress->{done}  || 0;
    $lastdone = 0 if $done < $lastdone;             # tolerate a progress re-init (done reset)
    my $add = $done - $lastdone;
    $add = 0 if $add < 0;
    $lastdone = $done;

    (my $base     = $label)     =~ s/\s*\(\d+\)\s*$//;
    (my $lastbase = $lastlabel) =~ s/\s*\(\d+\)\s*$//;

    if ($started && $base ne $lastbase)
    {
        print "\r\n";          # commit the finished phase line
        $dots = '';
    }
    $dots     .= "." x $add;
    $started   = 1;
    $lastlabel = $label;
    $paint->(length($dots) ? "$label  $dots" : $label);
};

while ($worker->is_running())
{
    $render->();
    select(undef, undef, undef, 0.2);
}
$render->();                  # catch any tick / label that landed at the very end

my $ok = $worker->join();
print "\r\n";
display(0, 0, sprintf("e80Config test: %s -> %s   (progress %d/%d)%s",
    $cmd, $ok ? 'OK' : 'FAIL',
    $progress->{done} || 0, $progress->{total} || 0,
    (!$ok && $progress->{error}) ? "   error: $progress->{error}" : ''));
exit($ok ? 0 : 1);
