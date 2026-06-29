#!/usr/bin/perl
#------------------------------------------
# navColorPick.pm
#------------------------------------------
# Shared color picker for navMate's three arbitrary-color editors
# (winDatabase, winFind, winMultiEditor), with a persistent custom-color
# palette that the native wxColourDialog cannot manage on its own.
#
# DESIGN
# ------
# The 16 custom-color slots are OUR data, persisted to
# $temp_dir/navMate_colors.json (mirroring navVisibility's view-state
# sidecar).  White (0xFFFFFF) marks an unused slot.
#
# We restore the palette into the native dialog's custom slots before every
# show, purely for DISPLAY.  We deliberately do NOT harvest the native slots
# back afterward -- the native "Add to Custom Colors" button always targets
# slot 0 and overwrites, which is unmanageable, so it is a no-op as far as
# persistence is concerned.
#
# Instead, the ONLY way a color enters the palette is the post-OK flow: when
# the user presses OK on a color that is neither a Windows "Basic" color nor
# already in the palette, we pop our own "Add Custom Color?" dialog
# (navColorPick::AddDialog).  It shows the new color plus the 16 slots; the
# user clicks a slot to place the new color there (double-click = place+save),
# or Skips.  Overwriting an occupied slot is thus an explicit choice, which
# also covers the "palette full" case with no special-casing.

package navColorPick;
use strict;
use warnings;
use Wx qw(:everything);
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display warning error $temp_dir);


my $NUM_CUSTOM = 16;
my $DEFAULT    = 0xFFFFFF;   # white = the unused-slot sentinel

my @custom;       # $NUM_CUSTOM ints, each 0xRRGGBB
my $loaded = 0;


# The 48 Windows "Basic colors" from comdlg32 (ReactOS predefcolors[6][8]),
# as COLORREF 0x00BBGGRR.  Converted to 0xRRGGBB once below; 0x00400040
# appears twice, so the distinct set is 47.
my @_BASIC_COLORREF = (
	0x008080FF,0x0080FFFF,0x0080FF80,0x0080FF00,0x00FFFF80,0x00FF8000,0x00C080FF,0x00FF80FF,
	0x000000FF,0x0000FFFF,0x0000FF80,0x0040FF00,0x00FFFF00,0x00C08000,0x00C08080,0x00FF00FF,
	0x00404080,0x004080FF,0x0000FF00,0x00808000,0x00804000,0x00FF8080,0x00400080,0x008000FF,
	0x00000080,0x000080FF,0x00008000,0x00408000,0x00FF0000,0x00A00000,0x00800080,0x00FF0080,
	0x00000040,0x00004080,0x00004000,0x00404000,0x00800000,0x00400000,0x00400040,0x00800040,
	0x00000000,0x00008080,0x00408080,0x00808080,0x00808040,0x00C0C0C0,0x00400040,0x00FFFFFF,
);
my %_basic_rgb;
for my $cref (@_BASIC_COLORREF)
{
	my $r = $cref & 0xFF;
	my $g = ($cref >> 8) & 0xFF;
	my $b = ($cref >> 16) & 0xFF;
	$_basic_rgb{ ($r << 16) | ($g << 8) | $b } = 1;
}
sub _isBasic { return $_basic_rgb{ $_[0] // -1 } ? 1 : 0 }


sub _stateFile { return "$temp_dir/navMate_colors.json" }


sub _wxcolour
{
	my ($rgb) = @_;
	$rgb //= $DEFAULT;
	return Wx::Colour->new(($rgb >> 16) & 0xFF, ($rgb >> 8) & 0xFF, $rgb & 0xFF);
}


sub _inPalette
{
	my ($rgb) = @_;
	for my $c (@custom) { return 1 if defined $c && $c == $rgb }
	return 0;
}


sub _load
{
	return if $loaded;
	$loaded = 1;
	@custom = ($DEFAULT) x $NUM_CUSTOM;
	my $file = _stateFile();
	return if !-f $file;
	my $raw = do { local $/; open(my $fh, '<:raw', $file) or return; <$fh> };
	my $h = eval { decode_json($raw) };
	return if !($h && ref $h eq 'HASH' && ref $h->{custom_colors} eq 'ARRAY');
	my @in = @{$h->{custom_colors}};
	for my $i (0 .. $NUM_CUSTOM - 1)
	{
		$custom[$i] = (defined $in[$i] && $in[$i] =~ /^\d+$/)
			? ($in[$i] & 0xFFFFFF) : $DEFAULT;
	}
	display(0, 0, 'navColorPick: loaded custom colors');
}


sub _save
{
	my $file = _stateFile();
	my $json = encode_json({ custom_colors => [ @custom ] });
	open(my $fh, '>:raw', $file)
		or do { error("navColorPick: cannot write $file: $!"); return; };
	print $fh $json;
	close $fh;
	display(0, 0, 'navColorPick: saved custom colors');
}


sub pickColour
	# Show the native full color dialog seeded with $initial (a Wx::Colour),
	# the persisted palette restored into the custom slots for display.
	# Returns the chosen Wx::Colour on OK, undef on Cancel.  On OK, if the
	# chosen color is new (not Basic, not already in the palette), offers the
	# Add Custom Color? dialog so the user can place it into a slot.
{
	my ($parent, $initial) = @_;
	_load();

	my $cd = Wx::ColourData->new();
	$cd->SetChooseFull(1);
	$cd->SetColour($initial) if $initial;
	$cd->SetCustomColour($_, _wxcolour($custom[$_])) for 0 .. $NUM_CUSTOM - 1;

	my $dlg    = Wx::ColourDialog->new($parent, $cd);
	my $ok     = ($dlg->ShowModal() == wxID_OK);
	my $chosen = $ok ? $dlg->GetColourData()->GetColour() : undef;
	$dlg->Destroy();
	return undef if !$chosen;

	my $rgb = ($chosen->Red() << 16) | ($chosen->Green() << 8) | $chosen->Blue();
	if (!_isBasic($rgb) && !_inPalette($rgb))
	{
		my $add = navColorPick::AddDialog->new($parent, $rgb, \@custom);
		if ($add->ShowModal() == wxID_OK)
		{
			my $slot = $add->resultSlot();
			if (defined $slot)
			{
				$custom[$slot] = $rgb;
				_save();
			}
		}
		$add->Destroy();
	}

	return $chosen;
}


#------------------------------------------
# navColorPick::AddDialog
#------------------------------------------
# Our own "remember this color?" dialog: the new color as a swatch, plus the
# 16 palette slots as sunken swatch-buttons on a light-grey field.  Single
# click selects a slot and previews the new color in it (enabling/defaulting
# Save); double click places-and-saves in one gesture.  Skip declines.

package navColorPick::AddDialog;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON EVT_LEFT_DOWN EVT_LEFT_DCLICK);
use base 'Wx::Dialog';

my $SLOT_W = 34;
my $SLOT_H = 24;


sub _wxcol
{
	my ($rgb) = @_;
	$rgb //= 0xFFFFFF;
	return Wx::Colour->new(($rgb >> 16) & 0xFF, ($rgb >> 8) & 0xFF, $rgb & 0xFF);
}


sub new
{
	my ($class, $parent, $new_rgb, $slots_ref) = @_;
	my $this = $class->SUPER::new($parent, -1, 'Add Custom Color?',
		wxDefaultPosition, wxDefaultSize, wxDEFAULT_DIALOG_STYLE);

	$this->{_new_rgb}     = $new_rgb;
	$this->{_slots}       = [ @$slots_ref ];   # 16 RGB ints
	$this->{_selected}    = undef;
	$this->{_slot_panels} = [];

	$this->SetBackgroundColour(Wx::Colour->new(220, 220, 220));
	my $vbox = Wx::BoxSizer->new(wxVERTICAL);

	# New color row
	my $top = Wx::BoxSizer->new(wxHORIZONTAL);
	$top->Add(Wx::StaticText->new($this, -1, 'New color:'),
		0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 6);
	my $new_sw = Wx::Panel->new($this, -1, wxDefaultPosition, [54, $SLOT_H], wxBORDER_SUNKEN);
	$new_sw->SetBackgroundColour(_wxcol($new_rgb));
	$top->Add($new_sw, 0, wxALIGN_CENTER_VERTICAL);
	$vbox->Add($top, 0, wxALL, 10);

	$vbox->Add(Wx::StaticText->new($this, -1,
		'Click a slot to place it (double-click to save):'),
		0, wxLEFT | wxRIGHT, 10);

	# 16 slots, 2 rows x 8
	my $grid = Wx::GridSizer->new(2, 8, 4, 4);
	for my $i (0 .. 15)
	{
		my $p = Wx::Panel->new($this, -1, wxDefaultPosition, [$SLOT_W, $SLOT_H], wxBORDER_SUNKEN);
		$p->SetBackgroundColour(_wxcol($this->{_slots}[$i]));
		my $idx = $i;
		EVT_LEFT_DOWN  ($p, sub { $this->_selectSlot($idx) });
		EVT_LEFT_DCLICK($p, sub { $this->_selectSlot($idx); $this->_commit() });
		$this->{_slot_panels}[$i] = $p;
		$grid->Add($p, 0, wxALIGN_CENTER);
	}
	$vbox->Add($grid, 0, wxALL, 10);

	# Buttons
	my $btns = Wx::BoxSizer->new(wxHORIZONTAL);
	$this->{_save} = Wx::Button->new($this, -1, 'Save');
	$this->{_skip} = Wx::Button->new($this, -1, 'Skip');
	$this->{_save}->Enable(0);
	$btns->Add($this->{_save}, 0, wxRIGHT, 8);
	$btns->Add($this->{_skip}, 0);
	$vbox->Add($btns, 0, wxALL | wxALIGN_RIGHT, 10);

	EVT_BUTTON($this, $this->{_save}, sub { $this->_commit() });
	EVT_BUTTON($this, $this->{_skip}, sub { $this->EndModal(wxID_CANCEL) });

	$this->SetSizerAndFit($vbox);
	return $this;
}


sub _selectSlot
{
	my ($this, $i) = @_;
	my $prev = $this->{_selected};
	if (defined $prev && $prev != $i)
	{
		$this->{_slot_panels}[$prev]->SetBackgroundColour(_wxcol($this->{_slots}[$prev]));
		$this->{_slot_panels}[$prev]->Refresh();
	}
	$this->{_selected} = $i;
	$this->{_slot_panels}[$i]->SetBackgroundColour(_wxcol($this->{_new_rgb}));
	$this->{_slot_panels}[$i]->Refresh();
	$this->{_save}->Enable(1);
	$this->{_save}->SetDefault();
}


sub _commit
{
	my ($this) = @_;
	return if !defined $this->{_selected};
	$this->{_result_slot} = $this->{_selected};
	$this->EndModal(wxID_OK);
}


sub resultSlot { return $_[0]->{_result_slot} }


1;
