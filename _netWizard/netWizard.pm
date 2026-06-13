#---------------------------------------------
# netWizard.pm
#---------------------------------------------
# E-Series Connection Setup -- the network-setup WIZARD for navMate.
#
# A console-less GUI (the navMateGUI/exec_type=1 build pattern) that gets a
# laptop onto the SeaTalkHS (RAYNET) network so navMate can talk to the plotter.
# Driven panel flow (no menubar): Welcome -> Search -> Address -> Done.
#
# Depends only on the shared Pub:: tree (Pub::Ray::NET::a_defs constants +
# Pub::Utils) -- NOTHING from navMate's own packages.  Decomposed into nw_*
# modules in this folder; new "wizardly" fallback paths get added as new
# nw_* panel modules.
#
# Privileged work (netsh) is NOT self-elevated: the shipped exe carries a
# requireAdministrator manifest; in dev launch it from an elevated shell.
# When not elevated the Apply step is disabled/annotated rather than failing.
#
# Output: NO command-line input surface.  The console, when present (dev), is
# strictly output.  Everything goes through Pub::Utils -- display() at the
# $dbg_* levels, warning()/error(), LOG(-1,..) for headers -- and is appended
# to navMate's $data_dir/netWizard.log.
#
# Run (dev):  /c/Perl/bin/perl.exe -I/base _netWizard/netWizard.pm

package netWizard;
use strict;
use warnings;
use lib '/base';
use lib '/base/apps/navMate/_netWizard';
use Wx;
use Pub::Utils;
use nw_frame;
use base qw(Wx::App);

my $frame;

sub OnInit
{
	my ($this) = @_;
	$frame = nw_frame->new();
	if (!$frame)
	{
		error("unable to create the wizard frame");
		return undef;
	}
	setAppFrame($frame);		# so error() surfaces as a dialog
	$frame->Show(1);
	return 1;
}


#---------------------------------
# main
#---------------------------------

setStandardDataDir('navMate');
$logfile = "$data_dir/netWizard.log";
LOG(-1, "==== E-Series Connection Setup (netWizard) ====");

my $app = netWizard->new();
$app->MainLoop();

LOG(-1, "netWizard exiting");

1;
