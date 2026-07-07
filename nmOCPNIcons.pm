#-------------------------------------------------------------------------
# nmOCPNIcons.pm
#-------------------------------------------------------------------------
# The OpenCPN-icon picker for the winOCPN spoke editor, plus its persistent
# raster cache.  This is the wxPerl analog of OpenCPN's own OCPNIconCombo
# (gui/src/mark_info.cpp) -- a Wx::OwnerDrawnComboBox whose row height auto-fits
# the icon bitmap, populated from the vocabulary the plugin reports up the wire
# (navOCPN's icon library cache, protocol sec 7).
#
# SOURCING (never OpenCPN's filesystem -- the plugin is the sole conduit):
#   navOCPN::loadIconLibrary($hash) -> the cached ocpn_icons[] for a hash, each
#   entry { name, description, fmt, data_b64, byte_hash, builtin? }.  TODAY the
#   wire is names-only (fmt:"none", empty bytes) so the picker shows a text-only
#   row per icon.  When oe ships the Direction-A image build the entries become
#   fmt:"png" + a 48x48 RGBA data_b64 (co-design Turn 27/28); this module then
#   decodes+caches the PNG and the SAME picker shows the glyph -- no code change,
#   no SVG anywhere (navMate is a raster app end to end).
#
# GROUPING: built-ins first, then user icons, each alphabetical by description
# (co-design Turn 28).  We group on the per-entry `builtin` flag the plugin
# supplies (NOT wire order -- g_bUserIconsFirst can reorder the array); absent
# flag defaults to built-in (today's names-only set is all foreign built-ins).
#
# RASTER CACHE: decoded PNGs persist under $data_dir/ocpn_icons/raster/<byte_hash>.png
# -- keyed by the content hash so identical bitmaps dedupe and never rebuild.

package nmOCPNIcons;
use strict;
use warnings;
use MIME::Base64 qw(decode_base64);
use Wx qw(:everything);
use Pub::Utils qw(display warning error $data_dir);
use navOCPN;

my $PICKER_PX      = 48;   # canonical Direction-A raster size on the wire (Turn 27)
my $PICKER_CELL_PX = 20;   # displayed picker cell -- must fit the ~23px combo control
                           # (matches the E80 sym picker); the 48px raster is cached
                           # full-res and scaled DOWN for display.


#-------------------------------------------------------------------------
# raster cache -- a decoded PNG bitmap per icon byte_hash, under $data_dir
#-------------------------------------------------------------------------

sub _rasterDir
{
	my $dir = "$data_dir/ocpn_icons/raster";
	mkdir("$data_dir/ocpn_icons") if !-d "$data_dir/ocpn_icons";
	mkdir($dir)                   if !-d $dir;
	return $dir;
}

# _trimAlpha($img) -- crop an image to its non-transparent content bounding box.
# OpenCPN renders each mark glyph centred in a big transparent 48px frame (a glyph
# is often only ~20% of the canvas), so without trimming a cell-scaled icon looks
# tiny.  Returns the cropped image (or the original if fully opaque / empty).
sub _trimAlpha
{
	my ($img) = @_;
	return $img if !$img->HasAlpha();
	my ($w, $h) = ($img->GetWidth(), $img->GetHeight());
	my ($minx, $miny, $maxx, $maxy) = ($w, $h, -1, -1);
	for my $y (0 .. $h - 1)
	{
		for my $x (0 .. $w - 1)
		{
			next if $img->GetAlpha($x, $y) <= 16;
			$minx = $x if $x < $minx; $maxx = $x if $x > $maxx;
			$miny = $y if $y < $miny; $maxy = $y if $y > $maxy;
		}
	}
	return $img if $maxx < $minx || $maxy < $miny;                     # fully transparent
	return $img if $minx == 0 && $miny == 0 && $maxx == $w-1 && $maxy == $h-1;  # no margin
	return $img->GetSubImage(Wx::Rect->new($minx, $miny, $maxx - $minx + 1, $maxy - $miny + 1));
}

# iconBitmap($entry) -- a cell-sized Wx::Bitmap for one library entry (the glyph
# trimmed of its transparent frame and scaled to fill PICKER_CELL_PX), or undef
# for a names-only entry.  Two-tier disk cache under $data_dir: the full-res 48px
# PNG (<hash>.png) and the trimmed display bitmap (<hash>_c<cell>.png), so the
# per-pixel trim runs once per icon EVER, not per pane refresh.
sub iconBitmap
{
	my ($entry, $px) = @_;
	$px = $PICKER_CELL_PX if !$px;
	return undef if ref($entry) ne 'HASH';
	my $fmt = $entry->{fmt} // 'none';
	my $b64 = $entry->{data_b64} // '';
	return undef if $fmt ne 'png' || $b64 eq '';

	my $key = $entry->{byte_hash} // '';
	$key =~ s/[^0-9a-fA-F]//g;   # defensive: hash is hex, never a path
	$key = length($key) ? $key : ('n' . length($b64));   # fallback key if no hash

	my $cell = _rasterDir() . "/${key}_c${px}.png";
	if (!-f $cell)
	{
		my $src = _rasterDir() . "/$key.png";
		if (!-f $src)
		{
			my $png = eval { decode_base64($b64) };
			return undef if !defined $png || $png eq '';
			open(my $fh, '>', $src) or do { warning(0,0,"nmOCPNIcons: cannot write $src: $!"); return undef; };
			binmode($fh); print $fh $png; close($fh);
		}
		my $img = eval { Wx::Image->new($src, wxBITMAP_TYPE_PNG) };
		return undef if !$img || !$img->IsOk();
		$img = _trimAlpha($img);
		$img = $img->Scale($px, $px, wxIMAGE_QUALITY_HIGH);
		eval { $img->SaveFile($cell, wxBITMAP_TYPE_PNG); };
	}
	my $bmp = eval { Wx::Bitmap->new($cell, wxBITMAP_TYPE_PNG) };
	return ($bmp && $bmp->IsOk()) ? $bmp : undef;
}


# bitmapMapByName($hash, $px) -- { icon_name => Wx::Bitmap } at $px for every png
# entry in the library.  winOCPN uses this for the tree swatch (15px) so a mark's
# row shows its actual OpenCPN glyph, not a derived E80 sym.
sub bitmapMapByName
{
	my ($hash, $px) = @_;
	my $lib = navOCPN::loadIconLibrary($hash);
	my $icons = (ref($lib) eq 'HASH' && ref($lib->{icons}) eq 'ARRAY') ? $lib->{icons} : [];
	my %map;
	for my $e (@$icons)
	{
		next if ref($e) ne 'HASH' || ($e->{name} // '') eq '';
		my $bmp = iconBitmap($e, $px);
		$map{$e->{name}} = $bmp if $bmp;
	}
	return \%map;
}


#-------------------------------------------------------------------------
# picker model -- the ordered [ {name, description, builtin, bitmap}, ... ]
#-------------------------------------------------------------------------
# built-ins first then user icons, each alphabetical by description (Turn 28).

sub pickerModel
{
	my ($hash) = @_;
	my $lib = navOCPN::loadIconLibrary($hash);
	my $icons = (ref($lib) eq 'HASH' && ref($lib->{icons}) eq 'ARRAY') ? $lib->{icons} : [];
	my @model;
	for my $e (@$icons)
	{
		next if ref($e) ne 'HASH';
		my $name = $e->{name} // '';
		next if $name eq '';
		push @model, {
			name        => $name,
			description => (defined($e->{description}) && $e->{description} ne '') ? $e->{description} : $name,
			builtin     => exists($e->{builtin}) ? ($e->{builtin} ? 1 : 0) : 1,   # absent -> built-in
			bitmap      => iconBitmap($e),
		};
	}
	@model = sort {
		   ($b->{builtin} <=> $a->{builtin})                              # built-ins first
		|| (lc($a->{description}) cmp lc($b->{description}))              # then alpha by label
		|| (lc($a->{name})        cmp lc($b->{name}))
	} @model;
	return \@model;
}


#-------------------------------------------------------------------------
# makeOCPNIconPicker($parent, $pos, $size, $hash) -- the populated combo
#-------------------------------------------------------------------------
# The value the picker carries is the icon NAME (the wire `icon` string), not an
# index -- getIconName / setIconByName wrap that.  $hash defaults to the live
# icon_hash (loadIconLibrary's own default).

sub makeOCPNIconPicker
{
	my ($parent, $pos, $size, $hash) = @_;
	my $combo = nmOCPNIcons::Combo->new($parent, $pos, $size);
	$combo->loadModel(pickerModel($hash));
	return $combo;
}


#=========================================================================
# nmOCPNIcons::Combo -- the icon picker (Wx::BitmapComboBox)
#=========================================================================
# Uses Wx::BitmapComboBox -- the SAME proven widget navMate's E80 sym picker
# uses (nmResources::makeSymComboBox) -- rather than an owner-drawn subclass,
# because BitmapComboBox natively renders bitmap + label per row and sizes the
# row to the bitmap, with no Perl-side draw callbacks to depend on.  The value
# the picker carries is the icon NAME (getIconName/setIconByName); each row shows
# the 48x48 glyph (a blank of the same size for names-only entries, so row height
# stays uniform regardless of order).

package nmOCPNIcons::Combo;
use strict;
use warnings;
use Wx qw(:everything);
use base qw(Wx::BitmapComboBox);

my $_blank_bmp;
sub _blankBmp { $_blank_bmp //= Wx::Bitmap->new($PICKER_CELL_PX, $PICKER_CELL_PX); return $_blank_bmp; }

sub new
{
	my ($class, $parent, $pos, $size) = @_;
	my $self = $class->SUPER::new($parent, -1, '',
		$pos  // wxDefaultPosition,
		$size // wxDefaultSize,
		[], wxCB_READONLY);
	$self->{_names}   = [];   # row -> icon name
	$self->{_by_name} = {};   # icon name -> row
	return $self;
}

# loadModel(\@model) -- (re)populate from pickerModel() output.
sub loadModel
{
	my ($self, $model) = @_;
	$self->Clear();
	# NB: Wx::BitmapComboBox::Append does NOT return the row index in this wxPerl
	# (same as makeSymComboBox, which ignores it) -- track the index ourselves.
	my $row = 0;
	for my $m (@{$model // []})
	{
		my $bmp = $m->{bitmap};
		$bmp = _blankBmp() if !($bmp && $bmp->IsOk());
		$self->Append($m->{description}, $bmp);
		$self->{_names}[$row]         = $m->{name};
		$self->{_by_name}{$m->{name}} = $row;
		$row++;
	}
	return $self;
}

# getIconName / setIconByName -- the picker's value IS the wire icon name.
sub getIconName
{
	my ($self) = @_;
	my $sel = $self->GetSelection();
	return '' if !defined $sel || $sel < 0;
	return $self->{_names}[$sel] // '';
}

sub setIconByName
{
	my ($self, $name) = @_;
	$name = '' if !defined $name;
	my $row = $self->{_by_name}{$name};
	if (defined $row) { $self->SetSelection($row); return 1; }
	$self->SetSelection(-1);   # icon not in the live vocabulary
	return 0;
}

sub Clear
{
	my ($self) = @_;
	$self->SUPER::Clear();
	$self->{_names}   = [];
	$self->{_by_name} = {};
}


1;
