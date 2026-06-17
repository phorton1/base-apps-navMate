#!/usr/bin/perl

package e80Firmware;
use strict;
use warnings;
use POSIX qw(strftime);
use Digest::SHA qw(sha256_hex);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use IO::Compress::Gzip qw(gzip $GzipError);
use Pub::Utils qw(display error warning);

# e80Firmware -- build a modified E80 application package from a stock one.
#
# One in-process library behind the modder: it extracts the application image
# from a stock E_App_Upg_Uni package, applies one or more modification records to
# that image in memory, and repackages it into a flashable, labeled package whose
# container checksums and length cascade are recomputed correctly. A companion
# verifier checks a stock package's DB1 checksums.
#
# The four published entry points:
#   extract_app_image($pkg)              -> the inflated application image bytes
#   apply_mod_record($record, \$image)   -> apply a mods/e80_mod<NNN>.txt record in place
#   build_mod_pkg(%args)                 -> repackage an image into a labeled .pkg
#   verify_db1_checksums($pkg)           -> ($ok, \@rows) for a stock-layout package
#
# The pipeline is in-memory: extract returns the image, apply mutates a scalar
# ref, build consumes one -- no temp files between steps. Errors are reported
# through Pub::Utils error() and, when a shared progress hash is supplied, its
# {error} field (the same mutate-only contract the sibling cleanroom libraries
# use); operations return undef / 0 on failure rather than dying.
#
# Container facts (offsets, the DB1 byte-sum checksum scheme, the child table) are
# the documented stock package format. The build stamps a BUILDER SIGNATURE into
# the package's build descriptors (rendered on the unit's Unit Info screen); it is
# the caller's chosen handle, validated below, defaulting to a neutral tag.

BEGIN
{
    use Exporter qw( import );
    our @EXPORT = qw(
        extract_app_image
        apply_mod_record
        build_mod_pkg
        verify_db1_checksums
    );
}



# ---- debug gates: display(gate, indent, msg) shows when the global debug level is >= gate ----
my $dbg_extract = 0;                # extract_app_image
my $dbg_apply   = 0;                # apply_mod_record
my $dbg_build   = 0;                # build_mod_pkg
my $dbg_verify  = 0;                # verify_db1_checksums
my $dbg_low     = 1;               # low-level structural / per-child checksum detail (quiet unless verbose)

# ---- builder signature (stamped into the build descriptors; shows in Unit Info) ----
my $DEFAULT_BUILDER = 'navMate';                    # neutral fallback when no handle is supplied
my $BUILDER_RE      = qr/^[A-Za-z0-9.-]{1,15}$/;    # 1..15 chars: letters, digits, dash, dot; no spaces

# ---- gzip header fields the stock package uses (pin them so a rebuild varies only by payload) ----
my $GZIP_NAME = "app.bin";
my $GZIP_TIME = 1338299407;
my $GZIP_OS   = 3;

# ---- DL1 / DB1 container layout (the stock E_App_Upg_Uni package format) ----
# The seven DB1 children at their stock file offsets.
my @CHILDREN = (
    [ "ClearFlash",   0x000000C0 ],
    [ "Reset2FSH",    0x00002328 ],
    [ "FactoryReset", 0x000047A0 ],
    [ "App2FSH",      0x00008254 ],
    [ "E80/120_App",  0x0000A6CC ],
    [ "Demo2FSH",     0x008DA900 ],
    [ "DemoSlides",   0x008DCD78 ],
);
my $APP2FSH_IDX = 3;
my $E80_IDX     = 4;
my $E80_OFF     = 0x0000A6CC;       # E80/120_App child -- carries the gzipped application image
my $DEMO2_OFF   = 0x008DA900;       # the child after E80/120_App -- shifts when the image resizes
# span-safe checksum recompute order: spanned/standalone children first (0,2,4,6),
# then the type-1 writers whose payload spans the child after them (1,3,5).
my @ORDER = (0, 2, 4, 6, 1, 3, 5);



#----------------------------------------------------------
# API   (published entry points; exported)
#----------------------------------------------------------


sub extract_app_image
    # ($pkg_path [,$progress]) -> the inflated application image bytes, or undef.
    # Locates the gzip stream inside the E80/120_App child by walking the container
    # (header dword2 -> transition record -> gz offset/length), then inflates it.
{
    my ($pkg_path, $progress) = @_;

    _phase($progress, "Reading package", 0, 3);
    my $pkg = _slurp($pkg_path);
    return _fail($progress, "cannot read package $pkg_path")             if !defined $pkg;
    return _fail($progress, "not an E80 application package (too small)") if length($pkg) < $E80_OFF + 0x100;

    # E80/120_App geometry: dword2 (+0x30) spans header+stub to the transition
    # record; the gz stream starts 0x10 past it, its length stored at +0x04.
    my $e80_d2 = _le32(\$pkg, $E80_OFF + 0x30);
    my $trans  = $E80_OFF + 0x94 + $e80_d2;
    my $gz_off = $trans + 0x10;
    my $gzlen  = _le32(\$pkg, $trans + 0x04);
    return _fail($progress, sprintf("implausible gzip length %d at 0x%x", $gzlen, $trans + 4))
        if $gzlen <= 0 || $gz_off + $gzlen > length($pkg);

    my $gz = substr($pkg, $gz_off, $gzlen);
    return _fail($progress, sprintf("expected a gzip stream at 0x%x", $gz_off))
        if substr($gz, 0, 2) ne "\x1f\x8b";

    _phase($progress, "Inflating image", 1, 3);
    my $image;
    return _fail($progress, "gunzip failed: $GunzipError") if !gunzip(\$gz => \$image);

    _phase($progress, "Done", 3, 3);
    display($dbg_extract, 0, sprintf("extract_app_image: %s -> %d bytes (gz %d at 0x%x)",
        $pkg_path, length($image), $gzlen, $gz_off));
    return $image;
}


sub apply_mod_record
    # ($record_path, \$image [,$progress]) -> 1 on success, 0 on failure.
    # Parses a mods/e80_mod<NNN>.txt record (edit blocks only; annotation
    # directives are ignored here) and applies the byte edits to $$image_ref IN
    # MEMORY. Verify-all-then-write: every region's SHA-256 is checked against the
    # record's <old_hash> before any write; idempotent (a region already equal to
    # the new bytes is skipped); any other mismatch aborts with no writes.
{
    my ($record_path, $image_ref, $progress) = @_;

    return _fail($progress, "apply_mod_record: image => \\\$bytes required") || 0
        if !$image_ref || ref($image_ref) ne 'SCALAR';

    _phase($progress, "Reading mod record", 0, 2);
    my ($recs, $err) = _parse_record($record_path);
    return _fail($progress, $err) || 0 if !$recs;

    # verify ALL regions before writing anything
    my @todo;
    for my $r (@$recs)
    {
        my $cur = substr(${$image_ref}, $r->{off}, $r->{len});
        return _fail($progress, sprintf("region at 0x%08x len %d: short image (have %d bytes)",
            $r->{off}, $r->{len}, length(${$image_ref}))) || 0
            if length($cur) != $r->{len};
        if ($cur eq $r->{new})
        {
            display($dbg_apply, 1, sprintf("SKIP  off=0x%08x len=%-4d : already applied", $r->{off}, $r->{len}));
            next;
        }
        my $curhash = sha256_hex($cur);
        return _fail($progress, sprintf(
            "region at 0x%08x len %d: SHA-256 mismatch -- NO writes made\n  expected old %s\n  found        %s",
            $r->{off}, $r->{len}, $r->{oldhash}, $curhash)) || 0
            if $curhash ne $r->{oldhash};
        push @todo, $r;
    }

    # all verified; apply
    _phase($progress, "Applying edits", 1, 2);
    for my $r (@todo)
    {
        substr(${$image_ref}, $r->{off}, $r->{len}) = $r->{new};
        display($dbg_apply, 1, sprintf("WROTE off=0x%08x len=%-4d", $r->{off}, $r->{len}));
    }

    _phase($progress, "Done", 2, 2);
    display($dbg_apply, 0, sprintf("apply_mod_record: %s : %d record(s), %d written, %d skipped",
        $record_path, scalar(@$recs), scalar(@todo), scalar(@$recs) - scalar(@todo)));
    return 1;
}


sub build_mod_pkg
    # (%args) -> the output .pkg path, or undef. Args:
    #   stock      => stock package path (read-only: static container + geometry)
    #   image      => \$image_bytes (the patched application image to package)
    #   label      => filename-safe label, e.g. "mod002"  -> E_App_Upg_Uni.<label>.pkg
    #   outdir     => directory to write the output package into
    #   builder    => builder signature (see below); empty/undef -> "navMate"
    #   version    => optional app version to relabel, e.g. "5.72"
    #   build_time => optional epoch for the build-date descriptor (default: now)
    #   progress   => optional shared progress hash (mutate-only contract)
    #
    # The builder signature is validated /^[A-Za-z0-9.-]{1,15}$/: empty/undef
    # becomes "navMate"; a non-empty value that fails the rule is REFUSED (returns
    # undef, reason via error()/$progress->{error}). It is rendered on the unit's
    # Unit Info screen. build_time exists so a build is reproducible: pin it (and
    # builder) to reproduce a prior package byte-for-byte.
{
    my (%a) = @_;
    my $progress = $a{progress};

    my $stock   = $a{stock};
    my $img_ref = $a{image};
    my $label   = $a{label};
    my $outdir  = $a{outdir};
    my $version = $a{version};

    return _fail($progress, "build_mod_pkg: image => \\\$bytes required")
        if !$img_ref || ref($img_ref) ne 'SCALAR';
    return _fail($progress, "build_mod_pkg: label required") if !defined $label || $label eq '';
    return _fail($progress, "label must be filename-safe, got '$label'") if $label !~ /^[\w.-]+$/;
    return _fail($progress, "build_mod_pkg: outdir required") if !defined $outdir || $outdir eq '';
    return _fail($progress, "version must be digits/dots, got '$version'")
        if defined $version && $version ne '' && $version !~ /^[0-9.]+$/;

    my $builder = _validate_builder($a{builder});
    return _fail($progress, "builder handle '" . (defined $a{builder} ? $a{builder} : '') . "' is invalid"
        . " (allowed: letters, digits, '-' and '.'; 1-15 chars; no spaces)") if !defined $builder;

    my $build_time = defined($a{build_time}) ? $a{build_time} : time();
    my $DATE = strftime("%a %d %b %Y %H:%M:%S GMT", gmtime($build_time));

    _phase($progress, "Reading stock package", 0, 5);
    my $orig = _slurp($stock);
    return _fail($progress, "cannot read stock package $stock") if !defined $orig;

    # learn E80/120_App geometry + carve the static container pieces (header + stub)
    my $e80_d2   = _le32(\$orig, $E80_OFF + 0x30);
    my $e80_hdr  = substr($orig, $E80_OFF, 0x94);
    my $e80_stub = substr($orig, $E80_OFF + 0x94, $e80_d2 + 0x10);

    # gzip the patched image (stock header fields to minimize variation)
    _phase($progress, "Compressing image", 1, 5);
    my $img = ${$img_ref};
    my $gz;
    gzip(\$img => \$gz, -Level => 9, Name => $GZIP_NAME, Time => $GZIP_TIME, OS_Code => $GZIP_OS)
        or return _fail($progress, "gzip failed: $GzipError");

    # round-trip: the embedded gzip must inflate back to the patched image bit-exact
    my $reinf;
    gunzip(\$gz => \$reinf) or return _fail($progress, "gunzip(re-gzip) failed: $GunzipError");
    return _fail($progress, "internal: re-gzip does not round-trip bit-exact")
        if sha256_hex($reinf) ne sha256_hex($img);

    # --- rebuild the DL1 around the new gzip ---
    _phase($progress, "Rebuilding package", 2, 5);
    my $newlen      = length($gz);
    my $e80_cov_rel = 0x94 + $e80_d2 + 0x10 + $newlen;
    my $e80_cov_end = $E80_OFF + $e80_cov_rel;
    my $align       = (4 - ($e80_cov_end & 3)) & 3;

    my $e80_block = $e80_hdr . $e80_stub . $gz . ("\x00" x $align);
    _setle32(\$e80_block, 0x94 + $e80_d2 + 0x04, $newlen);   # transition gzip length
    _setle32(\$e80_block, 0x34, 0x10 + $newlen);             # E80 header dword[3]

    my $ref = substr($orig, 0, $E80_OFF) . $e80_block . substr($orig, $DEMO2_OFF - 4);

    my $new_demo2 = $E80_OFF + length($e80_block) + 4;
    my $delta     = $new_demo2 - $DEMO2_OFF;

    my $app2_off  = $CHILDREN[$APP2FSH_IDX][1];
    my $app2_data = $e80_cov_rel;
    _setle32(\$ref, $app2_off + 0x34, 0x10 + $app2_data);            # App2FSH header dword[3]
    my $app2_d2   = _le32(\$ref, $app2_off + 0x30);
    _setle32(\$ref, $app2_off + 0x94 + $app2_d2 + 0x04, $app2_data); # App2FSH record word1
    my $app2_cov  = 0x94 + $app2_d2 + (0x10 + $app2_data);
    _setle32(\$ref, $app2_off - 4, ($app2_cov + 3) & ~3);           # App2FSH length-prefix

    my @offs;
    for my $c (@CHILDREN)
    {
        my ($name, $off) = @$c;
        $off += $delta if $off >= $DEMO2_OFF;
        push @offs, [ $name, $off ];
    }

    # --- relabel build descriptors: builder (+0x60) + date (+0x40) ---
    _phase($progress, "Relabeling + checksums", 3, 5);
    my $date_field = substr(sprintf("%-31s", $DATE)    . "\0", 0, 32);
    my $mach_field = substr(sprintf("%-15s", $builder) . "\0", 0, 16);
    for my $base (0, map { $_->[1] } @offs)
    {
        substr($ref, $base + 0x40, 32) = $date_field;
        substr($ref, $base + 0x60, 16) = $mach_field;
    }

    # optional version relabel: the app version is the DOB descriptor at header +0x14
    if (defined $version && $version ne '')
    {
        (my $cur = substr($ref, $offs[$E80_IDX][1] + 0x14, 16)) =~ s/\s+$//;
        my $newfield = substr("v$version" . (" " x 16), 0, 16);
        my $n = 0;
        for my $base (0, map { $_->[1] } @offs)
        {
            if (substr($ref, $base + 0x14, 16) =~ /^\Q$cur\E\s*$/)
            {
                substr($ref, $base + 0x14, 16) = $newfield;
                $n++;
            }
        }
        display($dbg_build, 0, "build_mod_pkg: version $cur -> v$version ($n descriptor header(s))");
    }

    # recompute checksums in span-safe order (all child headers just changed)
    _recompute_child(\$ref, $offs[$_][1]) for @ORDER;

    # --- verify + structural audit before writing anything ---
    _phase($progress, "Verifying", 4, 5);
    my ($vok, $vrows) = _verify_rows(\$ref, \@offs);
    for my $row (@$vrows)
    {
        display($dbg_low, 1, sprintf("%-13s hdr %08x/%08x %-4s  pay %08x/%08x %-4s",
            $row->{name}, $row->{hsum}, $row->{hstored}, ($row->{hok} ? "OK" : "FAIL"),
            $row->{psum}, $row->{pstored}, ($row->{pok} ? "OK" : "FAIL")));
    }
    my $aok = _audit(\$ref, \@offs);
    return _fail($progress, sprintf("build verification failed (checksums=%s, audit=%s) -- not written",
        $vok ? "ok" : "FAIL", $aok ? "ok" : "FAIL")) if !$vok || !$aok;

    # --- write ---
    my $out = "$outdir/E_App_Upg_Uni.$label.pkg";
    return _fail($progress, "cannot write $out") if !_spew($out, $ref);

    _phase($progress, "Done", 5, 5);
    display($dbg_build, 0, sprintf("build_mod_pkg: %s : %d bytes, builder=%s, date=%s -> %s",
        $label, length($ref), $builder, $DATE, $out));
    return $out;
}


sub verify_db1_checksums
    # ($pkg_path) -> ($all_ok, \@rows). Walks the seven DB1 children at their STOCK
    # file offsets and checks both the header and payload byte-sum checksums against
    # the values stored in each child. STOCK-layout: a rebuilt/resized package's
    # trailing children shift, so use this on stock-layout packages -- a freshly
    # built package is verified internally by build_mod_pkg. Read-only. Each row is
    # { name, magic, hok, pok, hsum, hstored, psum, pstored }.
{
    my ($pkg_path) = @_;

    my $data = _slurp($pkg_path);
    if (!defined $data)
    {
        error("verify_db1_checksums: cannot read $pkg_path");
        return (0, []);
    }

    my @rows;
    my $all = 1;
    for my $c (@CHILDREN)
    {
        my ($name, $off) = @$c;
        my $d1 = _le32(\$data, $off + 0x2C);
        my $d2 = _le32(\$data, $off + 0x30);
        my $d3 = _le32(\$data, $off + 0x34);
        my $hstored = _le32(\$data, $off + 0x38);
        my $pstored = _le32(\$data, $off + 0x3C);
        # header checksum: bytes [0,0x38) + [0x3C, d1) -- i.e. skip the 4 bytes at 0x38
        my $hsum = _m32(_bytesum(\$data, $off + 0x00, $off + 0x38)
                      + _bytesum(\$data, $off + 0x3C, $off + $d1));
        # payload checksum: bytes [d1, d1 + d2 + d3)
        my $pend = $off + $d1 + $d2 + $d3;
        $pend = length($data) if $pend > length($data);
        my $psum  = _bytesum(\$data, $off + $d1, $pend);
        my $magic = substr($data, $off, 4);
        my $hok   = ($hsum == $hstored);
        my $pok   = ($psum == $pstored);
        $all = 0 if !$hok || !$pok;
        push @rows, { name => $name, magic => $magic, hok => $hok, pok => $pok,
                      hsum => $hsum, hstored => $hstored, psum => $psum, pstored => $pstored };
        display($dbg_verify, 1, sprintf("%-13s %-3s hdr %08x/%08x %-4s  pay %08x/%08x %-4s",
            $name, ($magic eq "DB1 " ? "DB1" : "?"),
            $hsum, $hstored, ($hok ? "OK" : "FAIL"), $psum, $pstored, ($pok ? "OK" : "FAIL")));
    }
    display($dbg_verify, 0, sprintf("verify_db1_checksums: %s : %s",
        $pkg_path, $all ? "14/14 OK" : "FAILURES PRESENT"));
    return ($all, \@rows);
}



#----------------------------------------------------------
# private helpers
#----------------------------------------------------------


sub _parse_record
    # ($path) -> (\@recs, undef) on success, or (undef, $errmsg). Each rec is
    # { off, len, new (packed bytes), oldhash }. The binary patcher reads only the
    # edit blocks; annotation directives (and their '<< ... >>' text) are skipped.
{
    my ($path) = @_;
    return (undef, "no record file: $path") if !-f $path;
    open(my $rf, '<', $path) or return (undef, "open $path: $!");

    my %DIRECTIVE = map { $_ => 1 } qw(func name label sig local param pre plate eol post repeat);
    my @recs;
    my $lno   = 0;
    my $state = 'top';                  # top | prenew | innew
    my $blk;
    while (my $line = <$rf>)
    {
        $lno++;
        $line =~ s/\r?\n$//;
        (my $s = $line) =~ s/^\s+//;
        my $kw = ($s eq '') ? '' : lc((split /\s+/, $s, 2)[0]);

        if ($state eq 'innew')
        {
            if ($kw eq 'end')
            {
                return (undef, "line $lno: edit block (line $blk->{lno}) has no 'new' bytes")
                    if !length($blk->{new});
                return (undef, "line $lno: non-hex new bytes (block line $blk->{lno})")
                    if $blk->{new} !~ /^[0-9a-f]+$/;
                return (undef, "line $lno: odd hex digit count (block line $blk->{lno})")
                    if length($blk->{new}) % 2;
                my $nbytes = length($blk->{new}) / 2;
                return (undef, sprintf("line %d: new byte count %d != declared length %d (block line %d)",
                    $lno, $nbytes, $blk->{len}, $blk->{lno})) if $nbytes != $blk->{len};
                push @recs, { off => $blk->{off}, len => $blk->{len},
                              new => pack('H*', $blk->{new}), oldhash => $blk->{oldhash} };
                ($state, $blk) = ('top', undef);
                next;
            }
            next if $s eq '' || $s =~ /^#/;             # banner / # label: / prose lines
            (my $data = $s) =~ s/#.*//;                 # strip trailing comment
            $data =~ s/\s+//g;
            if (length $data)
            {
                return (undef, "line $lno: non-hex listing data '$data'") if $data !~ /^[0-9a-fA-F]+$/;
                $blk->{new} .= lc $data;
            }
            next;
        }

        if ($state eq 'prenew')
        {
            if ($kw eq 'new') { $state = 'innew'; next; }
            next;                                       # optional rationale / comments before 'new'
        }

        # ---- state: top ----
        next if $s eq '' || $s =~ /^#/;
        if ($DIRECTIVE{$kw})                            # skip directive (+ any '<< ... >>' block)
        {
            if ($s =~ /<</ && $s !~ />>/)
            {
                while (my $cont = <$rf>) { $lno++; last if $cont =~ />>/; }
            }
            next;
        }
        if ($kw eq 'edit')
        {
            my @f = split /\s+/, $s;
            return (undef, "line $lno: 'edit' needs <addr> <file_offset> <length> <old_hash>") if @f < 5;
            my $foff    = $f[2];
            my $len     = $f[3];
            my $oldhash = lc $f[4];
            return (undef, "line $lno: length must be an integer, got '$len'") if $len !~ /^\d+$/;
            return (undef, "line $lno: old_hash must be 64 hex (full SHA-256), got '$f[4]'")
                if $oldhash !~ /^[0-9a-f]{64}$/;
            my $off = ($foff =~ /^0x/i) ? hex($foff) : $foff + 0;
            $blk = { off => $off, len => $len + 0, oldhash => $oldhash, new => '', lno => $lno };
            $state = 'prenew';
            next;
        }
        return (undef, "line $lno: unexpected token '$kw' at top level");
    }
    close $rf;
    return (undef, "unterminated edit block started at line " . ($blk ? $blk->{lno} : '?')) if $state ne 'top';
    return (undef, "no edit records in $path") if !@recs;
    return (\@recs, undef);
}


sub _validate_builder
    # ($handle) -> a valid builder string, or undef if a non-empty handle is invalid.
    # empty / undef -> the neutral default.
{
    my ($b) = @_;
    return $DEFAULT_BUILDER if !defined($b) || $b eq '';
    return undef if $b !~ $BUILDER_RE;
    return $b;
}


sub _recompute_child
    # (\$buf, $off) -- recompute a child's payload checksum (+0x3C) then its header
    # checksum (+0x38). The header checksum covers the payload-checksum field, so
    # the payload sum must be stored first.
{
    my ($r, $off) = @_;
    my $d1 = _le32($r, $off + 0x2C);
    my $d2 = _le32($r, $off + 0x30);
    my $d3 = _le32($r, $off + 0x34);
    my $end = $off + $d1 + $d2 + $d3;
    $end = length($$r) if $end > length($$r);
    _setle32($r, $off + 0x3C, _bytesum($r, $off + $d1, $end));
    _setle32($r, $off + 0x38, _m32(_bytesum($r, $off, $off + 0x38) + _bytesum($r, $off + 0x3C, $off + $d1)));
}


sub _verify_rows
    # (\$buf, \@offsets) -> ($all_ok, \@rows). Each row is
    # { name, hok, pok, hsum, hstored, psum, pstored }.
{
    my ($ref, $offsets) = @_;
    my @rows;
    my $all = 1;
    for my $c (@$offsets)
    {
        my ($name, $off) = @$c;
        my $d1 = _le32($ref, $off + 0x2C);
        my $d2 = _le32($ref, $off + 0x30);
        my $d3 = _le32($ref, $off + 0x34);
        my $hstored = _le32($ref, $off + 0x38);
        my $pstored = _le32($ref, $off + 0x3C);
        my $hsum = _m32(_bytesum($ref, $off + 0x00, $off + 0x38) + _bytesum($ref, $off + 0x3C, $off + $d1));
        my $pend = $off + $d1 + $d2 + $d3;
        $pend = length($$ref) if $pend > length($$ref);
        my $psum = _bytesum($ref, $off + $d1, $pend);
        my $hok  = ($hsum == $hstored);
        my $pok  = ($psum == $pstored);
        $all = 0 if !$hok || !$pok;
        push @rows, { name => $name, hok => $hok, pok => $pok,
                      hsum => $hsum, hstored => $hstored, psum => $psum, pstored => $pstored };
    }
    return ($all, \@rows);
}


sub _audit
    # (\$buf, \@offsets) -> 1 if the structural audit passes, else 0. Checks 4-byte
    # alignment + header/record length agreement per child, and replays the DL1
    # envelope's length-prefixed DOB walk, asserting every block lands on "DB1 ".
{
    my ($ref, $offsets) = @_;
    my $ok = 1;
    for my $c (@$offsets)
    {
        my ($name, $off) = @$c;
        my $d2 = _le32($ref, $off + 0x30);
        my $d3 = _le32($ref, $off + 0x34);
        my $rec  = $off + 0x94 + $d2;
        my $type = _le32($ref, $rec) & 0xFFFF;
        my $w1   = _le32($ref, $rec + 0x04);
        $ok = 0 if ($off & 3) != 0;
        if ($type == 1 || $type == 3)
        {
            $ok = 0 if $w1 != $d3 - 0x10;
        }
    }
    my $count = _le32($ref, 0x38);
    my $toff  = _le32($ref, 0x3C);
    my $p   = $toff;
    my $len = _le32($ref, $p);
    $p += 4;
    for (my $k = 0; $k < $count; $k++)
    {
        $ok = 0 if substr($$ref, $p, 4) ne "DB1 ";
        last if $k == $count - 1;
        $p  += $len;
        $len = _le32($ref, $p);
        $p  += 4;
    }
    return $ok;
}


sub _slurp
    # ($path) -> file bytes, or undef.
{
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $d = <$fh>;
    close $fh;
    return $d;
}


sub _spew
    # ($path, $bytes) -> 1 on success, 0 on failure.
{
    my ($p, $d) = @_;
    open(my $fh, '>:raw', $p) or return 0;
    print $fh $d;
    close $fh;
    return 1;
}


sub _le32    { unpack("V", substr(${$_[0]}, $_[1], 4)) }
sub _setle32 { my ($r, $o, $v) = @_; substr($$r, $o, 4) = pack("V", $v & 0xFFFFFFFF) }
sub _m32     { $_[0] & 0xFFFFFFFF }

sub _bytesum
    # (\$buf, $start, $end) -> sum of bytes in [start, end), mod 2^32.
{
    my ($r, $s, $e) = @_;
    my $x = 0;
    $x += $_ for unpack("C*", substr($$r, $s, $e - $s));
    return _m32($x);
}


sub _phase
    # ($progress, $label, $done, $total) -- coarse progress update (no-op without $progress).
{
    my ($progress, $label, $done, $total) = @_;
    return if !$progress || ref($progress) ne 'HASH';
    $progress->{label} = $label;
    $progress->{done}  = $done;
    $progress->{total} = $total;
}


sub _fail
    # ($progress, $msg) -- log the failure, record it in $progress, and return undef.
{
    my ($progress, $msg) = @_;
    error($msg);
    $progress->{error} = $msg if $progress && ref($progress) eq 'HASH';
    return undef;
}



1;
