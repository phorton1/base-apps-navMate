#---------------------------------------------
# nw_defs.pm
#---------------------------------------------
# Shared constants for the netWizard: dev-verbosity knobs, config,
# wx control IDs, and geometry.  Exported (a_defs style) so the panels
# and engine can use them bare.

package nw_defs;
use strict;
use warnings;
use Pub::Ray::NET::a_defs;		# for $LOCAL_IP

BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		$dbg_wiz $dbg_net $dbg_search
		$SEARCH_SECS $TARGET_IP $TARGET_MASK
		$ID_BACK $ID_NEXT $ID_CANCEL $ID_ACTION $ID_LIST $ID_TIMER
		$WIN_W $WIN_H $M $TITLE_Y $BODY_Y $BTN_W $BTN_H $BTN_GAP
	);
}

# dev-verbosity knobs ('our' so they can be tweaked at runtime;
# display() shows a line when its level <= $debug_level)

our $dbg_wiz    = 0;	# wizard flow / navigation
our $dbg_net    = 0;	# adapter detection + netsh
our $dbg_search = 0;	# RAYDP listen detail

# config (no command-line flags; source constants, shark $WITH_* spirit)

our $SEARCH_SECS = 8;
our $TARGET_IP   = $LOCAL_IP;		# 10.0.0.200, from a_defs
our $TARGET_MASK = '255.0.0.0';

# wx control IDs (clear of the Pub::WX-reserved 0..199 range)

our $ID_BACK	= 2001;
our $ID_NEXT	= 2002;
our $ID_CANCEL	= 2003;
our $ID_ACTION	= 2004;		# panel-specific left button
our $ID_LIST	= 2005;
our $ID_TIMER	= 2006;

# geometry

our $WIN_W	= 480;
our $WIN_H	= 380;
our $M		= 18;		# margin
our $TITLE_Y	= 14;
our $BODY_Y	= 50;
our $BTN_W	= 75;
our $BTN_H	= 28;
our $BTN_GAP	= 8;

1;
