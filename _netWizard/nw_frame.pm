#---------------------------------------------
# nw_frame.pm
#---------------------------------------------
# The fixed-size, menubar-less wizard frame: owns the shared model (a plain
# hashref), builds the panel stack, and drives navigation (showStep / goTo /
# goBack / goNext) with a small history stack so branches can be backed out of.

package nw_frame;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_CLOSE);
use Pub::Utils;
use nw_defs;
use nw_panel;
use nw_welcome;
use nw_search;
use nw_address;
use nw_done;
use base qw(Wx::Frame);

sub new
{
	my ($class) = @_;
	my $style = wxDEFAULT_FRAME_STYLE() & ~( wxRESIZE_BORDER() | wxMAXIMIZE_BOX() );
	my $this = $class->SUPER::new(undef, -1, "E-Series Connection Setup",
		wxDefaultPosition, [ $WIN_W, $WIN_H ], $style);

	$this->{model} = {
		devices		=> {},
		intent		=> 'setup',
		target_ip	=> $TARGET_IP,
		target_mask	=> $TARGET_MASK,
		applied		=> 0,
	};
	$this->{history} = [];
	$this->{panel} = {
		welcome	=> nw_welcome->new($this),
		search	=> nw_search->new($this),
		address	=> nw_address->new($this),
		done	=> nw_done->new($this),
	};
	$this->{order} = [ qw(welcome search address done) ];

	EVT_CLOSE($this, \&onClose);
	$this->Centre();
	$this->showStep('welcome');
	return $this;
}

sub showStep
	# hide all, size one to the client area, show it, fire onEnter
{
	my ($this, $name) = @_;
	my $panel = $this->{panel}{$name};
	return error("no wizard step '$name'") if !$panel;

	$_->Show(0) for values %{$this->{panel}};
	my $cs = $this->GetClientSize();
	$panel->SetSize(0, 0, $cs->GetWidth(), $cs->GetHeight());
	$this->{current} = $name;
	$panel->Show(1);
	$panel->onEnter();
	display($dbg_wiz, 0, "step -> $name");
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
	Wx::MessageBox($msg, "E-Series Connection Setup", wxOK | wxICON_ERROR, $this);
}

sub onClose
{
	my ($this, $event) = @_;
	$this->{panel}{$this->{current}}->onLeave() if $this->{current};
	$this->Destroy();
}

1;
