#---------------------------------------------
# em_frame.pm
#---------------------------------------------
# The fixed-size, menubar-less e80Mod frame: owns the shared model, builds the
# panel stack, and drives navigation (showStep / goTo / goBack / goNext) with a
# history stack.  Modelled on the netWizard nw_frame.

package em_frame;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_CLOSE);
use Pub::Utils;
use em_defs;
use em_panel;
use em_agree;
use em_pick;
use em_build;
use em_done;
use base qw(Wx::Frame);

sub new
{
	my ($class) = @_;
	my $style = wxDEFAULT_FRAME_STYLE() & ~( wxRESIZE_BORDER() | wxMAXIMIZE_BOX() );
	my $this = $class->SUPER::new(undef, -1, "e80Mod -- E-Series Firmware Builder",
		wxDefaultPosition, [ $WIN_W, $WIN_H ], $style);

	$this->{model}   = {};
	$this->{history} = [];
	# NB: no GPL "license agreement" page here.  GPLv3 does not require acceptance
	# to RUN the program (sec.9), the installer already surfaces it once, and it is
	# a code-licensing instrument, not the use-time disclaimer that warrants a
	# point-of-use gate.  GPL is satisfied by shipping LICENSE.TXT (+ a future About
	# box); only the Notice/firmware-risk disclaimer gates the act here.
	$this->{panel} = {
		disclaimer => em_agree->new($this,
			title   => "Please read this notice",
			text    => $DISCLAIMER_TEXT,
			check   => "I have read and accept this notice.",
			next_to => 'pick'),
		pick  => em_pick->new($this),
		build => em_build->new($this),
		done  => em_done->new($this),
	};
	$this->{order} = [ qw(disclaimer pick build done) ];

	EVT_CLOSE($this, \&onClose);
	$this->Centre();
	$this->showStep('disclaimer');
	return $this;
}

sub showStep
	# hide all, size one to the client area, show it, fire onEnter
{
	my ($this, $name) = @_;
	my $panel = $this->{panel}{$name};
	return error("no e80Mod step '$name'") if !$panel;

	$_->Show(0) for values %{$this->{panel}};
	my $cs = $this->GetClientSize();
	$panel->SetSize(0, 0, $cs->GetWidth(), $cs->GetHeight());
	$this->{current} = $name;
	$panel->Show(1);
	$panel->onEnter();
	display($dbg_mod, 0, "step -> $name");
}

sub goTo
{
	my ($this, $name) = @_;
	$this->{panel}{$this->{current}}->onLeave() if $this->{current};
	push @{$this->{history}}, $this->{current} if defined $this->{current};
	$this->showStep($name);
}

sub goBack
{
	my ($this) = @_;
	$this->{panel}{$this->{current}}->onLeave() if $this->{current};
	my $prev = pop @{$this->{history}};
	$this->showStep($prev) if defined $prev;
}

sub goNext
	# default linear advance (panels usually override onNext to branch)
{
	my ($this) = @_;
	my @order = @{$this->{order}};
	for my $i (0 .. $#order)
	{
		next if $order[$i] ne $this->{current};
		$this->goTo($order[$i + 1]) if $i < $#order;
		return;
	}
}

sub showError		# called by Pub::Utils error() because we setAppFrame($this)
{
	my ($this, $msg) = @_;
	Wx::MessageBox($msg, "e80Mod", wxOK | wxICON_ERROR, $this);
}

sub onClose
{
	my ($this, $event) = @_;
	$this->{panel}{$this->{current}}->onLeave() if $this->{current};
	$this->Destroy();
}

1;
