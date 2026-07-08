#!/usr/bin/perl
#---------------------------------------------
# winOCPNSymMap.pm
#---------------------------------------------
# Modal dialog editing the sym (0..35) <-> OpenCPN IconName map (protocol
# sec 7), reached from the OpenCPN menu.  Two knobs, both persisted in the
# key_values 'sym_icons' row as { icons => [...36...], default_sym => N }:
#
#   * 36 forward rows -- sym -> OpenCPN icon.  Used on PUSH-OUT
#     (navDB::iconForSym): the icon a navMate-origin mark shows in OpenCPN.
#     Editing a row also reconfigures the REVERSE (icon -> sym) for that icon,
#     since navDB::symForIcon inverts the forward map.
#
#   * one default sym -- the reverse catch-all.  Every OpenCPN icon NOT named
#     in the 36 rows (OpenCPN's vocabulary is ~10x larger) ingests to this sym
#     (navDB::ocpnDefaultSym).  Display-only for foreign marks (their real
#     IconName round-trips via spoke_shadow), but the only symbol they carry if
#     later pushed to the E80 or FSH.
#
#   showOCPNSymMapDialog($parent) -> 1 if saved, 0 if cancelled / unchanged.
#
# Each row shows BOTH glyphs -- the E80 sym bitmap and the OpenCPN icon bitmap --
# with a "Change..." button that opens ONE shared BitmapComboBox picker on demand.
# The 36 rows are therefore static bitmaps + buttons (cheap), not 36 populated
# BitmapComboBoxes (which was ~30s to open against a real library).  Glyphs come
# from nmOCPNIcons' shared in-memory bitmap cache.  Combos swallow the mouse wheel
# (_noWheel) so scrolling the list never silently changes a value.

package winOCPNSymMap;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON);
use Pub::Utils qw(display warning error my_encode_json);
use navDB;
use n_defs;
use nmDialogs qw(confirmDialog);
use nmResources qw(symBitmap makeSymComboBox);
use nmOCPNIcons;
use Pub::Ray::NET::a_utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw( showOCPNSymMapDialog );
}


my $ICON_PX = 20;   # OpenCPN icon swatch size (matches the E80 sym bitmap scale)


my $_pick_pos;      # remembered screen position of the Change... picker popup


# _pickIcon($parent, $current) -- modal single-icon picker (a BitmapComboBox that
# shows the glyphs).  Returns the chosen icon name, or undef if cancelled.  Opens
# at its last position (first time: beside the parent so it does not cover it) and
# remembers wherever the user leaves it, so repeated Change... clicks stay put.
sub _pickIcon
{
	my ($parent, $current) = @_;
	my $pos = $_pick_pos;
	if (!$pos)
	{
		my $pp = $parent->GetScreenPosition();
		my $ps = $parent->GetSize();
		$pos = Wx::Point->new($pp->x + $ps->GetWidth() + 12, $pp->y + 60);
	}
	my $dlg = Wx::Dialog->new($parent, -1, 'Choose OpenCPN Icon',
		$pos, [320, 130], wxDEFAULT_DIALOG_STYLE);
	my $v = Wx::BoxSizer->new(wxVERTICAL);
	my $combo = nmOCPNIcons::makeOCPNIconPicker($dlg, wxDefaultPosition, [280, -1]);
	$combo->setIconByName($current);
	nmResources::noComboWheel($combo);
	$v->Add($combo, 0, wxALL, 12);
	my $br = Wx::BoxSizer->new(wxHORIZONTAL);
	$br->AddStretchSpacer(1);
	$br->Add(Wx::Button->new($dlg, wxID_CANCEL, 'Cancel'), 0, wxRIGHT, 8);
	$br->Add(Wx::Button->new($dlg, wxID_OK,     'OK'),     0);
	$v->Add($br, 0, wxEXPAND | wxALL, 10);
	$dlg->SetSizer($v);
	my $rc = $dlg->ShowModal();
	my $chosen = ($rc == wxID_OK) ? $combo->getIconName() : undef;
	$_pick_pos = $dlg->GetScreenPosition();   # remember where the user leaves it
	$dlg->Destroy();
	return $chosen;
}


sub showOCPNSymMapDialog
{
	my ($parent) = @_;

	# whole vocabulary's swatch bitmaps, built once (shared in-memory cache)
	my $bmp_by_name = nmOCPNIcons::bitmapMapByName(undef, $ICON_PX);
	my $blank = Wx::Bitmap->new($ICON_PX, $ICON_PX);
	my $swatch = sub {
		my ($name) = @_;
		my $b = $bmp_by_name->{$name // ''};
		return ($b && $b->IsOk()) ? $b : $blank;
	};

	my $dlg = Wx::Dialog->new($parent, -1, 'OpenCPN Symbol Map',
		wxDefaultPosition, [540, 600],
		wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);
	$dlg->Freeze();

	my $vsizer = Wx::BoxSizer->new(wxVERTICAL);

	$vsizer->Add(Wx::StaticText->new($dlg, -1,
		"Each navMate sym (left) maps to one OpenCPN icon (right) on push-out;\n" .
		"on ingest the map runs in reverse, with unlisted OpenCPN icons taking\n" .
		"the default sym below.  Foreign marks keep their own icon regardless."),
		0, wxALL, 10);

	# 36 forward rows: [sym swatch + label] [icon swatch + name] [Change...]
	my $scroll = Wx::ScrolledWindow->new($dlg, -1);
	$scroll->SetScrollRate(0, 16);
	my $grid = Wx::FlexGridSizer->new(scalar(@SYM_DEFAULT_ICONS), 3, 4, 10);
	my @rows;
	for my $sym (0 .. $#SYM_DEFAULT_ICONS)
	{
		my $left = Wx::BoxSizer->new(wxHORIZONTAL);
		$left->Add(Wx::StaticBitmap->new($scroll, -1, symBitmap($sym)),
			0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 6);
		$left->Add(Wx::StaticText->new($scroll, -1,
			sprintf('%2d - %s', $sym, $E80_SYMS[$sym])),
			0, wxALIGN_CENTER_VERTICAL);
		$grid->Add($left, 0, wxALIGN_CENTER_VERTICAL | wxLEFT, 10);

		my $name = navDB::iconForSym($sym);
		my $mid  = Wx::BoxSizer->new(wxHORIZONTAL);
		my $ibmp = Wx::StaticBitmap->new($scroll, -1, $swatch->($name));
		my $ilbl = Wx::StaticText->new($scroll, -1, $name, wxDefaultPosition, [150, -1]);
		$mid->Add($ibmp, 0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 6);
		$mid->Add($ilbl, 0, wxALIGN_CENTER_VERTICAL);
		$grid->Add($mid, 0, wxALIGN_CENTER_VERTICAL);

		my $btn = Wx::Button->new($scroll, -1, 'Change...', wxDefaultPosition, [90, -1]);
		$grid->Add($btn, 0, wxRIGHT, 10);

		my $row = { name => $name, bmp => $ibmp, lbl => $ilbl };
		$rows[$sym] = $row;
		EVT_BUTTON($dlg, $btn, sub {
			my $chosen = _pickIcon($dlg, $row->{name});
			return if !defined $chosen || $chosen eq '' || $chosen eq $row->{name};
			$row->{name} = $chosen;
			$row->{lbl}->SetLabel($chosen);
			$row->{bmp}->SetBitmap($swatch->($chosen));
		});
	}
	$scroll->SetSizer($grid);
	$scroll->FitInside();
	$vsizer->Add($scroll, 1, wxEXPAND | wxLEFT | wxRIGHT, 4);

	# Reverse catch-all: default sym for every unmapped OpenCPN icon
	my $def_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$def_row->Add(Wx::StaticText->new($dlg, -1, 'Default sym for unmapped icons:'),
		0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 8);
	my $def_combo = makeSymComboBox($dlg, wxDefaultPosition, [240, -1]);
	$def_combo->SetSelection(navDB::ocpnDefaultSym());
	$def_row->Add($def_combo, 0, wxALIGN_CENTER_VERTICAL);
	$vsizer->Add($def_row, 0, wxALL, 10);

	# Buttons
	my $reset_btn  = Wx::Button->new($dlg, -1,          'Reset to Defaults');
	my $cancel_btn = Wx::Button->new($dlg, wxID_CANCEL, 'Cancel');
	my $save_btn   = Wx::Button->new($dlg, wxID_OK,     'Save');
	my $btn_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$btn_row->Add($reset_btn, 0);
	$btn_row->AddStretchSpacer(1);
	$btn_row->Add($cancel_btn, 0, wxRIGHT, 8);
	$btn_row->Add($save_btn, 0);
	$vsizer->Add($btn_row, 0, wxEXPAND | wxLEFT | wxRIGHT | wxBOTTOM, 10);

	$dlg->SetSizer($vsizer);

	my $applied = 0;

	EVT_BUTTON($dlg, $reset_btn, sub {
		return if !confirmDialog($dlg,
			"Reset all 36 icon mappings and the default sym to their factory\n" .
			"defaults?\n\nThis only refills the dialog -- click Save to apply.",
			'Reset to Defaults');
		for my $sym (0 .. $#SYM_DEFAULT_ICONS)
		{
			my $d = $SYM_DEFAULT_ICONS[$sym];
			$rows[$sym]{name} = $d;
			$rows[$sym]{lbl}->SetLabel($d);
			$rows[$sym]{bmp}->SetBitmap($swatch->($d));
		}
		$def_combo->SetSelection($WP_DEFAULT_SYMS{$WP_TYPE_NAV});
	});

	EVT_BUTTON($dlg, wxID_OK, sub {
		my @icons = map { $rows[$_]{name} ne '' ? $rows[$_]{name} : $SYM_DEFAULT_ICONS[$_] }
			0 .. $#SYM_DEFAULT_ICONS;
		my $default_sym = $def_combo->GetSelection();
		$default_sym = $WP_DEFAULT_SYMS{$WP_TYPE_NAV} if $default_sym < 0;

		# diff vs the in-effect map
		my $changed = ($default_sym != navDB::ocpnDefaultSym()) ? 1 : 0;
		$changed++ for grep { $icons[$_] ne navDB::iconForSym($_) } 0 .. $#SYM_DEFAULT_ICONS;
		if (!$changed)
		{
			$dlg->EndModal(wxID_CANCEL);
			return;
		}

		my $dbh = connectDB();
		if (!$dbh)
		{
			error("winOCPNSymMap: connectDB failed");
			return;
		}
		$dbh->do("UPDATE key_values SET value=? WHERE key='sym_icons'",
			[my_encode_json({ icons => \@icons, default_sym => $default_sym })]);
		loadSymMap($dbh);
		disconnectDB($dbh);

		display(0, 0, "winOCPNSymMap: saved sym <-> OpenCPN icon map ($changed change(s))");
		$applied = 1;
		$dlg->EndModal(wxID_OK);
	});

	nmResources::disableComboWheel($dlg);
	$dlg->Thaw();
	$dlg->ShowModal();
	$dlg->Destroy();
	return $applied;
}


1;
