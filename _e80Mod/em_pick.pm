#---------------------------------------------
# em_pick.pm
#---------------------------------------------
# Choose the stock firmware package and (optionally) a builder handle.  Next
# stays disabled until a .pkg is chosen AND the handle is empty or valid.  The
# library refuses an invalid handle, so we validate it here against the same
# rule and give immediate feedback rather than a failed build.

package em_pick;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON EVT_TEXT);
use Pub::Utils;
use em_defs;
use em_panel;
use base qw(em_panel);

sub new
{
	my ($class, $frame) = @_;
	my $this = $class->SUPER::new($frame);
	$this->setTitle("Choose your firmware");

	my $w = $WIN_W - 2 * $M;
	my $y = $BODY_Y;

	my $intro =
		"Download the E-Series Classic software from Raymarine, unzip it, and choose\n".
		"the E_App_Upg_Uni.pkg file it contains.  Nothing of Raymarine's is included\n".
		"with e80Mod -- you supply your own firmware.";
	Wx::StaticText->new($this, -1, $intro, [ $M, $y ], [ $w, 56 ]);
	$y += 60;

	$this->{link} = Wx::HyperlinkCtrl->new($this, -1,
		"Open the Raymarine download page", $RAYMARINE_URL, [ $M, $y ], [ $w, 20 ]);
	$y += 34;

	Wx::StaticText->new($this, -1, "Firmware package:", [ $M, $y ]);
	$y += 20;
	$this->{path} = Wx::TextCtrl->new($this, -1, '', [ $M, $y ], [ $w - 110, 24 ], wxTE_READONLY);
	$this->{browse} = Wx::Button->new($this, $ID_BROWSE, "Browse ...", [ $M + $w - 100, $y - 2 ], [ 100, 28 ]);
	EVT_BUTTON($this, $ID_BROWSE, \&_onBrowse);
	$y += 44;

	Wx::StaticText->new($this, -1, "Output folder:", [ $M, $y ]);
	$y += 20;
	$this->{outdir_ctrl} = Wx::TextCtrl->new($this, -1, '', [ $M, $y ], [ $w - 110, 24 ], wxTE_READONLY);
	$this->{out_btn} = Wx::Button->new($this, $ID_OUTDIR, "Change ...", [ $M + $w - 100, $y - 2 ], [ 100, 28 ]);
	EVT_BUTTON($this, $ID_OUTDIR, \&_onOutdir);
	$y += 44;

	Wx::StaticText->new($this, -1, "Builder handle (optional):", [ $M, $y ]);
	$y += 20;
	$this->{handle} = Wx::TextCtrl->new($this, $ID_HANDLE, '', [ $M, $y ], [ 220, 24 ]);
	$this->{handle}->SetMaxLength(15);
	EVT_TEXT($this, $ID_HANDLE, \&_onHandle);
	$y += 28;
	$this->{hint} = Wx::StaticText->new($this, -1,
		"Letters, numbers, - and .; no spaces; up to 15 characters.\n".
		"This will be shown on the Unit Info screen for you to verify\n".
		"your built firmware has been installed .\n".
		"Leave it blank for the unit to display \"$DEFAULT_BUILDER\".",
		[ $M, $y ], [ $w, 60 ]);
	$this->{col_ok}  = $this->{hint}->GetForegroundColour();
	$this->{col_bad} = Wx::Colour->new(180, 0, 0);

	$y += 60 + 20;		# past the 2-line handle paragraph + one blank line
	Wx::StaticText->new($this, -1,
		"Press Build once you have selected your firmware package above.",
		[ $M, $y ], [ $w, 20 ]);

	$this->setButtonLabel('next', 'Build');
	$this->{pkg} = '';
	$this->{btn_next}->Enable(0);
	return $this;
}

sub onEnter
{
	my ($this) = @_;
	$this->showButton('back', (@{$this->{frame}{history}} > 0) ? 1 : 0);
	$this->_update();
}

sub _onBrowse
{
	my ($this) = @_;
	my $dlg = Wx::FileDialog->new($this,
		"Select your E_App_Upg_Uni.pkg firmware", '', '',
		"E80 firmware package (*.pkg)|*.pkg|All files (*.*)|*.*",
		wxFD_OPEN | wxFD_FILE_MUST_EXIST);
	if ($dlg->ShowModal() == wxID_OK)
	{
		$this->{pkg} = $dlg->GetPath();
		$this->{path}->SetValue($this->{pkg});
		# default the output folder to the input's location (the user can change it)
		(my $dir = $this->{pkg}) =~ s{[/\\][^/\\]*$}{};
		$this->{outdir_ctrl}->SetValue($dir);
		$this->_update();
	}
	$dlg->Destroy();
}

sub _onOutdir
{
	my ($this) = @_;
	my $start = $this->{outdir_ctrl}->GetValue();
	my $dlg = Wx::DirDialog->new($this, "Choose where to write the modified package", $start);
	if ($dlg->ShowModal() == wxID_OK)
	{
		$this->{outdir_ctrl}->SetValue($dlg->GetPath());
		$this->_update();
	}
	$dlg->Destroy();
}

sub _onHandle { $_[0]->_update(); }

sub _handle_ok
	# the typed handle is acceptable: empty (-> the default) or matches the rule
{
	my ($this) = @_;
	my $h = $this->{handle}->GetValue();
	return 1 if !defined $h || $h eq '';
	return $h =~ $BUILDER_RE ? 1 : 0;
}

sub _update
	# enable Next only with a chosen package and an acceptable handle; nudge the
	# hint red while the handle is invalid
{
	my ($this) = @_;
	my $hok = $this->_handle_ok();
	$this->{hint}->SetForegroundColour($hok ? $this->{col_ok} : $this->{col_bad});
	$this->{hint}->Refresh();
	my $have_out = $this->{outdir_ctrl}->GetValue() ne '';
	$this->{btn_next}->Enable(($this->{pkg} ne '' && $have_out && $hok) ? 1 : 0);
}

sub onNext
{
	my ($this) = @_;
	my $model = $this->model;
	my $outdir = $this->{outdir_ctrl}->GetValue();

	# Warn before clobbering an existing build.  The output name is fixed
	# (OUT_BASENAME), so a prior build sits at a known path in this folder.
	my $target = "$outdir/$OUT_BASENAME";
	if (-e $target)
	{
		my $ans = Wx::MessageBox(
			"A modified firmware package already exists in this folder:\n\n".
			"$target\n\nBuilding will overwrite it.  Continue?",
			"Overwrite existing package?", wxYES_NO | wxICON_QUESTION, $this);
		return if $ans != wxYES;
	}

	$model->{pkg_path} = $this->{pkg};
	my $h = $this->{handle}->GetValue();
	$model->{builder} = (defined $h && $h ne '') ? $h : '';
	$model->{outdir} = $outdir;
	$this->frame->goTo('build');
}

1;
