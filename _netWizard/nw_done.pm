#---------------------------------------------
# nw_done.pm
#---------------------------------------------
# The final step: report the outcome and offer Launch navMate / Close.

package nw_done;
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
	$this->setTitle("All set");
	$this->{body} = Wx::StaticText->new($this, -1, '',
		[ $M, $BODY_Y ], [ $WIN_W - 2 * $M, 170 ]);

	$this->showButton('next', 0);
	$this->showButton('back', 0);
	$this->setButtonLabel('cancel', 'Close');
	return $this;
}

sub onEnter
{
	my ($this) = @_;
	my $model = $this->model;
	my @e80s = values %{$model->{devices}};
	my $nic = $model->{e80_nic};
	my $alias = $nic ? $nic->{alias} : 'network';

	if ($model->{intent} eq 'revert')
	{
		my $ralias = $model->{revert_nic} ? $model->{revert_nic}{alias} : 'network';
		$this->{body}->SetLabel(
			"Your computer's network has been restored.\n\n".
			"The '$ralias' adapter is back to Automatic (DHCP).");
	}
	elsif (@e80s && $model->{applied})
	{
		$this->{body}->SetLabel(
			"Connected to your plotter.\n\n".
			"Your '$alias' adapter is set to static IP $model->{target_ip} and\n".
			"mask $model->{target_mask} with no gateway.\n\n".
			"You can close this window and start or return to navMate.  To undo\n".
			"this change later, run this wizard again and choose \"Undo a previous setup\".");
	}
	elsif (@e80s)
	{
		my $ip = $nic ? $nic->{ipv4} : '';
		$this->{body}->SetLabel(
			"Connected to your plotter.\n\n".
			"Your '$alias' adapter ($ip) can already reach it -- nothing needed\n".
			"to change.\n\n".
			"You can close this window and start or return to navMate.");
	}
	else
	{
		$this->{body}->SetLabel(
			"Setup is finished.\n\n".
			"If navMate doesn't see the plotter, run the wizard again.");
	}
}

1;
