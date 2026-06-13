#---------------------------------------------
# nw_welcome.pm
#---------------------------------------------
# The opening step: reassurance + one primary forward ("Find my plotter")
# and a small secondary "Undo a previous setup".  No mode-menu.

package nw_welcome;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils;
use nw_defs;
use nw_panel;
use base qw(nw_panel);

sub new
{
	my ($class, $frame) = @_;
	my $this = $class->SUPER::new($frame);
	$this->setTitle("Connect to your E-Series plotter");

	my $msg =
		"This takes about a minute.  Nothing here can harm your plotter, and the\n".
		"one change it makes to your computer (its network address) is easily undone.";
	Wx::StaticText->new($this, -1, $msg, [ $M, $BODY_Y ], [ $WIN_W - 2 * $M, 80 ]);

	$this->addAction("Undo a previous setup");
	$this->setButtonLabel('next', "Find my plotter");
	$this->showButton('back', 0);
	return $this;
}

sub onNext
{
	my ($this) = @_;
	$this->model->{intent} = 'setup';
	$this->frame->goTo('search');
}

sub onAction		# Undo a previous setup
{
	my ($this) = @_;
	$this->model->{intent} = 'revert';
	$this->frame->goTo('address');
}

1;
