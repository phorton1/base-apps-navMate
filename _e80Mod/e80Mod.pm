#---------------------------------------------
# e80Mod.pm
#---------------------------------------------
# E-Series Firmware Builder -- the "modder".  A console-less GUI (the
# navMateGUI/exec_type=1 build pattern) that turns the user's OWN stock
# E_App_Upg_Uni package into a modified, flashable package, entirely on their
# machine.  Driven panel flow (no menubar): Disclaimer -> License -> Pick ->
# Build -> Done.  NO command-line params -- every input comes through the GUI.
#
# Depends on the sacrosanct e80Firmware library (the build backend) plus the
# shared Pub:: tree; its own panels live in nw_*-style em_* modules in this
# folder.  Pure offline file work: no device contact, no network, no elevation.
#
# Run (dev):  /c/Perl/bin/perl.exe -I/base _e80Mod/e80Mod.pm

package e80Mod;
use strict;
use warnings;
use lib '/base';
use lib '/base/apps/navMate';
use lib '/base/apps/navMate/_e80Mod';
use Wx;
use Pub::Utils;
use em_frame;
use base qw(Wx::App);

my $frame;

sub OnInit
{
	my ($this) = @_;
	$frame = em_frame->new();
	if (!$frame)
	{
		error("unable to create the e80Mod frame");
		return undef;
	}
	setAppFrame($frame);		# error() surfaces as a dialog.  The build panel mutes
								# the app frame around e80Firmware so its cryptic errors
								# do not pop, then logs them and shows reworded ones.
	$frame->Show(1);
	return 1;
}


#---------------------------------
# main
#---------------------------------

setStandardDataDir('navMate');
$logfile = "$data_dir/e80Mod.log";
LOG(-1, "==== e80Mod (E-Series Firmware Builder) ====");

my $app = e80Mod->new();
$app->MainLoop();

LOG(-1, "e80Mod exiting");

1;
