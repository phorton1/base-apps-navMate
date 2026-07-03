#---------------------------------------------
# n_utils.pm
#---------------------------------------------

package n_utils;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use POSIX qw(strftime);
use Pub::Utils;
use if is_win, 'Cava::Packager';
use n_defs;
use Pub::Ray::NET::a_utils qw(northEastToLatLon @E80_SYMS);


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$app_dir
		implementationError
		makeUUID
		makeFSHUUID
		parseLatLon
		formatLatLon
		latLonLineText
		northEastLineText
		symText
		wpTypeText
		depthText
		tempKText
		tsText
		$TRACK_TIMED_MIN
		trackPointIsTimed
		decodeTrackPoint
		encodeTrackPoint
		trackPointsText
		trackEndpointsText
		routePointsText
		uuidRefText
		@E80_ROUTE_COLOR_ABGR
		@E80_ROUTE_COLOR_NAMES
		abgrToE80Index
		isExactE80Color
	);
}


our $app_dir = is_win() ? 'C:\base\apps\navMate' : '/base/apps/navMate';

# Cava resource root: dev = the in-repo _res folder; packaged = the bundled
# resource dir.  _site and sym_catalog now live under it, as $resource_dir/site
# and $resource_dir/sym_catalog.
setStandardResourceDir("$app_dir/_res");


#---------------------------------
# implementationError
#---------------------------------
# Unified guard-emission helper used across navOps.  Emits the same
# message in two modes depending on $nmDialogs::suppress_error_dialog:
#   suppressed (test runs):  warning() -- log only, "WARNING: ..." prefix
#   live UI:                 error()   -- pops dialog AND logs
# call_level=2 makes the log attribute to the caller (navOps site),
# not this helper.  Callers pass condition-only text; the helper
# prefixes "IMPLEMENTATION ERROR: " uniformly.

sub implementationError
{
	my ($msg) = @_;
	if ($nmDialogs::suppress_error_dialog)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: $msg", 2);
	}
	else
	{
		error("IMPLEMENTATION ERROR: $msg", 2);
	}
}


#---------------------------------
# makeUUID
#---------------------------------

sub makeUUID
	# Generate a navMate UUID (16 hex chars = 8 bytes).
	# Byte 1 = 0x4E ('N') identifies navMate-created objects.
	# Bytes 4-5 hold the persistent counter (little-endian).
	# Byte 0 and bytes 2-3 are random; bytes 6-7 are intra-tick random.
{
	my ($counter) = @_;
	return sprintf("%02x4e%04x%s%04x",
		int(rand(256)),
		int(rand(65536)),
		unpack('H*', pack('v', $counter)),
		int(rand(65536)));
}


sub makeFSHUUID
{
	my ($counter) = @_;
	return sprintf("%02x46%04x%s%04x",
		int(rand(256)),
		int(rand(65536)),
		unpack('H*', pack('v', $counter)),
		int(rand(65536)));
}


#---------------------------------
# parseLatLon
#---------------------------------
# Accepts decimal degrees or degrees+decimal-minutes, with optional
# leading minus or trailing NSEW compass letter.  NSEW overrides
# a leading minus when both are present.
#
# Accepted formats (whitespace flexible):
#   DD:   9.3617   -9.3617   9.3617 N   9.3617 S
#   DDM:  9 21.702   -9 21.702   9 21.702 N   9 21.702 S
#
# Returns decimal degrees as a number, or undef on parse failure.

sub parseLatLon
{
	my ($str) = @_;
	return undef if !defined($str);
	$str =~ s/^\s+|\s+$//g;
	return undef if $str eq '';

	my $sign = 1;

	# Optional leading minus
	if ($str =~ s/^-//)
	{
		$sign = -1;
	}
	$str =~ s/^\s+//;

	# Optional trailing NSEW - overrides leading minus
	if ($str =~ s/\s*([NSEWnsew])$//)
	{
		my $dir = uc($1);
		$sign = ($dir eq 'S' || $dir eq 'W') ? -1 : 1;
	}
	$str =~ s/\s+$//;

	# DDM: non-negative integer degrees + space + decimal minutes (0..59.999)
	if ($str =~ /^(\d+)\s+(\d+(?:\.\d+)?)$/)
	{
		my ($deg, $min) = ($1 + 0, $2 + 0);
		return undef if $min >= 60;
		return $sign * ($deg + $min / 60);
	}

	# DD: single non-negative number
	if ($str =~ /^(\d+(?:\.\d+)?)$/)
	{
		return $sign * ($1 + 0);
	}

	return undef;
}


#---------------------------------
# formatLatLon
#---------------------------------
# Formats a decimal-degree value as "DD (DDM)" for display.
# $is_lat true -> N/S compass; false -> E/W.
# Example: formatLatLon(9.3617, 1)  -> "9.361700 N  (9deg21.702' N)"
#          formatLatLon(-82.2451, 0) -> "82.245100 W  (82deg14.706' W)"

sub formatLatLon
{
	my ($dd, $is_lat) = @_;
	my $abs = abs($dd);
	my $dir = $is_lat
		? ($dd >= 0 ? 'N' : 'S')
		: ($dd >= 0 ? 'E' : 'W');
	my $deg     = int($abs);
	my $min     = ($abs - $deg) * 60;
	my $deg_sym = chr(176);
	return sprintf("%.6f %s  (%d%s%06.3f' %s)", $abs, $dir, $deg, $deg_sym, $min, $dir);
}


#---------------------------------
# E80 route/track line colors
#---------------------------------
# Index 0-5 maps to $ROUTE_COLOR_XXX constants in NET::a_defs.pm.
# Index 5 ($ROUTE_COLOR_BLACK) displays as white on the Leaflet map.

our @E80_ROUTE_COLOR_ABGR = qw(
	ff0000ff
	ff00ffff
	ff00ff00
	ffff0000
	ffff00ff
	ffffffff
);

# Index 5 is called BLACK in the E80 protocol but its ABGR is ffffffff (white on Leaflet).
our @E80_ROUTE_COLOR_NAMES = ('Red', 'Yellow', 'Green', 'Blue', 'Purple', 'Black (White on Map)');


sub abgrToE80Index
{
	my ($abgr) = @_;
	return 0 if !($abgr && length($abgr) >= 8);
	my $rr = hex(substr($abgr, 6, 2));
	my $gg = hex(substr($abgr, 4, 2));
	my $bb = hex(substr($abgr, 2, 2));
	my @targets = (
		[255,   0,   0],   # 0 RED
		[255, 255,   0],   # 1 YELLOW
		[  0, 255,   0],   # 2 GREEN
		[  0,   0, 255],   # 3 BLUE
		[255,   0, 255],   # 4 PURPLE
		[255, 255, 255],   # 5 WHITE (protocol name: BLACK)
	);
	my ($best_idx, $best_dist) = (0, 9e99);
	for my $i (0 .. $#targets)
	{
		my $d = ($rr - $targets[$i][0])**2
		      + ($gg - $targets[$i][1])**2
		      + ($bb - $targets[$i][2])**2;
		$best_idx = $i if $d < $best_dist and do { $best_dist = $d; 1 };
	}
	return $best_idx;
}


my %_e80_exact_color = map { $_ => 1 } @E80_ROUTE_COLOR_ABGR;
sub isExactE80Color { $_e80_exact_color{lc($_[0] // '')} ? 1 : 0 }


#---------------------------------
# info-text helpers
#---------------------------------
# Convergence layer used by winDatabase / winFSH / winE80 info panels.
# Each returns the formatted "value" portion -- callers wrap with their
# own "<key> = " prefix via sprintf / _fmt.

sub latLonLineText
	# Two-line block: "  lat = DD (DDM)\n  lon = DD (DDM)\n"
	# Caller-supplied indent (default 2 spaces) and key width.
{
	my ($lat, $lon, %opts) = @_;
	my $indent = $opts{indent} // '  ';
	my $kw     = $opts{kw}     // 12;
	return sprintf("%s%-${kw}s = %s\n%s%-${kw}s = %s\n",
		$indent, 'lat', formatLatLon($lat // 0, 1),
		$indent, 'lon', formatLatLon($lon // 0, 0));
}


sub northEastLineText
	# Two-line block showing raw N/E ints AND the lat/lon they round-trip
	# back to (diagnostic for Mercator precision delta).  nkey/ekey
	# default to 'north'/'east' but can be set to 'north_start'/'east_end'
	# etc. when an MTA record carries pair-suffixed fields.
{
	my ($north, $east, %opts) = @_;
	my $indent = $opts{indent} // '  ';
	my $kw     = $opts{kw}     // 12;
	my $nkey   = $opts{nkey}   // 'north';
	my $ekey   = $opts{ekey}   // 'east';
	my $c = northEastToLatLon($north // 0, $east // 0);
	return sprintf("%s%-${kw}s = %-12d -> %s\n%s%-${kw}s = %-12d -> %s\n",
		$indent, $nkey, $north // 0, formatLatLon($c->{lat} + 0, 1),
		$indent, $ekey, $east  // 0, formatLatLon($c->{lon} + 0, 0));
}


sub symText
{
	my ($sym) = @_;
	$sym //= 0;
	my $name = $E80_SYMS[$sym] // '?';
	return "$sym ($name)";
}


sub wpTypeText
{
	my ($wt) = @_;
	$wt //= 0;
	my $name = $WP_TYPE_NAMES[$wt] // '?';
	return "$wt ($name)";
}


sub depthText
	# Accepts depth in cm; renders "N cm  (X.X ft)".
{
	my ($cm) = @_;
	$cm //= 0;
	return sprintf('%d cm  (%.1f ft)', $cm, $cm / 30.48);
}


sub tempKText
	# Accepts Kelvin * 100; renders "N  (X.X F)".
{
	my ($tk) = @_;
	$tk //= 0;
	return sprintf('%d  (%.1f F)', $tk, ($tk / 100 - 273) * 9 / 5 + 32);
}


sub tsText
	# Unix epoch seconds -> "YYYY-MM-DD HH:MM UTC" or "(none)".
{
	my ($ts) = @_;
	return $ts ? strftime("%Y-%m-%d %H:%M UTC", gmtime($ts)) : '(none)';
}


# mod003 timed-track decode.  A mod003 E80 (per Pub::Ray
# e80_firmware/deployment/mod003.md, "the timed-track contract") stamps each
# track point with time + true depth by OVERLOADING the 14-byte record's last
# two fields, length-preserving and with no type flag -- detection is purely by
# value.  When the raw depth u32 reads as a unix time at/after 1980-01-01
# (>= 315532800 = 0x12CEA600), the point is "timed": the depth field then holds
# the unix timestamp (sec) and the temp field holds the real depth in 0.1 ft
# (not a temperature).  No real depth in cm approaches 3155 km, so the threshold
# separates the two readings with vast margin.
our $TRACK_TIMED_MIN = 315532800;	# 0x12CEA600 -- 1980-01-01 00:00 UTC

sub trackPointIsTimed
	# True if a raw track-point depth u32 is a mod003 "timed" stamp (a unix
	# time) rather than a depth in cm.  Callers pass the raw depth field
	# ($pt->{depth} / depth_start / depth_end); on a timed point the temp
	# field then holds depth in 0.1 ft.
{
	my ($depth_raw) = @_;
	return defined($depth_raw) && $depth_raw >= $TRACK_TIMED_MIN ? 1 : 0;
}


# tenths-of-a-foot <-> centimetres.  A mod003 TIMED point stores depth in the
# (overloaded) temp field as 0.1 ft; the hub stores depth in cm.  0.1 ft = 3.048 cm.
my $CM_PER_TENTH_FT = 3.048;


sub decodeTrackPoint
	# Decode one RAW spoke track point (Pub::Ray parseTRK shape:
	# {lat, lon, north, east, temp_k, depth}) into the hub's flat per-point columns
	# {lat, lon, depth_cm, temp_k, ts}.  mod003 TIMED points overload the last two
	# wire fields: when the raw depth reads as a unix time (trackPointIsTimed) the
	# depth field IS the timestamp and the temp field is the real depth in 0.1 ft --
	# so they split out as {ts, depth_cm from 0.1ft, temp_k=0}.  STOCK points pass
	# through {depth_cm=depth, temp_k, ts=0}.  See $TRACK_TIMED_MIN and the corpus
	# Pub::Ray e80_firmware/deployment/mod003.md.
{
	my ($pt) = @_;
	my $raw_depth = $pt->{depth} // $pt->{depth_cm} // 0;
	my %hub = (lat => $pt->{lat}, lon => $pt->{lon});
	if (trackPointIsTimed($raw_depth))
	{
		$hub{ts}       = $raw_depth;
		$hub{depth_cm} = int(($pt->{temp_k} // 0) * $CM_PER_TENTH_FT + 0.5);
		$hub{temp_k}   = 0;
	}
	else
	{
		$hub{depth_cm} = $raw_depth;
		$hub{temp_k}   = $pt->{temp_k} // 0;
		$hub{ts}       = 0;
	}
	return \%hub;
}


sub encodeTrackPoint
	# Encode one hub point {depth_cm, temp_k, ts} into the two overloadable wire
	# fields {temp_k, depth} for buildTRKPoint (the caller supplies north/east).
	# When $force_timed is set AND the point carries a real timestamp
	# (>= $TRACK_TIMED_MIN), write a TIMED point: depth = the unix ts, temp = depth
	# in 0.1 ft (a real cm depth degrades to the 0.1 ft grid -- the accepted loss).
	# Otherwise write STOCK: depth = depth_cm, temp = temp_k.  Firmware-agnostic --
	# the E80 ignores a track point's depth/temp, so a timed write is safe on any
	# unit and round-trips losslessly through it.
{
	my ($pt, $force_timed) = @_;
	my $ts       = $pt->{ts} // 0;
	my $depth_cm = $pt->{depth_cm} // $pt->{depth} // 0;
	return { depth => $ts, temp_k => int($depth_cm / $CM_PER_TENTH_FT + 0.5) }
		if $force_timed && $ts >= $TRACK_TIMED_MIN;
	return { depth => $depth_cm, temp_k => $pt->{temp_k} // 0 };
}


sub trackPointsText
	# Renders an indexed table of trackpoints.  Each point may carry
	# {lat, lon, depth_cm OR depth, temp_k, ts} -- depth and ts are
	# optional.  with_datetime=1 adds a trailing UTC timestamp column
	# (only the DB carries per-point ts).
	#
	# variable=1 decodes the mod003 "timed-track" overload (live E80 reads):
	# any point whose raw depth u32 is a unix time (trackPointIsTimed) is timed
	# -- its depth field is the timestamp and its temp field is the real depth
	# in 0.1 ft, not a temperature.  When any point is timed the datetime column
	# is shown automatically.  See $TRACK_TIMED_MIN.
{
	my ($points, %opts) = @_;
	return '' if !$points || !@$points;
	my $variable = $opts{variable} ? 1 : 0;

	# show the datetime column when explicitly asked (DB per-point ts) or when
	# a variable-format track actually carries a timed point (live mod003 E80).
	my $any_timed = 0;
	if ($variable)
	{
		for my $pt (@$points)
		{
			$any_timed = 1, last
				if trackPointIsTimed($pt->{depth_cm} // $pt->{depth});
		}
	}
	my $with_dt = ($opts{with_datetime} || $any_timed) ? 1 : 0;

	my $text = '';
	for my $i (0 .. $#$points)
	{
		my $pt   = $points->[$i];
		my $lat  = ($pt->{lat} // 0) + 0;
		my $lon  = ($pt->{lon} // 0) + 0;
		# (0,0) treated as a sentinel (FSH zero-zero filler) -- depth/temp
		# blanked out to match the visual "no real data" cue.
		my $sentinel = ($lat == 0 && $lon == 0) ? 1 : 0;
		my $d_raw = $pt->{depth_cm} // $pt->{depth} // 0;

		my ($d_ft, $t_f, $ts);
		if ($variable && !$sentinel && trackPointIsTimed($d_raw))
		{
			# timed point: depth holds the unix time, temp holds 0.1-ft depth
			$ts   = $d_raw;
			$d_ft = sprintf('%.1fft', ($pt->{temp_k} // 0) / 10);
			$t_f  = '-';
		}
		else
		{
			$d_ft = (!$sentinel && $d_raw) ? sprintf('%.1fft', $d_raw / 30.48) : '-';
			$t_f  = (!$sentinel && ($pt->{temp_k} // 0))
				? sprintf('%.1fF', ($pt->{temp_k} / 100 - 273) * 9 / 5 + 32)
				: '-';
			$ts   = $pt->{ts};
		}

		my $dt = '';
		if ($with_dt)
		{
			$dt = (!$sentinel && ($ts // 0))
				? '  ' . strftime("%Y-%m-%d %H:%M:%S UTC", gmtime($ts))
				: '  -';
		}
		$text .= sprintf("  %3d  %9.6f  %10.6f  %8s  %6s%s\n",
			$i + 1, $lat, $lon, $d_ft, $t_f, $dt);
	}
	return $text;
}


sub trackEndpointsText
	# Renders an E80/FSH track's start- and end-point summary: the north/east
	# geometry line then the depth/temperature for each end.  mod003 timed tracks
	# OVERLOAD the stored depth_start/depth_end -- when one reads as a unix time
	# (trackPointIsTimed) it is that end's timestamp and the companion temp_k field
	# is its real depth in 0.1 ft, not a temperature -- so it is shown as
	# time_/depth_ rather than depth_/temp_k_.  Shared by winE80 and winFSH so both
	# on-device track views decode the overload identically.
{
	my ($track) = @_;
	my $text = '';
	for my $which ('start', 'end')
	{
		my $north = $track->{"north_$which"};
		my $east  = $track->{"east_$which"};
		$text .= northEastLineText($north, $east, nkey => "north_$which", ekey => "east_$which")
			if defined $north && defined $east;

		my $depth = $track->{"depth_$which"};
		my $temp  = $track->{"temp_k_$which"};
		if (trackPointIsTimed($depth))
		{
			$text .= sprintf("  %-12s = %s\n",      "time_$which",  tsText($depth));
			$text .= sprintf("  %-12s = %.1f ft\n", "depth_$which", ($temp // 0) / 10);
		}
		else
		{
			$text .= sprintf("  %-12s = %s\n", "depth_$which",  depthText($depth)) if $depth;
			$text .= sprintf("  %-12s = %s\n", "temp_k_$which", tempKText($temp))  if $temp;
		}
	}
	return $text;
}


sub routePointsText
	# Renders a list of route waypoints with their per-point geometry.
	# Each point may carry {name, lat, lon, bearing, legLength, totLength}.
	# bearing/legLength/totLength are present on E80/FSH route geometry
	# records and absent in the DB; rendered conditionally.
{
	my ($points) = @_;
	return '' if !$points || !@$points;
	my $text = '';
	for my $i (0 .. $#$points)
	{
		my $pt = $points->[$i];
		$text .= sprintf("  %2d. %s\n", $i + 1, $pt->{name} // '');
		$text .= sprintf("      lat       = %s\n", formatLatLon($pt->{lat} // 0, 1));
		$text .= sprintf("      lon       = %s\n", formatLatLon($pt->{lon} // 0, 0));
		$text .= sprintf("      bearing   = %.1f deg\n",
			($pt->{bearing} / 10000) * (180 / 3.14159265358979))
			if defined $pt->{bearing};
		$text .= sprintf("      legLength = %d m\n", $pt->{legLength}) if defined $pt->{legLength};
		$text .= sprintf("      totLength = %d m\n", $pt->{totLength}) if defined $pt->{totLength};
	}
	return $text;
}


sub uuidRefText
	# Render a UUID with optional name resolution.  $resolver is a
	# coderef taking the UUID and returning a descriptive string
	# (e.g. 'group "Foo"') or undef when not found.
{
	my ($uuid, $resolver) = @_;
	my $ref = $resolver ? $resolver->($uuid) : undef;
	return $ref ? "$uuid = $ref" : $uuid;
}


1;

