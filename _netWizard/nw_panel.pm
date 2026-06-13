#---------------------------------------------
# nw_panel.pm
#---------------------------------------------
# Base class for every wizard step: a Wx::Panel with a bold title, a button
# bar, and onEnter/onLeave/onAction/onBack/onNext/onCancel hooks the steps
# override.
#
# The button bar is laid out DYNAMICALLY, not from a fixed template: every
# button auto-sizes to its label, and layoutButtons() positions whichever
# buttons are currently shown (right cluster = Back/Next/Cancel, left = the
# optional action button).  Steps relabel / show / hide buttons freely -- and
# future panels can add their own -- without overlap or truncation.

package nw_panel;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_BUTTON);
use Pub::Utils;
use nw_defs;
use base qw(Wx::Panel);

sub new
{
	my ($class, $frame) = @_;
	my $this = $class->SUPER::new($frame, -1);
	$this->{frame} = $frame;
	$this->{model} = $frame->{model};

	# title (bold, a bit larger)

	$this->{title} = Wx::StaticText->new($this, -1, '', [ $M, $TITLE_Y ]);
	my $font = $this->{title}->GetFont();
	$font->SetWeight(wxFONTWEIGHT_BOLD);
	$font->SetPointSize($font->GetPointSize() + 2);
	$this->{title}->SetFont($font);

	# Back / Next / Cancel -- auto-sized to their labels; positioned by layoutButtons()

	$this->{btn_back}   = Wx::Button->new($this, $ID_BACK,   'Back');
	$this->{btn_next}   = Wx::Button->new($this, $ID_NEXT,   'Next');
	$this->{btn_cancel} = Wx::Button->new($this, $ID_CANCEL, 'Cancel');
	$this->_fit($_) for ($this->{btn_back}, $this->{btn_next}, $this->{btn_cancel});

	EVT_BUTTON($this, $ID_BACK,   \&_evt_back);
	EVT_BUTTON($this, $ID_NEXT,   \&_evt_next);
	EVT_BUTTON($this, $ID_CANCEL, \&_evt_cancel);

	$this->layoutButtons();
	$this->Show(0);
	return $this;
}

# accessors

sub frame { return $_[0]->{frame}; }
sub model { return $_[0]->{model}; }
sub setTitle { $_[0]->{title}->SetLabel($_[1]); }


#------------------------------
# button bar (dynamic)
#------------------------------

sub addAction
	# a left-side action button (Apply / Search again / Undo / Launch)
{
	my ($this, $label) = @_;
	$this->{btn_action} = Wx::Button->new($this, $ID_ACTION, $label);
	$this->_fit($this->{btn_action});
	EVT_BUTTON($this, $ID_ACTION, \&_evt_action);
	$this->layoutButtons();
	return $this->{btn_action};
}

sub _fit		# size a button to its label width at the standard height
{
	my ($this, $b) = @_;
	$b->SetSize($b->GetBestSize()->GetWidth(), $BTN_H);
}

sub setButtonLabel		# $key = back | next | cancel | action
{
	my ($this, $key, $label) = @_;
	my $b = $this->{"btn_$key"};
	return if !$b;
	$b->SetLabel($label);
	$this->_fit($b);
	$this->layoutButtons();
}

sub showButton
{
	my ($this, $key, $show) = @_;
	my $b = $this->{"btn_$key"};
	return if !$b;
	$b->Show($show ? 1 : 0);
	$this->layoutButtons();
}

sub layoutButtons
	# right cluster (Cancel, Next, Back -- only those shown) + the left action
	# button, along the bottom margin of the frame's client area
{
	my ($this) = @_;
	my $cs = $this->{frame}->GetClientSize();
	my ($cw, $ch) = ($cs->GetWidth(), $cs->GetHeight());
	my $by = $ch - $M - $BTN_H;

	my $x = $cw - $M;
	for my $key (qw(cancel next back))
	{
		my $b = $this->{"btn_$key"};
		next if !$b || !$b->IsShown();
		$x -= $b->GetSize()->GetWidth();
		$b->Move($x, $by);
		$x -= $BTN_GAP;
	}
	if ($this->{btn_action} && $this->{btn_action}->IsShown())
	{
		$this->{btn_action}->Move($M, $by);
	}
}


# event handlers are bound as named refs (per convention) that DISPATCH to the
# object's method, so subclass overrides of onBack/onNext/onCancel/onAction are
# honored.  A bare \&onNext would freeze in the base-class (non-polymorphic) sub.

sub _evt_back   { $_[0]->onBack($_[1]); }
sub _evt_next   { $_[0]->onNext($_[1]); }
sub _evt_cancel { $_[0]->onCancel($_[1]); }
sub _evt_action { $_[0]->onAction($_[1]); }


#------------------------------
# default hooks -- steps override as needed
#------------------------------

sub onEnter  { }
sub onLeave  { }
sub onAction { }
sub onBack   { my ($this) = @_; $this->frame->goBack(); }
sub onNext   { my ($this) = @_; $this->frame->goNext(); }
sub onCancel { my ($this) = @_; $this->frame->Close(); }

1;
