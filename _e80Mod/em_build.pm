#---------------------------------------------
# em_build.pm
#---------------------------------------------
# Run the build pipeline (extract -> mod001 -> mod002 -> mod003 -> mod004 -> build) and show coarse
# progress.  The work is synchronous and fast; it is kicked off via CallAfter so
# the panel paints first, and each step repaints between e80Firmware calls.

package em_build;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_TIMER);
use Pub::Utils;
use em_defs;
use em_engine;
use em_panel;
use base qw(em_panel);

sub new
{
	my ($class, $frame) = @_;
	my $this = $class->SUPER::new($frame);
	$this->setTitle("Building modified firmware");

	my $w = $WIN_W - 2 * $M;
	$this->{status} = Wx::StaticText->new($this, -1, '', [ $M, $BODY_Y ], [ $w, 24 ]);
	$this->{gauge}  = Wx::Gauge->new($this, -1, 4, [ $M, $BODY_Y + 30 ], [ $w, 22 ]);
	$this->{detail} = Wx::StaticText->new($this, -1, '', [ $M, $BODY_Y + 70 ], [ $w, 140 ]);

	$this->showButton('next', 0);
	return $this;
}

sub onEnter
{
	my ($this) = @_;
	$this->{status}->SetLabel("Preparing ...");
	$this->{detail}->SetLabel('');
	$this->{gauge}->SetRange(5);
	$this->{gauge}->SetValue(0);
	$this->showButton('next', 0);
	$this->showButton('back', 0);

	# Paint the panel first, then run the (blocking) build.  This wxPerl has no
	# Wx::CallAfter, so a one-shot timer defers _run() until the event loop has
	# shown this panel.
	if (!$this->{kick})
	{
		$this->{kick} = Wx::Timer->new($this, $ID_TIMER);
		EVT_TIMER($this, $ID_TIMER, \&_onTimer);
	}
	$this->{kick}->Start(50, 1);
}

sub _onTimer { $_[0]->_run(); }

sub _run
{
	my ($this) = @_;
	my $model = $this->model;

	my $progress = {};
	my $step = sub
	{
		my ($label, $done, $total) = @_;
		$this->{status}->SetLabel($label);
		$this->{gauge}->SetRange($total);
		$this->{gauge}->SetValue($done);
		$this->Update();
		Wx::Yield();
	};

	# Mute the app frame around the build so e80Firmware's own (cryptic) error()
	# does not pop a dialog; we log the detail and show the user a reworded one.
	my $saved = Pub::Utils::getAppFrame();
	Pub::Utils::setAppFrame(undef);
	my $out = em_engine::build_modified(
		pkg      => $model->{pkg_path},
		builder  => $model->{builder},
		outdir   => $model->{outdir},
		progress => $progress,
		step     => $step);
	Pub::Utils::setAppFrame($saved);

	if ($out)
	{
		$model->{out_path} = $out;
		$this->{gauge}->SetValue(5);
		$this->{status}->SetLabel("Build complete.");
		$this->{detail}->SetLabel(
			"Your modified firmware was built successfully.\n\n".
			"Click Next to see where it is and how to put it on a CF card.");
		$this->showButton('next', 1);
		$this->{btn_next}->Enable(1);
	}
	else
	{
		# the technical detail to the log for analysis ...
		warning(0, 0, "e80Mod build failed: " . ($progress->{error} || 'unknown'));
		# ... and a plain-language reason to the user (dialog + on-panel note)
		(my $file = $model->{pkg_path} || '') =~ s{^.*[/\\]}{};
		my $err = $progress->{error} || '';
		my $why;
		if ($err =~ /cannot write/i)
		{
			$why = "The modified package could not be written to the output folder you ".
			       "chose. Please pick a folder you can write to, then try again.";
		}
		elsif ($err =~ /missing modification data|no record file/i)
		{
			# OUR shipping problem, not the user's firmware -- do not blame the file.
			$why = "e80Mod could not find its firmware modification data. This means ".
			       "e80Mod was not installed correctly. Please reinstall navMate and ".
			       "try again.";
		}
		else
		{
			$why = "\"$file\" does not appear to be valid v5.69 E-Series firmware. ".
			       "This modification requires the v5.69 firmware downloaded directly ".
			       "from Raymarine. Please check the input file and try again.";
		}
		error($why);
		$this->{status}->SetLabel("Could not build the firmware.");
		$this->{detail}->SetLabel($why);
		$this->showButton('back', 1);
	}
}

1;
