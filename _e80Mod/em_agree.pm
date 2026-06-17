#---------------------------------------------
# em_agree.pm
#---------------------------------------------
# A scroll-gated agreement step: a read-only multiline text box plus an
# "I agree" checkbox that stays DISABLED until the user scrolls to the bottom of
# the text; Next stays disabled until the checkbox is ticked.  Cancel is always
# live.  One reusable panel -- the frame builds two instances (the extended
# disclaimer and the GPL license), differing only in title, text, and label.
#
# Scroll-to-bottom is detected by POLLING the text control's vertical scroll
# position on a timer (robust across wheel / scrollbar / keyboard).  If the
# control reports no usable scroll info, or the text needs no scrollbar, the gate
# fails OPEN (the checkbox enables) rather than trapping the user.

package em_agree;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_CHECKBOX EVT_TIMER);
use Pub::Utils;
use em_defs;
use em_panel;
use base qw(em_panel);

sub new
{
	my ($class, $frame, %args) = @_;
	my $this = $class->SUPER::new($frame);

	$this->{title_text} = $args{title} || 'Please read';
	$this->{check_text} = $args{check} || 'I have read and agree.';
	$this->{next_to}    = $args{next_to};
	$this->{text} =
		defined $args{text}     ? $args{text} :
		defined $args{textfile} ? _slurp($args{textfile}) :
		'';

	$this->{view} = Wx::TextCtrl->new($this, -1, '', [ $M, $BODY_Y ], [ 100, 100 ],
		wxTE_MULTILINE | wxTE_READONLY);
	$this->{check} = Wx::CheckBox->new($this, $ID_AGREE, $this->{check_text}, [ $M, 0 ]);
	EVT_CHECKBOX($this, $ID_AGREE, \&_evt_check);

	# a subtle nudge to the right of the checkbox while it is still disabled;
	# cleared the moment the reader reaches the bottom
	$this->{hint} = Wx::StaticText->new($this, -1, '', [ 0, 0 ], [ -1, -1 ], wxALIGN_RIGHT);
	$this->{hint}->SetForegroundColour(Wx::Colour->new(110, 110, 110));

	$this->{reached_bottom} = 0;
	return $this;
}

sub onEnter
{
	my ($this) = @_;
	$this->setTitle($this->{title_text});
	$this->_layout();

	my $t = $this->{view};
	$t->SetValue($this->{text});

	# Measure the bottom scroll position EMPIRICALLY: scroll to the end, read the
	# scrollbar position there, then return to the top.  The live check compares
	# against this measured max, so it gates correctly whatever the native control
	# reports -- and if the control reports nothing usable, max stays 0 and the gate
	# fails OPEN (enables) rather than trapping the user.
	$t->ShowPosition($t->GetLastPosition());
	$t->Update();
	$this->{max_scroll} = $t->GetScrollPos(wxVERTICAL);
	$t->ShowPosition(0);
	$t->SetInsertionPoint(0);

	$this->{reached_bottom} = 0;
	$this->{check}->SetValue(0);
	$this->{check}->Enable(0);
	$this->{hint}->SetLabel("Scroll to the end to continue");
	$this->{btn_next}->Enable(0);
	$this->showButton('back', (@{$this->{frame}{history}} > 0) ? 1 : 0);

	if (!$this->{timer})
	{
		$this->{timer} = Wx::Timer->new($this, $ID_TIMER);
		EVT_TIMER($this, $ID_TIMER, \&_onTimer);
	}
	$this->{timer}->Start(200);
	$this->_check_scroll();		# immediate: handle the fits-without-scrolling case
}

sub onLeave
{
	my ($this) = @_;
	$this->{timer}->Stop() if $this->{timer};
}

sub onNext
{
	my ($this) = @_;
	$this->frame->goTo($this->{next_to}) if $this->{next_to};
}

sub _layout
	# size the text box to the client area, with the checkbox just below it and
	# above the (dynamically positioned) button row
{
	my ($this) = @_;
	my $cs = $this->{frame}->GetClientSize();
	my ($cw, $ch) = ($cs->GetWidth(), $cs->GetHeight());
	my $by   = $ch - $M - $BTN_H;			# button row top (matches em_panel)
	my $cb_y = $by - $BTN_GAP - $CB_H;		# checkbox row
	my $vh   = $cb_y - $BTN_GAP - $BODY_Y;	# text height
	$vh = 80 if $vh < 80;
	my $hint_w = 220;
	$this->{view}->SetSize($M, $BODY_Y, $cw - 2 * $M, $vh);
	$this->{check}->SetSize($M, $cb_y, $cw - 2 * $M - $hint_w, $CB_H);
	$this->{hint}->SetSize($cw - $M - $hint_w, $cb_y + 2, $hint_w, $CB_H);
}

sub _onTimer { $_[0]->_check_scroll(); }

sub _check_scroll
	# enable the checkbox once the user has reached the bottom of the text
{
	my ($this) = @_;
	return if $this->{reached_bottom};
	my $pos = $this->{view}->GetScrollPos(wxVERTICAL);
	my $max = $this->{max_scroll} || 0;

	# at bottom once the live position reaches the measured max; max <= 0 means the
	# text needs no scrollbar (or the control reports nothing) -> fail OPEN
	my $at_bottom = ($max <= 0) ? 1 : ($pos >= $max - 1) ? 1 : 0;

	if ($at_bottom)
	{
		$this->{reached_bottom} = 1;
		$this->{check}->Enable(1);
		$this->{hint}->SetLabel('');
	}
}

sub _evt_check
{
	my ($this) = @_;
	$this->{btn_next}->Enable($this->{check}->GetValue() ? 1 : 0);
}

sub _slurp
{
	my ($p) = @_;
	open(my $fh, '<', $p) or return "(could not open $p)";
	local $/;
	my $d = <$fh>;
	close $fh;
	return $d;
}

1;
