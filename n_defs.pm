#---------------------------------------------
# n_defs.pm
#---------------------------------------------

package n_defs;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Ray::NET::a_utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(

		$NAVMATE_DATABASE

		$SCHEMA_VERSION

		$WP_TYPE_NAV
		$WP_TYPE_ROUTE_PT
		$WP_TYPE_SOUNDING
		$WP_TYPE_LABEL
		$WP_TYPE_HAZARD
		$WP_TYPE_SHIPWRECK
		$WP_TYPE_FISH
		$WP_TYPE_DIVING
		$WP_TYPE_POI
		@WP_TYPE_NAMES
		%WP_DEFAULT_SYMS
		@SYM_DEFAULT_ICONS

		$TS_SOURCE_E80
		$TS_SOURCE_KML_TIMESPAN
		$TS_SOURCE_PHORTON
		$TS_SOURCE_IMPORT

		$NODE_TYPE_BRANCH
		$NODE_TYPE_GROUP

		$CTX_CMD_COPY
		$CTX_CMD_CUT

		$CTX_CMD_PASTE
		$CTX_CMD_PASTE_NEW
		$CTX_CMD_PASTE_BEFORE
		$CTX_CMD_PASTE_AFTER
		$CTX_CMD_PASTE_NEW_BEFORE
		$CTX_CMD_PASTE_NEW_AFTER

		$CTX_CMD_DELETE_WAYPOINT
		$CTX_CMD_DELETE_GROUP
		$CTX_CMD_DELETE_GROUP_WPS
		$CTX_CMD_DELETE_ROUTE
		$CTX_CMD_REMOVE_ROUTEPOINT
		$CTX_CMD_DELETE_TRACK
		$CTX_CMD_DELETE_BRANCH

		$CTX_CMD_NEW_WAYPOINT
		$CTX_CMD_NEW_GROUP
		$CTX_CMD_NEW_ROUTE
		$CTX_CMD_NEW_BRANCH

		$CTX_CMD_PUSH
		$CTX_CMD_PUSH_FSH
		$CTX_CMD_PUSH_E80
		$CTX_CMD_PUSH_OCPN

	);
}


our $NAVMATE_DATABASE = 'C:/dat/Rhapsody/navMate.db';

# Schema version: integer part = breaking change (reimport required),
# decimal part = non-breaking change (advisory).
our $SCHEMA_VERSION = '13.2';

# waypoints.wp_type values (integer enum)
our $WP_TYPE_NAV       = 0;
our $WP_TYPE_ROUTE_PT  = 1;
our $WP_TYPE_SOUNDING  = 2;
our $WP_TYPE_LABEL     = 3;
our $WP_TYPE_HAZARD    = 4;
our $WP_TYPE_SHIPWRECK = 5;
our $WP_TYPE_FISH      = 6;
our $WP_TYPE_DIVING    = 7;
our $WP_TYPE_POI       = 8;

# Display names indexed by wp_type int (info text + wp_type editor choice).
our @WP_TYPE_NAMES = (
	'nav',        # 0
	'route_pt',   # 1
	'sounding',   # 2
	'label',      # 3
	'hazard',     # 4
	'shipwreck',  # 5
	'fish',       # 6
	'diving',     # 7
	'poi',        # 8
);

# Initial seed for key_values.wp_default_syms.  Phase 1 seeds but does not
# yet consume; Phase 2 wires the data-layer default-sym lookup.
our %WP_DEFAULT_SYMS = (
	$WP_TYPE_NAV       => $E80_SYM_SQUARE,
	$WP_TYPE_ROUTE_PT  => $E80_SYM_DIAMOND,
	$WP_TYPE_SOUNDING  => $E80_SYM_CIRCLE_M,
	$WP_TYPE_LABEL     => $E80_SYM_TRIANGLE,
	$WP_TYPE_HAZARD    => $E80_SYM_SKULL,
	$WP_TYPE_SHIPWRECK => $E80_SYM_SHIPWRECK,
	$WP_TYPE_FISH      => $E80_SYM_FISH,
	$WP_TYPE_DIVING    => $E80_SYM_BLUE_FLAG,
	$WP_TYPE_POI       => $E80_SYM_TRIANGLE_I,
);

# OpenCPN spoke (protocol.md sec 7): sym (0..35) -> the closest of OpenCPN's 43
# default IconNames (from ProcessDefaultIcons).  Positional: index == sym.  NOT
# a bijection (OpenCPN's set is open and coarser), so the icon->sym reverse
# (navDB::symForIcon) folds many icons onto one sym with a catch-all default.
# Grounded in the E80 sym catalog (Pub::Ray::NET::a_utils $E80_SYM_* 0..35).
our @SYM_DEFAULT_ICONS = (
	'Symbol-X-Large-Red',         #  0 X
	'Symbol-Circle-Red',          #  1 CIRCLE
	'Symbol-Square-Red',          #  2 SQUARE
	'Sea-Height-Red',             #  3 TRIANGLE
	'Symbol-Diamond-Red',         #  4 DIAMOND
	'Symbol-Diamond-Orange',      #  5 SHADED_DIAMOND
	'Symbol-Anchor3',             #  6 ANCHOR
	'Hazard-Danger',              #  7 SKULL (danger)
	'square',                     #  8 SQUARE_X
	'Info-Info',                  #  9 TRIANGLE_I
	'Sea-DepthB-Red',             # 10 DOWN_TRI_T
	'mob',                        # 11 CIRCLE_M (MOB)
	'Marks-Buoy-Safe-Water',      # 12 BUOY
	'litevessel',                 # 13 SAILBOAT
	'wreck2',                     # 14 SHIPWRECK
	'food',                       # 15 COCKTAIL
	'Activity-Diving-Snorkel',    # 16 SWIMMER
	'Hazard-Warning',             # 17 EXCLAMATION (warning)
	'Weather-Tropical-Storm-NH',  # 18 CLOUD
	'camping',                    # 19 TREE
	'coral',                      # 20 REEF
	'kelp',                       # 21 WEEDS
	'scuba',                      # 22 DIVE_FLAG
	'scuba',                      # 23 BLUE_FLAG
	'Info-Fish',                  # 24 BIG_FISH
	'Info-Fish-Haven',            # 25 FISH
	'Info-Fish-Pelagic',          # 26 FISH_STAR
	'Info-Fish-Reef',             # 27 FISH_TWO_STAR
	'Info-Fish-Reef',             # 28 FISH_THREE_STAR
	'Info-Fish-Reef',             # 29 TWO_FISH
	'Info-Fish-Pelagic',          # 30 SWORDFISH
	'Info-Fish-Whale',            # 31 DOLPHIN
	'Info-Fish-Shark',            # 32 SHARK
	'fishhaven',                  # 33 LOBSTER
	'fishing',                    # 34 SPORTFISHEER
	'fishing',                    # 35 TRAWLER
);

# ts_source values (waypoints.ts_source, tracks.ts_source)
our $TS_SOURCE_E80          = 'e80';
our $TS_SOURCE_KML_TIMESPAN = 'kml_timespan';
our $TS_SOURCE_PHORTON      = 'phorton';
our $TS_SOURCE_IMPORT       = 'import';

# collections.node_type values (DB-level only; import uses transient 'routes'/'groups'/'tracks' strings internally)
our $NODE_TYPE_BRANCH = 'branch';
our $NODE_TYPE_GROUP  = 'group';

# Context menu command IDs
our $CTX_CMD_COPY				= 10200;
our $CTX_CMD_CUT				= 10201;

our $CTX_CMD_PASTE				= 10210;
our $CTX_CMD_PASTE_NEW			= 10211;
our $CTX_CMD_PASTE_BEFORE		= 10212;
our $CTX_CMD_PASTE_AFTER		= 10213;
our $CTX_CMD_PASTE_NEW_BEFORE	= 10214;
our $CTX_CMD_PASTE_NEW_AFTER	= 10215;

our $CTX_CMD_DELETE_WAYPOINT	= 10220;
our $CTX_CMD_DELETE_GROUP		= 10221;
our $CTX_CMD_DELETE_GROUP_WPS	= 10222;
our $CTX_CMD_DELETE_ROUTE		= 10223;
our $CTX_CMD_REMOVE_ROUTEPOINT	= 10224;
our $CTX_CMD_DELETE_TRACK		= 10225;
our $CTX_CMD_DELETE_BRANCH		= 10226;

our $CTX_CMD_NEW_WAYPOINT		= 10230;
our $CTX_CMD_NEW_GROUP			= 10231;
our $CTX_CMD_NEW_ROUTE			= 10232;
our $CTX_CMD_NEW_BRANCH			= 10233;

our $CTX_CMD_PUSH				= 10250;
our $CTX_CMD_PUSH_FSH			= 10251;
our $CTX_CMD_PUSH_E80			= 10252;
our $CTX_CMD_PUSH_OCPN			= 10253;


1;
