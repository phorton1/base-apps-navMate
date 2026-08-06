#---------------------------------------------
# em_defs.pm
#---------------------------------------------
# Shared constants for e80Mod: debug gates, wx control IDs, geometry, the
# firmware-source URL, the fixed output naming, the builder-handle rule, the
# point-of-use disclaimer text, and the location of the mod records the build
# reads.  Exported a_defs-style so the panels and engine use them bare.

package em_defs;
use strict;
use warnings;
use Pub::Utils;			# $resource_dir (set by e80Mod via setStandardResourceDir)
use if is_win, 'Cava::Packager';		# $Cava::Packager::PACKAGED

BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		$dbg_mod $dbg_build
		$ID_BACK $ID_NEXT $ID_CANCEL $ID_ACTION $ID_AGREE $ID_BROWSE $ID_OUTDIR $ID_HANDLE $ID_TIMER
		$WIN_W $WIN_H $M $TITLE_Y $BODY_Y $BTN_H $BTN_GAP $CB_H
		$RAYMARINE_URL $BUILDER_RE $DEFAULT_BUILDER $OUT_LABEL $OUT_VERSION $OUT_BASENAME
		$DISCLAIMER_TEXT
		mods_dir mod_record
	);
}

# debug gates (display(level,indent,msg) shows when the global level >= gate)

our $dbg_mod   = 0;		# wizard flow / pick
our $dbg_build = 0;		# the build pipeline

# wx control IDs (clear of the Pub::WX-reserved 0..199 range; e80Mod's own 2100 block)

our $ID_BACK   = 2101;
our $ID_NEXT   = 2102;
our $ID_CANCEL = 2103;
our $ID_ACTION = 2104;		# panel-specific left button
our $ID_AGREE  = 2105;		# the "I agree" checkbox
our $ID_BROWSE = 2106;		# the firmware Browse button
our $ID_HANDLE = 2107;		# the builder-handle text field
our $ID_TIMER  = 2108;		# scroll-gate poll timer
our $ID_OUTDIR = 2109;		# the output-folder Change button

# geometry (the agreement panels need a tall read area, so a larger frame than netWizard)

our $WIN_W   = 600;
our $WIN_H   = 560;
our $M       = 18;		# margin
our $TITLE_Y = 14;
our $BODY_Y  = 50;
our $BTN_H   = 28;
our $BTN_GAP = 8;
our $CB_H    = 24;		# checkbox row height

# product / firmware source

our $RAYMARINE_URL  = 'https://www.raymarine.com/en-us/download/e-series-classic-software';
our $BUILDER_RE     = qr/^[A-Za-z0-9.-]{1,15}$/;	# letters/digits/dash/dot, 1-15, no spaces
our $DEFAULT_BUILDER = 'navMate';
our $OUT_LABEL      = 'mod005';			# output is E_App_Upg_Uni.mod005.pkg (FIXED; user never names it)
our $OUT_VERSION    = '5.75';			# the combined mod001..mod005 app version
our $OUT_BASENAME   = "E_App_Upg_Uni.$OUT_LABEL.pkg";

# Mod-record location -- the build's ONLY runtime data dependency (the disclaimer
# is an embedded constant; the GPL license page was dropped).  DEV reads the
# canonical, sacrosanct source in the repo tree.  PACKAGED reads the copy shipped
# under the Cava resource dir ({app}/res/mods), placed there at build time by
# _installer/PreInstallApp.pm -- the records (mods/) are not a Cava resource,
# so the build denormalizes a copy for shipping (see build.md).

our $DEV_ROOT = '/base/apps/navMate';

sub mods_dir
{
	# PACKAGED -> {app}/res/mods ($resource_dir is set by e80Mod.pm via
	# setStandardResourceDir); DEV -> the canonical mods/ source.
	return $Cava::Packager::PACKAGED
		? "$resource_dir/mods"
		: "$DEV_ROOT/mods";
}

sub mod_record
{
	my ($n) = @_;
	return sprintf("%s/e80_mod%03d.txt", mods_dir(), $n);
}

# The point-of-use disclaimer: the general Notice to Mariners PLUS the
# firmware-modification risk acknowledgment.  (Kept in spirit with the
# installer's NOTICE_TO_MARINERS.txt; the app extends it with the modify-risk.)

our $DISCLAIMER_TEXT = <<'END_DISCLAIMER';
MODIFYING YOUR CHARTPLOTTER'S FIRMWARE

e80Mod builds a modified version of the software that runs your E-Series
display. You are modifying firmware on your own device, from firmware you
supply yourself -- nothing of the manufacturer's is included with this tool.

Although we have taken every step we could think of to make this modified
firmware as robust and safe as possible for you to use, you are building
and installing the result at your own risk and on your own responsibility.

Installing modified firmware carries real risk. A failed, interrupted, or
incorrect firmware update can leave the unit temporarily or permanently
unusable or result in unexpected behavior.

navMate and this firmware are provided as an aid to navigation only --
not a substitute for official charts, a proper lookout, or sound
seamanship and judgment. Never rely on it as your sole means of navigation.
The sea is inherently hazardous. You alone are responsible for the safe
operation of your vessel and every decision made aboard it. Use of this
software is entirely at your own risk.

navMate and this firware are provided "as is", without warranty of any kind.
To the extent permitted by law, the author accepts no liability for any loss,
property damage, personal injury, or loss of life arising from its use or misuse.

By continuing you acknowledge that you have read and understood these risks
and accept full responsibility for building and installing modified firmware
on your own hardware. If you are not comfortable with this, stop now and
close this window.
END_DISCLAIMER

1;
