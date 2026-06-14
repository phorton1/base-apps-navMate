#---------------------------------------------
# nw_done.pm
#---------------------------------------------
# The final step: report the outcome and offer Launch navMate / Close.

package nw_done;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils;
use Pub::Prefs;
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

	my $body;
	my $final_ip;		# IP navMate should bind; undef = leave its pref untouched

	if ($model->{intent} eq 'revert')
	{
		my $ralias = $model->{revert_nic} ? $model->{revert_nic}{alias} : 'network';
		$body =
			"Your computer's network has been restored.\n\n".
			"The '$ralias' adapter is back to Automatic (DHCP).";
		$final_ip = $TARGET_IP;		# undo -> reset navMate back to its default
	}
	elsif (@e80s && $model->{applied})
	{
		$body =
			"Connected to your plotter.\n\n".
			"Your '$alias' adapter is set to static IP $model->{target_ip} and\n".
			"mask $model->{target_mask} with no gateway.\n\n".
			"You can close this window and start or return to navMate.  To undo\n".
			"this change later, run this wizard again and choose \"Undo a previous setup\".";
		$final_ip = $model->{target_ip};
	}
	elsif (@e80s)
	{
		my $ip = $nic ? $nic->{ipv4} : '';
		$body =
			"Connected to your plotter.\n\n".
			"Your '$alias' adapter ($ip) can already reach it -- nothing needed\n".
			"to change.\n\n".
			"You can close this window and start or return to navMate.";
		$final_ip = $ip;		# bind whatever working 10.x they're already on
	}
	else
	{
		$body =
			"Setup is finished.\n\n".
			"If navMate doesn't see the plotter, run the wizard again.";
		# nothing established -- don't touch navMate's IP pref
	}

	$body .= "\n\nIf navMate is running, please restart it for this network ".
		"change to take effect." if _reconcile_pref($final_ip);

	$this->{body}->SetLabel($body);
}


sub _reconcile_pref
	# Make navMate's LOCAL_IP pref match the IP the wizard left the adapter on, so
	# navMate binds the right address.  $final_ip undef/'' -> skip (nothing was
	# established).  Returns 1 if the effective value actually changed (caller then
	# shows the restart note).  We initPrefs with LOCAL_IP defaulted to $TARGET_IP
	# (== navMate's own a_defs default), so setPref to that default makes writePrefs
	# comment the stale line out (navMate falls back to its code default); a
	# non-default value is written as an active line.  Other prefs in the file are
	# preserved by writePrefs.  ('LOCAL_IP' must match the id a_defs::initServices reads.)
{
	my ($final_ip) = @_;
	return 0 if !$final_ip;
	Pub::Prefs::initPrefs("$data_dir/navMate.prefs", { LOCAL_IP => $TARGET_IP });
	my $old = getPref('LOCAL_IP') // $TARGET_IP;
	return 0 if $old eq $final_ip;
	setPref('LOCAL_IP', $final_ip);
	writePrefs();
	return 1;
}

1;
