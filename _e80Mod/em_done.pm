#---------------------------------------------
# em_done.pm
#---------------------------------------------
# Report the built package and tell the user how to get it onto a CF card, with
# the revert-to-stock note and the version-floor limitation.

package em_done;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils;
use em_defs;
use em_panel;
use base qw(em_panel);

sub new
{
	my ($class, $frame) = @_;
	my $this = $class->SUPER::new($frame);
	$this->setTitle("Your modified firmware is ready");
	my $w = $WIN_W - 2 * $M;
	$this->{intro} = Wx::StaticText->new($this, -1, '', [ $M, $BODY_Y ],       [ $w, 56 ]);
	$this->{files} = Wx::StaticText->new($this, -1, '', [ $M, $BODY_Y + 64 ],  [ $w, 64 ]);
	$this->{outro} = Wx::StaticText->new($this, -1, '', [ $M, $BODY_Y + 140 ], [ $w, 230 ]);

	# fixed-width font for the file list so the parenthetical notes line up
	my $mono = Wx::Font->new($this->{files}->GetFont()->GetPointSize(),
		wxFONTFAMILY_TELETYPE, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);
	$this->{files}->SetFont($mono);

	$this->addAction("Open output folder");
	$this->showButton('next', 0);
	$this->showButton('back', 0);
	$this->setButtonLabel('cancel', 'Close');
	return $this;
}

sub onEnter
{
	my ($this) = @_;
	my $model = $this->model;
	my $out = $model->{out_path} || '';
	(my $dir = $out) =~ s{[/\\][^/\\]*$}{};
	$this->{dir} = $dir;

	$this->{intro}->SetLabel(
		"Built:  $out\n\n".
		"To install it, put THREE files on a CF card and insert it in your unit:");

	$this->{files}->SetLabel(
		sprintf("   %-27s%s\n", "autorun.dob",       "(from the Raymarine download, unchanged)").
		sprintf("   %-27s%s\n", $OUT_BASENAME,        "(the modified firmware you just built)").
		sprintf("   %-27s%s",   "E_App_Upg_Uni.pkg",  "(the original -- so you can go back)"));

	$this->{outro}->SetLabel(
		"Boot the unit with the card in; the installer lists every package on the\n".
		"card, so you can install the modified firmware -- or re-select the original\n".
		"to revert to stock v5.69 at any time.\n\n".
		"Note: reverting goes back to v5.69 (the version you downloaded).  e80Mod\n".
		"cannot restore some other, older firmware you may once have had.");
}

sub onAction		# Open output folder
{
	my ($this) = @_;
	return if !$this->{dir};
	(my $win = $this->{dir}) =~ s{/}{\\}g;
	system(1, "explorer", $win);
}

1;
