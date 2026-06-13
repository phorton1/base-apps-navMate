#---------------------------------------------
# nw_search.pm
#---------------------------------------------
# The heart: an asynchronous (Wx::Timer-driven) RAYDP search across ALL up
# NICs.  Next stays disabled until a plotter is heard OR the search times out;
# it enables the instant the first plotter appears.  No dead-ends -- a timeout
# with nothing heard explains the (usually physical) problem and offers Search
# again.

package nw_search;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_TIMER);
use Pub::Utils;
use nw_defs;
use nw_engine;
use nw_panel;
use base qw(nw_panel);

sub new
{
	my ($class, $frame) = @_;
	my $this = $class->SUPER::new($frame);
	$this->setTitle("Looking for your plotter");

	$this->{status} = Wx::StaticText->new($this, -1, '',
		[ $M, $BODY_Y ], [ $WIN_W - 2 * $M, 40 ]);
	$this->{list} = Wx::ListBox->new($this, $ID_LIST,
		[ $M, $BODY_Y + 44 ], [ $WIN_W - 2 * $M, 120 ], [], wxLB_SINGLE);
	$this->{result} = Wx::StaticText->new($this, -1, '',
		[ $M, $BODY_Y + 172 ], [ $WIN_W - 2 * $M, 44 ]);

	$this->addAction("Search again");
	return $this;
}

sub onEnter
{
	my ($this) = @_;
	my $model = $this->model;
	$this->setTitle($model->{applied} ? "Confirming the connection" : "Looking for your plotter");

	$this->{btn_next}->Enable(0);
	$this->{list}->Clear();
	$this->{result}->SetLabel('');
	$model->{devices} = {};
	$model->{e80_nic} = undef;

	# paint a "checking" message BEFORE the (blocking, ~1s) enumeration
	$this->{status}->SetLabel("Checking your network adapters ...");
	$this->Update();

	my ($adapters, $elev) = nw_engine::probe_network();
	$model->{adapters} = $adapters;
	$model->{elevated} = $elev;

	my @nics = nw_engine::up_nics($adapters);
	if (!@nics)
	{
		$this->{status}->SetLabel("No active network adapters found.");
		$this->{result}->SetLabel("Connect your plotter's cable, then press Search again.");
		return;
	}

	$this->{socks} = nw_engine::search_open_all(\@nics);
	$this->{end_time} = time() + $SEARCH_SECS;
	$this->{status}->SetLabel("Make sure the plotter is on and connected.  Searching ...");

	if (!$this->{timer})
	{
		$this->{timer} = Wx::Timer->new($this, $ID_TIMER);
		EVT_TIMER($this, $ID_TIMER, \&onTimer);
	}
	$this->{timer}->Start(300);
}

sub onTimer
{
	my ($this) = @_;
	my $model = $this->model;

	$this->_refresh() if nw_engine::search_poll_all($this->{socks}, $model->{devices});
	nw_engine::search_wake_all($this->{socks});

	my $have = scalar keys %{$model->{devices}};

	# enable Next the instant we hear the first plotter
	if ($have && !$this->{btn_next}->IsEnabled())
	{
		$this->_pick_nic();
		$this->{btn_next}->Enable(1);
		$this->{status}->SetLabel("Found your plotter.");
	}
	elsif (!$have)
	{
		my $left = int($this->{end_time} - time());
		$left = 0 if $left < 0;
		$this->{status}->SetLabel("Make sure the plotter is on and connected.  Searching ... ($left s)");
	}

	if (time() > $this->{end_time})
	{
		$this->{timer}->Stop();
		nw_engine::search_close_all($this->{socks});
		$this->{socks} = undef;
		$this->_conclude();
	}
}

sub _pick_nic
	# the NIC that heard the plotter; prefer one already on a 10.x
{
	my ($this) = @_;
	my $model = $this->model;
	my $chosen;
	for my $d (values %{$model->{devices}})
	{
		$chosen ||= $d->{nic};
		$chosen = $d->{nic} if nw_engine::on_seatalk($d->{nic});
	}
	$model->{e80_nic} = $chosen;
}

sub _refresh
{
	my ($this) = @_;
	my $devs = $this->model->{devices};
	$this->{list}->Clear();
	for my $id (sort keys %$devs)
	{
		my $d = $devs->{$id};
		$this->{list}->Append(sprintf("%-8s  %s  (%s, v%s)", $d->{name}, $d->{ip}, $d->{role}, $d->{version}));
	}
}

sub _conclude
{
	my ($this) = @_;
	my $model = $this->model;
	my @e80s = values %{$model->{devices}};

	if (!@e80s)
	{
		$this->{status}->SetLabel("No plotter found.");
		$this->{result}->SetLabel(
			"If your plotter is on and the cable is seated in a live port, it should\n".
			"appear here.  Check those, then press Search again.");
		$this->{btn_next}->Enable(0);
		return;
	}

	$this->_pick_nic();
	my $nic = $model->{e80_nic};
	$this->{status}->SetLabel("Found " . scalar(@e80s) . " plotter(s).");
	if (nw_engine::on_seatalk($nic))
	{
		$this->{result}->SetLabel("Your computer is on the plotter's network and can reach it.");
	}
	else
	{
		$this->{result}->SetLabel(
			"The plotter is there, but your computer needs an address on its\n".
			"network.  Please press 'Next' to set it.");
	}
	$this->{btn_next}->Enable(1);
}

sub onAction		# Search again
{
	my ($this) = @_;
	$this->onLeave();
	$this->onEnter();
}

sub onNext
{
	my ($this) = @_;
	my $nic = $this->model->{e80_nic};
	$this->frame->goTo(nw_engine::on_seatalk($nic) ? 'done' : 'address');
}

sub onLeave
{
	my ($this) = @_;
	$this->{timer}->Stop() if $this->{timer};
	nw_engine::search_close_all($this->{socks}) if $this->{socks};
	$this->{socks} = undef;
}

1;
