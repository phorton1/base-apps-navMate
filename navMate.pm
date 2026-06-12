#---------------------------------------------
# navMate.pm
#---------------------------------------------

package navMate;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::AppConfig;
use Pub::WX::Main;

use Pub::Ray::NET::a_defs;
use Pub::Ray::NET::a_mon;
use Pub::Ray::NET::a_utils;
use Pub::Ray::NET::a_parser;
use Pub::Ray::NET::b_sock;
use Pub::Ray::NET::b_records;
use Pub::Ray::NET::c_RAYDP;
use Pub::Ray::NET::d_WPMGR;
use Pub::Ray::NET::d_TRACK;
use Pub::Ray::NET::d_FILESYS;
use Pub::Ray::NET::e_WPMGR;
use Pub::Ray::NET::e_TRACK;
use Pub::Ray::NET::e_FILESYS;
use Pub::Ray::NET::e_wp_api;

use n_defs;
use n_utils;
use navPrefs;
use navDB;
use navFSH;
use navVisibility;
use navOutline;
use navSelection;
use navServer;
use Pub::Ray::NET::s_serial;
use nmResources;
use nmFrame;

use base 'Wx::App';

setStandardTempDir($appName);
setStandardDataDir($appName);
$ini_file = "$temp_dir/$appName.ini";
$appClientName = 'navMate';
init_prefs();


#---------------------------------
# main
#---------------------------------

display(0,0,"navMate.pm initializing");

sub _handleSerialCommand
{
	my ($lpart, $rpart) = @_;
	dispatchNavMateCommand($lpart, $rpart);
}

my $serial = Pub::Ray::NET::s_serial->new(\&_handleSerialCommand);

loadOutline('db');
loadOutline('fsh');
loadSelectionSets();
my $db_rc = navDB::openDB();
if ($db_rc == -1)
{
	display(0,0,"navMate: schema mismatch - use File->Import KML to rebuild database");
}
loadViewState();
if ($db_rc > 0)
{
	pruneDbVisibility();
	saveViewState();
}
navServer::startNavMateServer();

Pub::Ray::NET::a_defs::initServices(wpmgr => 1, track => 1, filesys => 1, auto_query => 1);
Pub::Ray::NET::c_RAYDP->new();
$raydp->start();

$serial->start();

display(0,0,"starting app");

my $frame;

sub OnInit
{
	$frame = nmFrame->new();
	if (!$frame)
	{
		error("unable to create frame");
		return undef;
	}
	$frame->Show(1);
	display(0,0,"$$resources{app_title} started");
	return 1;
}

my $app = navMate->new();
Pub::WX::Main::run($app);

display(0,0,"ending $appName.pm frame=$frame");
$frame->DESTROY() if $frame;
$frame = undef;

