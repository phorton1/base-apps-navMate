#---------------------------------------------
# nw_address.pm
#---------------------------------------------
# Set (or, in revert mode, undo) the computer's address on the plotter's
# network via netsh.  ONE decisive action -- "Set my address" -- does it and
# advances to a re-search that confirms reachability; there is NO separate Next
# on this step (Apply *is* the proceed).  The action is disabled when not
# elevated (netsh needs Administrator; no self-elevation).  Apply SETs the adapter
# to the static IP (replacing its config); Undo returns it to Automatic (DHCP).

package nw_address;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils;
use nw_defs;
use nw_engine;
use nw_panel;
use base qw(nw_panel);

sub new
{
	my ($class, $frame) = @_;
	my $this = $class->SUPER::new($frame);
	$this->setTitle("Set your computer's network address");
	$this->{body} = Wx::StaticText->new($this, -1, '',
		[ $M, $BODY_Y ], [ $WIN_W - 2 * $M, 210 ]);
	$this->addAction("Set my address");
	$this->showButton('next', 0);		# single action; no Next on this step
	return $this;
}

sub onEnter
{
	my ($this) = @_;
	return $this->_enter_revert() if $this->model->{intent} eq 'revert';

	my $model = $this->model;
	my $nic = $model->{e80_nic};
	$this->setTitle("Set your computer's network address");
	$this->setButtonLabel('action', 'Set my address');
	$this->showButton('next', 0);

	if (!$nic)
	{
		$this->{body}->SetLabel(
			"No plotter was found, so there's no network to join yet.\n".
			"Go Back and Search again.");
		$this->{btn_action}->Enable(0);
		return;
	}

	my $elev = $model->{elevated} ? '' :
		"\n\nThis step needs Administrator rights and so 'Set my address' isn't\n".
		"available.  Close and relaunch the wizard as Administrator.";
	$this->{body}->SetLabel(
		"Your plotter was found on the '$nic->{alias}' adapter.\n\n".
		"This will set that adapter's fixed IP address to\n".
		"$model->{target_ip}   (mask $model->{target_mask}).\n\n".
		"You can undo this later, and it cannot affect the plotter.$elev");
	$this->{btn_action}->Enable($model->{elevated} ? 1 : 0);
}

sub _enter_revert
{
	my ($this) = @_;
	my $model = $this->model;
	$this->setTitle("Undo a previous setup");
	$this->setButtonLabel('action', 'Undo');
	$this->showButton('next', 0);

	my ($adapters, $elev) = nw_engine::probe_network();
	$model->{adapters} = $adapters;
	$model->{elevated} = $elev;
	my ($nic) = grep { nw_engine::has_ip($_, $model->{target_ip}) } @$adapters;
	$model->{revert_nic} = $nic;

	if (!$nic)
	{
		$this->{body}->SetLabel("Nothing to undo -- no adapter is using $model->{target_ip}.");
		$this->{btn_action}->Enable(0);
		return;
	}

	my $elevnote = $elev ? '' :
		"\n\nThis step needs Administrator rights and so 'Undo' isn't available.\n".
		"Close and relaunch the wizard as Administrator.";
	$this->{body}->SetLabel(
		"This will restore the '$nic->{alias}' adapter to automatic (DHCP),\n".
		"putting your computer's network back the way it was.$elevnote");
	$this->{btn_action}->Enable($elev ? 1 : 0);
}

sub onAction		# "Set my address" or "Undo" -- the single decisive action
{
	my ($this) = @_;
	my $model = $this->model;

	if ($model->{intent} eq 'revert')
	{
		my $nic = $model->{revert_nic};
		return if !$nic;
		if (nw_engine::revert_address($nic))
		{
			$this->frame->goTo('done');
		}
		else
		{
			$this->{body}->SetLabel("Could not undo (see the log).");
		}
		return;
	}

	my $nic = $model->{e80_nic};
	return if !$nic;
	if (nw_engine::apply_address($nic, $model->{target_ip}, $model->{target_mask}))
	{
		$model->{applied} = 1;
		$this->frame->goTo('search');		# advance straight to confirm-by-re-search
	}
	else
	{
		$this->{body}->SetLabel("Could not set the address (see the log).");
	}
}

1;
