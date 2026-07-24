#---------------------------------------------
# em_engine.pm
#---------------------------------------------
# The e80Mod ENGINE: UI-free orchestration of the firmware build.  Depends only
# on the sacrosanct e80Firmware library (the four published entry points) and
# em_defs -- nothing wx.  The whole transform is in-memory and synchronous;
# build_modified() runs the four steps in order and calls an optional $step
# callback before each so the UI can paint coarse progress between them.

package em_engine;
use strict;
use warnings;
use Pub::Utils;
use e80Firmware;		# extract_app_image / apply_mod_record / build_mod_pkg / verify_db1_checksums
use em_defs;

sub build_modified
	# (%args) -> the output .pkg path on success, or undef on failure.
	#   pkg      => stock package path (the user's own E_App_Upg_Uni.pkg)
	#   builder  => the validated builder handle (or '' for the default)
	#   outdir   => directory to write the modified package into
	#   progress => optional shared/plain hash e80Firmware mutates ({error} on fail)
	#   step     => optional sub->($label, $done, $total) the UI paints between steps
	#
	# Stacks mod001..mod004 onto the extracted image (the combined v5.74
	# product), then repackages.  Any failure returns undef with the reason left
	# in $progress->{error} (and logged by e80Firmware via Pub::Utils error()).
{
	my (%a) = @_;
	my $pkg      = $a{pkg};
	my $builder  = $a{builder};
	my $outdir   = $a{outdir};
	my $progress = $a{progress} || {};
	my $step     = $a{step} || sub { };

	# The mod records are the build's only runtime data dependency.  Check them
	# up front so a missing/unshipped record yields a precise "modification data
	# missing" reason (our shipping problem) rather than e80Firmware's generic
	# per-region failure, which em_build would otherwise blame on the firmware.
	for my $n (1, 2, 3, 4)
	{
		my $rec = mod_record($n);
		if (!-f $rec)
		{
			$progress->{error} = "missing modification data file: $rec";
			return undef;
		}
	}

	# progress is reported as a COMPLETED-step count (0..6) so the long final
	# re-gzip/build sits visibly at 5/6 while it runs, rather than the bar jumping
	# straight to full.
	$step->("Reading firmware image ...", 0, 6);
	my $img = extract_app_image($pkg, $progress);
	return undef if !defined $img;

	$step->("Applying modification 1 of 4 ...", 1, 6);
	return undef if !apply_mod_record(mod_record(1), \$img, $progress);

	$step->("Applying modification 2 of 4 ...", 2, 6);
	return undef if !apply_mod_record(mod_record(2), \$img, $progress);

	$step->("Applying modification 3 of 4 ...", 3, 6);
	return undef if !apply_mod_record(mod_record(3), \$img, $progress);

	$step->("Applying modification 4 of 4 ...", 4, 6);
	return undef if !apply_mod_record(mod_record(4), \$img, $progress);

	$step->("Building modified package ...", 5, 6);
	my $out = build_mod_pkg(
		stock    => $pkg,
		image    => \$img,
		label    => $OUT_LABEL,
		version  => $OUT_VERSION,
		builder  => $builder,
		outdir   => $outdir,
		progress => $progress);

	display($dbg_build, 0, "build_modified: " . (defined $out ? "ok -> $out" : "FAILED")) if defined $dbg_build;
	return $out;
}

1;
