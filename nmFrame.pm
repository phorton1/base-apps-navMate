#!/usr/bin/perl
#-------------------------------------------------------------------------
# nmFrame.pm
#-------------------------------------------------------------------------

package nmFrame;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use Sys::Hostname;
use Socket qw(inet_ntoa);
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_MENU
	EVT_UPDATE_UI);
use Pub::Utils qw(display warning error _def is_win);
use Pub::WX::AppConfig;
use Pub::WX::Frame;
use Pub::WX::Dialogs;
use Pub::Ray::NET::c_RAYDP;
use navVisibility qw(saveViewState);
use navSelection;
use nmResources;
use nmDialogs;
use navPrefs qw(getPref $PREF_HTTP_PORT);
use navServer;
use navTest;
use navOps;
use navLeaflet;
use navFSH;
use winDatabase;
use winE80;
use winFSH;
use winOCPN;
use navOCPN;
use winMonitor;
use Pub::Ray::NET::winFILESYS;
use navOneTimeImport;
use navKML;
use winSymMapping;
use winOCPNSymMap;
use nmE80DirectOps;
use nmE80TimedTracks;
use nmE80About;
use base qw(Pub::WX::Frame);

my $next_db_instance = 0;

my $REPO_URL        = 'https://github.com/phorton1/base-apps-navMate';
my $USER_MANUAL_URL = "$REPO_URL/blob/master/user_manual/readme.md";


sub new
{
	my ($class, $parent) = @_;
	my $rect = Wx::Rect->new(200, 100, 1100, 800);

	Pub::WX::Frame::setHowRestore($RESTORE_ALL);

	my $this = $class->SUPER::new($parent, $rect);

	EVT_MENU($this, $WIN_DATABASE,				\&onCommand);
	EVT_MENU($this, $WIN_E80,					\&onCommand);
	EVT_MENU($this, $WIN_MONITOR,				\&onCommand);
	EVT_MENU($this, $WIN_FSH,					\&onCommand);
	EVT_MENU($this, $WIN_FILESYS,				\&onCommand);
	EVT_MENU($this, $WIN_OCPN,					\&onCommand);
	EVT_MENU($this, $COMMAND_NEW_FSH,			\&onCommand);
	EVT_MENU($this, $COMMAND_OPEN_FSH_FILE,		\&onCommand);
	EVT_MENU($this, $COMMAND_SAVE_FSH_FILE,		\&onCommand);
	EVT_MENU($this, $COMMAND_SAVE_FSH_FILE_AS,	\&onCommand);
	EVT_MENU($this, $COMMAND_SAVE_FSH_OUTLINE,	\&onCommand);
	EVT_MENU($this, $COMMAND_RESTORE_FSH_OUTLINE, \&onCommand);
	EVT_MENU($this, $COMMAND_CONVERT_FSH_TO_NAVMATE, \&onCommand);
	EVT_MENU($this, $COMMAND_OPEN_MAP,			\&onCommand);
	EVT_MENU($this, $COMMAND_IMPORT_KML,		\&onCommand);
	EVT_MENU($this, $COMMAND_REFRESH_WIN_E80,	\&onCommand);
	EVT_MENU($this, $COMMAND_REFRESH_E80_DB,	\&onCommand);
	EVT_MENU($this, $COMMAND_CLEAR_E80_DB,		\&onCommand);
	EVT_MENU($this, $COMMAND_SAVE_E80_CONFIG,	\&onCommand);
	EVT_MENU($this, $COMMAND_RESTORE_E80_CONFIG,	\&onCommand);
	EVT_MENU($this, $COMMAND_CLEAR_E80_CONFIG,	\&onCommand);
	EVT_MENU($this, $COMMAND_GRAB_E80_SCREEN,	\&onCommand);
	EVT_MENU($this, $COMMAND_E80_TIMED_TRACKS,	\&onCommand);
	EVT_MENU($this, $COMMAND_E80_ABOUT,			\&onCommand);
	EVT_MENU($this, $COMMAND_RUN_NET_WIZARD,	\&onCommand);
	EVT_MENU($this, $COMMAND_REFRESH_DB,		\&onCommand);
	EVT_MENU($this, $COMMAND_EXPORT_DB_TEXT,	\&onCommand);
	EVT_MENU($this, $COMMAND_IMPORT_DB_TEXT,	\&onCommand);
	EVT_MENU($this, $COMMAND_EXPORT_KML,		\&onCommand);
	EVT_MENU($this, $COMMAND_IMPORT_KML_NM,		\&onCommand);
	EVT_MENU($this, $COMMAND_CLEAR_MAP,			\&onCommand);
	EVT_MENU($this, $COMMAND_REVERT_DB,			\&onCommand);
	EVT_MENU($this, $COMMAND_COMMIT_DB,			\&onCommand);
	EVT_MENU($this, $COMMAND_COMPACT_DB_POSITIONS, \&onCommand);
	EVT_MENU($this, $COMMAND_SYM_MAPPING,		\&onCommand);
	EVT_MENU($this, $COMMAND_FORCE_SYM_RESET,	\&onCommand);
	EVT_MENU($this, $COMMAND_OCPN_SYM_MAP,		\&onCommand);
	EVT_MENU($this, $COMMAND_SAVE_OUTLINE,		\&onCommand);
	EVT_MENU($this, $COMMAND_RESTORE_OUTLINE,	\&onCommand);
	EVT_MENU($this, $COMMAND_SAVE_SELECTION,	\&onCommand);
	EVT_MENU($this, $COMMAND_RESTORE_SELECTION,	\&onCommand);
	EVT_MENU($this, $COMMAND_HELP_USER_MANUAL,	\&onCommand);
	EVT_MENU($this, $COMMAND_ABOUT_NAVMATE,		\&onCommand);
	EVT_UPDATE_UI($this, $COMMAND_REFRESH_WIN_E80,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_REFRESH_E80_DB,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_CLEAR_E80_DB,			\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_SAVE_E80_CONFIG,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_RESTORE_E80_CONFIG,	\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_CLEAR_E80_CONFIG,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_GRAB_E80_SCREEN,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_E80_TIMED_TRACKS,	\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_E80_ABOUT,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_REVERT_DB,			\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_COMMIT_DB,			\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_SAVE_FSH_FILE,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_SAVE_FSH_FILE_AS,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_SAVE_FSH_OUTLINE,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_RESTORE_FSH_OUTLINE,	\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_CONVERT_FSH_TO_NAVMATE, \&onCommandEnable);
	EVT_IDLE($this, \&onIdle);

	my $sb = Wx::StatusBar->new($this, -1);
	$sb->SetFieldsCount(3);
	$sb->SetStatusWidths(130, -1, 200);
	$this->SetStatusBar($sb);
	$this->{statusbar} = $sb;

	my $base = $sb->GetFont();
	my $bold = Wx::Font->new($base->GetPointSize(), $base->GetFamily(),
		$base->GetStyle(), wxFONTWEIGHT_BOLD);

	$this->{st_wpmgr} = Wx::StaticText->new($sb, -1, 'WPMGR', [5,  3]);
	$this->{st_wpmgr}->SetFont($bold);
	$this->{st_track} = Wx::StaticText->new($sb, -1, 'TRACK', [72, 3]);
	$this->{st_track}->SetFont($bold);

	$this->{color_on}  = Wx::Colour->new(0,   110, 0);
	$this->{color_off} = Wx::Colour->new(180, 0,   0);

	return $this;
}


sub setStatus
{
	my ($this, $text) = @_;
	$this->{statusbar}->SetStatusText($text // '', 1);
}


sub setClipboardStatus
{
	my ($this, $text) = @_;
	$this->{statusbar}->SetStatusText($text // '', 2);
}


sub showError
{
	my ($this, $msg) = @_;
	return if $nmDialogs::suppress_error_dialog;
	$this->SUPER::showError($msg);
}


sub onIdle
{
	my ($this, $event) = @_;

	Pub::WX::ProgressDialog::forceCloseActive();
	if (!Pub::WX::ProgressDialog::isActive())
	{
		my $test_cmd = pollTestCommand();
		dispatchTestCommand($this, $test_cmd) if $test_cmd;
		my $track_edit = pollTrackEditPending();
		dispatchTrackEdit($this, $track_edit) if $track_edit;
		my $route_edit = pollRouteEditPending();
		dispatchRouteEdit($this, $route_edit) if $route_edit;
		my $wp_save = pollWaypointSavePending();
		dispatchWaypointSave($this, $wp_save) if $wp_save;
		# Publish the map-create destination (DB-tree selection) for /api/dest.
		publishMapDest($this);

		# One-time DB->map restore: the server render set is empty at startup,
		# but the db visible flags persist (view state).  Push them once, quiet
		# (no auto-zoom), so the map reflects the checkboxes after a restart.
		if (!$this->{_did_db_resync})
		{
			my @dbs = $this->_findDatabasePanes();
			if (@dbs)
			{
				$_->resyncDbToLeaflet() for @dbs;
				$this->{_did_db_resync} = 1;
			}
		}
	}

	nmE80DirectOps::onIdle($this);
	nmE80TimedTracks::onIdle($this);

	if (pollClearMapPending())
	{
		$_->onClearMap() for $this->_findDatabasePanes();
		my $e80 = $this->findPane($WIN_E80);
		$e80->onClearMap() if $e80;
		my $fsh = $this->findPane($WIN_FSH);
		$fsh->onClearMap() if $fsh;
		my $ocpn = $this->findPane($WIN_OCPN);
		$ocpn->onClearMap() if $ocpn;
	}

	my $wpmgr_on = ($raydp && $raydp->findImplementedService('WPMGR', 1)) ? 1 : 0;
	my $track_on = ($raydp && $raydp->findImplementedService('TRACK', 1)) ? 1 : 0;

	if ($wpmgr_on != ($this->{_wpmgr_on} // -1))
	{
		$this->{_wpmgr_on} = $wpmgr_on;
		$this->{st_wpmgr}->SetForegroundColour($wpmgr_on ? $this->{color_on} : $this->{color_off});
		$this->{st_wpmgr}->Refresh();
	}
	if ($track_on != ($this->{_track_on} // -1))
	{
		$this->{_track_on} = $track_on;
		$this->{st_track}->SetForegroundColour($track_on ? $this->{color_on} : $this->{color_off});
		$this->{st_track}->Refresh();
	}

	my $wpmgr_busy    = $Pub::Ray::NET::d_WPMGR::query_in_progress // 0;
	my $track_busy    = $Pub::Ray::NET::d_TRACK::query_in_progress // 0;
	my $wpmgr_queried = $Pub::Ray::NET::d_WPMGR::query_completed   // 0;
	my $track_queried = $Pub::Ray::NET::d_TRACK::query_completed    // 0;

	# Session is stable once WPMGR has completed a real query and no service
	# is currently downloading.  TRACK is optional: if absent, ignore it.
	my $session_stable =
		($wpmgr_on &&
		 !$wpmgr_busy &&
		 $wpmgr_queried &&
		 (!$track_on || (!$track_busy && $track_queried)))
		? 1 : 0;

	my $prev_stable = $this->{_e80_stable} // -1;
	if ($session_stable != $prev_stable)
	{
		$this->{_e80_stable} = $session_stable;
		my $e80 = $this->findPane($WIN_E80);
		if ($e80)
		{
			if ($session_stable)
			{
				$this->{_e80_version} = Pub::Ray::NET::b_sock::getVersion();
				$e80->onSessionStart();
			}
			else
			{
				$e80->refresh();
			}
		}
	}
	elsif ($session_stable)
	{
		my $was_active = $this->{_dialog_active} // 0;
		my $now_active = Pub::WX::ProgressDialog::isActive() ? 1 : 0;
		$this->{_dialog_active} = $now_active;

		if ($was_active && !$now_active)
		{
			$this->{_e80_dirty_time} = 0;
			my $e80 = $this->findPane($WIN_E80);
			$e80->refresh() if $e80;
		}
		else
		{
			my $v = Pub::Ray::NET::b_sock::getVersion();
			if ($v != ($this->{_e80_version} // -1))
			{
				$this->{_e80_version}    = $v;
				$this->{_e80_dirty_time} = time();
			}
			elsif ($this->{_e80_dirty_time} &&
			       !Pub::Ray::NET::d_WPMGR::getPendingCommands() &&
			       time() > $this->{_e80_dirty_time} + 0.20)
			{
				$this->{_e80_dirty_time} = 0;
				my $e80 = $this->findPane($WIN_E80);
				$e80->refresh() if $e80;
			}
		}
	}

	# OpenCPN spoke refresh clock: navOCPN bumps its shared version once per
	# inventory POST from the oESeries plugin.  Refresh the pane on change,
	# parallel to the E80 getVersion clock above (POSTs are infrequent, so no
	# debounce is needed).
	{
		my $ov = navOCPN::getSharedVersion();
		if ($ov != ($this->{_ocpn_version} // -1))
		{
			$this->{_ocpn_version} = $ov;
			my $ocpn = $this->findPane($WIN_OCPN);
			$ocpn->refresh() if $ocpn;
		}
	}

	sleep(0.02);
	$event->RequestMore();
}


sub createPane
{
	my ($this, $id, $book, $data) = @_;
	return error("No id in createPane()") if !$id;
	$book ||= $this->{book};
	display(0, 0, "nmFrame::createPane($id) book=" . _def($book) . "  data=" . _def($data));
	my $pane;
	if    ($id == $WIN_DATABASE) { $pane = winDatabase->new($this, $book, $id, $data, ++$next_db_instance); }
	elsif ($id == $WIN_E80)      { $pane = winE80->new($this, $book, $id, $data); }
	elsif ($id == $WIN_MONITOR)  { $pane = winMonitor->new($this, $book, $id, $data); }
	elsif ($id == $WIN_FSH)      { $pane = winFSH->new($this, $book, $id, $data); }
	elsif ($id == $WIN_OCPN)     { $pane = winOCPN->new($this, $book, $id, $data); }
	elsif ($id == $WIN_FILESYS)  { $pane = winFILESYS->new($this, $book, $id, $data, $CMD_DOWNLOAD); }
	else { return $this->SUPER::createPane($id, $book, $data); }
	# app-wide: the mouse wheel must not silently change combo selections
	nmResources::disableComboWheel($pane) if $pane;
	return $pane;
}


sub _findDatabasePanes
{
	my ($this) = @_;
	return grep { $_->{id} == $WIN_DATABASE } @{$this->{panes}};
}


sub _findCurrentDatabasePane
{
	my ($this) = @_;
	my $cur = $this->{current_pane};
	return $cur if $cur && $cur->{id} == $WIN_DATABASE;
	my ($first) = $this->_findDatabasePanes();
	return $first;
}


sub onCommand
{
	my ($this, $event) = @_;
	my $id = $event->GetId();
	if ($id == $WIN_DATABASE)
	{
		$this->createPane($id);
	}
	elsif ($id == $WIN_E80 || $id == $WIN_MONITOR || $id == $WIN_FSH || $id == $WIN_FILESYS || $id == $WIN_OCPN)
	{
		my $pane = $this->findPane($id);
		if (!$pane)
		{
			$this->createPane($id);
			if ($id == $WIN_E80 && $this->{_e80_stable})
			{
				my $e80 = $this->findPane($WIN_E80);
				$e80->onSessionStart() if $e80;
			}
		}
	}
	elsif ($id == $COMMAND_OPEN_MAP)
	{
		openMapBrowser() if !isBrowserConnected();
	}
	elsif ($id == $COMMAND_IMPORT_KML)
	{
		_doImportKML($this);
	}
	elsif ($id == $COMMAND_NEW_FSH)
	{
		_doNewFSH($this);
	}
	elsif ($id == $COMMAND_OPEN_FSH_FILE)
	{
		_doOpenFSH($this);
	}
	elsif ($id == $COMMAND_SAVE_FSH_FILE)
	{
		_doSaveFSH($this);
	}
	elsif ($id == $COMMAND_SAVE_FSH_FILE_AS)
	{
		_doSaveFSHAs($this);
	}
	elsif ($id == $COMMAND_SAVE_FSH_OUTLINE)
	{
		my $fsh = $this->findPane($WIN_FSH);
		$fsh->doSaveFSHOutline() if $fsh;
	}
	elsif ($id == $COMMAND_RESTORE_FSH_OUTLINE)
	{
		my $fsh = $this->findPane($WIN_FSH);
		$fsh->doRestoreFSHOutline() if $fsh;
	}
	elsif ($id == $COMMAND_CONVERT_FSH_TO_NAVMATE)
	{
		_doConvertFSHToNavMate($this);
	}
	elsif ($id == $COMMAND_REFRESH_WIN_E80)
	{
		my $e80 = $this->findPane($WIN_E80);
		$e80->refresh() if $e80;
	}
	elsif ($id == $COMMAND_REFRESH_E80_DB)
	{
		_doRefreshE80Data($this);
	}
	elsif ($id == $COMMAND_CLEAR_E80_DB)
	{
		navOps::doClearE80DB($this);
	}
	elsif ($id == $COMMAND_SAVE_E80_CONFIG)
	{
		nmE80DirectOps::doSave($this);
	}
	elsif ($id == $COMMAND_RESTORE_E80_CONFIG)
	{
		nmE80DirectOps::doRestore($this);
	}
	elsif ($id == $COMMAND_CLEAR_E80_CONFIG)
	{
		nmE80DirectOps::doClear($this);
	}
	elsif ($id == $COMMAND_GRAB_E80_SCREEN)
	{
		nmE80DirectOps::doGrab($this);
	}
	elsif ($id == $COMMAND_E80_TIMED_TRACKS)
	{
		nmE80TimedTracks::doToggle($this);
	}
	elsif ($id == $COMMAND_E80_ABOUT)
	{
		nmE80About::doAbout($this);
	}
	elsif ($id == $COMMAND_RUN_NET_WIZARD)
	{
		_doRunNetWizard($this);
	}
	elsif ($id == $COMMAND_RUN_E80MOD)
	{
		_doRunE80Mod($this);
	}
	elsif ($id == $COMMAND_REFRESH_DB)
	{
		$_->refresh() for $this->_findDatabasePanes();
	}
	elsif ($id == $COMMAND_EXPORT_DB_TEXT)
	{
		_doExportDB($this);
	}
	elsif ($id == $COMMAND_IMPORT_DB_TEXT)
	{
		_doImportDB($this);
	}
	elsif ($id == $COMMAND_EXPORT_KML)
	{
		_doExportKML($this);
	}
	elsif ($id == $COMMAND_IMPORT_KML_NM)
	{
		_doImportKMLNM($this);
	}
	elsif ($id == $COMMAND_CLEAR_MAP)
	{
		$_->onClearMap() for $this->_findDatabasePanes();
		my $e80 = $this->findPane($WIN_E80);
		$e80->onClearMap() if $e80;
		my $fsh = $this->findPane($WIN_FSH);
		$fsh->onClearMap() if $fsh;
		my $ocpn = $this->findPane($WIN_OCPN);
		$ocpn->onClearMap() if $ocpn;
	}
	elsif ($id == $COMMAND_REVERT_DB)
	{
		_doRevertDB($this);
	}
	elsif ($id == $COMMAND_COMMIT_DB)
	{
		_doCommitDB($this);
	}
	elsif ($id == $COMMAND_COMPACT_DB_POSITIONS)
	{
		_doCompactDBPositions($this);
	}
	elsif ($id == $COMMAND_SYM_MAPPING)
	{
		_doSymMapping($this);
	}
	elsif ($id == $COMMAND_FORCE_SYM_RESET)
	{
		_doForceSymReset($this);
	}
	elsif ($id == $COMMAND_OCPN_SYM_MAP)
	{
		_doOCPNSymMap($this);
	}
	elsif ($id == $COMMAND_SAVE_OUTLINE)
	{
		my $database = $this->_findCurrentDatabasePane();
		$database->doSaveOutline() if $database;
	}
	elsif ($id == $COMMAND_RESTORE_OUTLINE)
	{
		$_->doRestoreOutline() for $this->_findDatabasePanes();
	}
	elsif ($id == $COMMAND_SAVE_SELECTION)
	{
		my $database = $this->_findCurrentDatabasePane();
		if ($database)
		{
			my $dialog = Wx::TextEntryDialog->new(
				$this, 'Selection set name:', 'Save Selection', '');
			if ($dialog->ShowModal() == wxID_OK)
			{
				my $name = $dialog->GetValue();
				$database->doSaveSelection($name) if $name ne '';
			}
			$dialog->Destroy();
		}
	}
	elsif ($id == $COMMAND_RESTORE_SELECTION)
	{
		my $database = $this->_findCurrentDatabasePane();
		if ($database)
		{
			my @names = navSelection::getSelectionSetNames();
			if (!@names)
			{
				okDialog($this, 'No saved selection sets.', 'Restore Selection');
			}
			else
			{
				my $dialog = Wx::SingleChoiceDialog->new(
					$this, 'Choose a selection set:', 'Restore Selection', \@names);
				if ($dialog->ShowModal() == wxID_OK)
				{
					my $name = $dialog->GetStringSelection();
					$database->doRestoreSelection($name);
				}
				$dialog->Destroy();
			}
		}
	}
	elsif ($id == $COMMAND_HELP_USER_MANUAL)
	{
		Wx::LaunchDefaultBrowser($USER_MANUAL_URL);
	}
	elsif ($id == $COMMAND_ABOUT_NAVMATE)
	{
		_doAboutNavMate($this);
	}
}


sub _navMateVersion
	# The product version for display: the Cava-stamped version (e.g. "0.9.6.34")
	# in an installed copy, or "dev" when running from source.
{
	if ($Cava::Packager::PACKAGED)
	{
		my $v = Cava::Packager::GetInfoProductVersion();
		return (defined($v) && $v ne '') ? $v : 'unknown';
	}
	return 'dev';
}


sub _adapterName
	# Reduce an 'ipconfig /all' adapter header to the short connection name
	# Windows itself assigns -- "Ethernet adapter Ethernet:" -> "Ethernet",
	# "Wireless LAN adapter Wi-Fi:" -> "Wi-Fi", "Ethernet adapter vEthernet
	# (WSL):" -> "vEthernet (WSL)".  We keep the OS's own name rather than
	# guessing a type, so virtual adapters are named honestly (not mislabeled
	# "Ethernet").  The word "adapter" is English -- fine, since the whole
	# ipconfig path is English-anchored (see _serverAddresses).
{
	my ($header) = @_;
	$header =~ s/\s*:\s*$//;
	$header =~ s/^.*\badapter\s+//i;
	$header = substr($header, 0, 28) if length($header) > 28;
	return $header;
}


sub _serverAddresses
	# The (label, "ip:port") rows the About box offers for the OpenCPN plugin.
	# navMate's HTTP server binds INADDR_ANY, so EVERY IPv4 the host holds will
	# answer; we enumerate them all and let the user pick the one on the OpenCPN
	# box's network (the manual explains which -- the dialog can't know where the
	# client sits).  Always leads with loopback, which is correct (and, being a
	# literal IPv4, dodges the "localhost -> ::1" trap) when OpenCPN runs on this
	# machine.  Labels come from parsing 'ipconfig /all'; if that yields nothing
	# (non-English Windows, or the Linux port), we fall back to an unlabeled
	# gethostbyname() enumeration.  IPv4 only -- the server is IO::Socket::INET,
	# so ::1 / IPv6 never answer.  169.254.x (APIPA) is dropped as noise.
{
	my $port = getPref($PREF_HTTP_PORT);
	my @rows = (['Local', "127.0.0.1:$port"]);

	if (is_win())
	{
		my $text = `ipconfig /all 2>nul`;
		my $header;
		for my $line (split(/\r?\n/, $text))
		{
			if ($line =~ /^\S.*:\s*$/)		# non-indented block header
			{
				$header = $line;
			}
			elsif ($line =~ /IPv4 Address.*:\s*(\d+\.\d+\.\d+\.\d+)/)
			{
				my $ip = $1;
				next if $ip =~ /^(127\.|169\.254\.)/;
				push @rows, [_adapterName($header // 'Network'), "$ip:$port"];
			}
		}
	}

	if (@rows == 1)		# nothing parsed -- unlabeled fallback lookup
	{
		my (undef, undef, undef, undef, @packed) = gethostbyname(hostname());
		for my $p (@packed)
		{
			my $ip = inet_ntoa($p);
			next if $ip =~ /^(127\.|169\.254\.)/;
			push @rows, ['Network', "$ip:$port"];
		}
	}

	return @rows;
}


sub _doAboutNavMate
	# A small modal About box: the app name, version (Cava-stamped or "dev"), a
	# one-line description, a link to the project on GitHub, and -- for OpenCPN
	# plugin users -- the navMate server address(es) to paste into the plugin.
	# The address list is variable-length, so the dialog height is computed.
{
	my ($this) = @_;

	my @addrs    = _serverAddresses();
	my $row_y0   = 214;
	my $row_dy   = 22;
	my $rows_end = $row_y0 + @addrs * $row_dy;

	my $dlg = Wx::Dialog->new($this, -1, 'About navMate',
		wxDefaultPosition, [470, $rows_end + 84], wxDEFAULT_DIALOG_STYLE);

	my $title_font = Wx::Font->new(14, wxFONTFAMILY_DEFAULT,
		wxFONTSTYLE_NORMAL, wxFONTWEIGHT_BOLD);
	my $name = Wx::StaticText->new($dlg, -1, 'navMate', [20, 18]);
	$name->SetFont($title_font);

	Wx::StaticText->new($dlg, -1, 'Version: '._navMateVersion(), [20, 52]);
	Wx::StaticText->new($dlg, -1,
		'A navigation-knowledge hub for Raymarine E-Series chartplotters.',
		[20, 80], [420, 36]);

	Wx::HyperlinkCtrl->new($dlg, -1, $REPO_URL, $REPO_URL, [20, 124]);
	Wx::StaticText->new($dlg, -1, 'Copyright (c) 2026 Patrick Horton', [20, 150]);

	Wx::StaticText->new($dlg, -1,
		'navMate server (enter into the OpenCPN plugin):', [20, 186]);

	my $y = $row_y0;
	for my $row (@addrs)
	{
		Wx::StaticText->new($dlg, -1, $row->[0], [40,  $y], [190, -1]);
		Wx::StaticText->new($dlg, -1, $row->[1], [240, $y]);
		$y += $row_dy;
	}

	my $ok = Wx::Button->new($dlg, wxID_OK, 'OK',
		[370, $rows_end + 16], [80, 28]);
	$ok->SetDefault();

	$dlg->ShowModal();
	$dlg->Destroy();
}


sub onCloseFrame
{
	my ($this, $event) = @_;
	my ($database) = $this->_findDatabasePanes();
	$database->doSaveOutline() if $database;
	my $fsh = $this->findPane($WIN_FSH);
	$fsh->doSaveFSHOutline() if $fsh;
	navDB::pruneDbVisibility();
	saveViewState();
	$this->SUPER::onCloseFrame($event);
}


sub onCommandEnable
{
	my ($this, $event) = @_;
	my $id = $event->GetId();
	my $enable = 1;

	if ($id == $COMMAND_REFRESH_WIN_E80)
	{
		$enable = 0 if !$this->findPane($WIN_E80);
	}
	elsif ($id == $COMMAND_REFRESH_E80_DB)
	{
		$enable = 0 if !($raydp && $raydp->findImplementedService('WPMGR', 1));
	}
	elsif ($id == $COMMAND_CLEAR_E80_DB)
	{
		my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
		if (!$wpmgr)
		{
			$enable = 0;
		}
		else
		{
			my $track = $raydp ? $raydp->findImplementedService('TRACK', 1) : undef;
			$enable = 0 if !(%{$wpmgr->{routes}    // {}}
			             || %{$wpmgr->{groups}    // {}}
			             || %{$wpmgr->{waypoints} // {}}
			             || ($track && %{$track->{tracks} // {}}));
		}
	}
	elsif ($id == $WIN_FILESYS)
	{
		$enable = 0 if !nmE80DirectOps::hasFilesysService();
	}
	elsif ($id == $COMMAND_SAVE_E80_CONFIG
	    || $id == $COMMAND_RESTORE_E80_CONFIG
	    || $id == $COMMAND_CLEAR_E80_CONFIG)
	{
		$enable = 0 if !nmE80DirectOps::opDeviceCount('save');	# config ops share the v5.71 floor
	}
	elsif ($id == $COMMAND_GRAB_E80_SCREEN)
	{
		$enable = 0 if !nmE80DirectOps::opDeviceCount('grab');	# screen grab needs v5.72
	}
	elsif ($id == $COMMAND_E80_ABOUT)
	{
		$enable = 0 if !nmE80DirectOps::deviceCount();			# any reachable unit (no firmware floor)
	}
	elsif ($id == $COMMAND_E80_TIMED_TRACKS)
	{
		$enable = 0 if !nmE80TimedTracks::available();
	}
	elsif ($id == $COMMAND_REVERT_DB || $id == $COMMAND_COMMIT_DB)
	{
		my $now = time();
		if (!defined($this->{_db_dirty_time}) || $now - $this->{_db_dirty_time} >= 2)
		{
			$this->{_db_dirty_time} = $now;
			my $out = qx(git -C "C:/dat/Rhapsody" status --porcelain navMate.db 2>&1);
			$this->{_db_dirty} = ($out =~ /\S/) ? 1 : 0;
		}
		$enable = 0 if !$this->{_db_dirty};
	}
	elsif ($id == $COMMAND_SAVE_FSH_FILE)
	{
		# Save (overwrite) requires a current filename AND pending changes
		$enable = 0 if !$navFSH::fsh_db || !$navFSH::fsh_filename || !$navFSH::fsh_dirty;
	}
	elsif ($id == $COMMAND_SAVE_FSH_FILE_AS
	    || $id == $COMMAND_SAVE_FSH_OUTLINE
	    || $id == $COMMAND_RESTORE_FSH_OUTLINE
	    || $id == $COMMAND_CONVERT_FSH_TO_NAVMATE)
	{
		$enable = 0 if !$navFSH::fsh_db;
	}

	$event->Enable($enable);
}


sub _doExportDB
{
	my ($this) = @_;
	my $default_dir = readConfig('db_backup_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Export Database',
		$default_dir, 'navMate_backup.txt',
		'Text files (*.txt)|*.txt|All files (*.*)|*.*',
		wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('db_backup_dir', $dialog->GetDirectory());
		my $dbh = navDB::connectDB();
		if ($dbh)
		{
			display(0,0,"nmFrame: exporting database to $filename");
			my $progress = Pub::WX::ProgressDialog->new($this, 'Exporting Database...', 0, 7);
			$dbh->exportDatabaseText($filename, $progress);
			$progress->Destroy();
			navDB::disconnectDB($dbh);
			display(0,0,"nmFrame: export complete");
		}
	}
	$dialog->Destroy();
}


sub _doImportDB
{
	my ($this) = @_;
	return if !yesNoDialog($this,
		"This will REPLACE the entire navMate database with the contents of the backup file.\n\nAre you sure?",
		'Import Database');
	my $default_dir = readConfig('db_backup_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Import Database',
		$default_dir, '',
		'Text files (*.txt)|*.txt|All files (*.*)|*.*',
		wxFD_OPEN | wxFD_FILE_MUST_EXIST);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('db_backup_dir', $dialog->GetDirectory());
		display(0,0,"nmFrame: importing database from $filename");
		navDB::resetDB();
		my $dbh = navDB::connectDB();
		if ($dbh)
		{
			my $progress = Pub::WX::ProgressDialog->new($this, 'Importing Database...', 0, 7);
			$dbh->importDatabase($filename, $progress);
			$progress->Destroy();
			navDB::disconnectDB($dbh);
			$_->refresh() for $this->_findDatabasePanes();
			display(0,0,"nmFrame: import complete");
		}
	}
	$dialog->Destroy();
}


sub _doExportKML
{
	my ($this) = @_;
	my $default_dir = readConfig('kml_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Export KML',
		$default_dir, 'navMate.kml',
		'KML files (*.kml)|*.kml|All files (*.*)|*.*',
		wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('kml_dir', $dialog->GetDirectory());
		eval { navKML::exportKML($filename) };
		error("Export KML failed: $@") if $@;
	}
	$dialog->Destroy();
}


sub _doImportKMLNM
{
	my ($this) = @_;
	my $default_dir = readConfig('kml_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Import KML',
		$default_dir, '',
		'KML files (*.kml)|*.kml|All files (*.*)|*.*',
		wxFD_OPEN | wxFD_FILE_MUST_EXIST);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('kml_dir', $dialog->GetDirectory());
		eval { navKML::importKML($filename) };
		if ($@)
		{
			error("Import KML failed: $@");
		}
		else
		{
			$_->refresh() for $this->_findDatabasePanes();
		}
	}
	$dialog->Destroy();
}


sub _doImportKML
{
	my ($this) = @_;
	return if !yesNoDialog($this,
		"This will DELETE and rebuild the entire navMate database from KML files.\n\nAre you sure?",
		'OneTimeImportKML');
	display(0,0,"nmFrame: ImportKML starting");
	my $rc = navDB::resetDB();
	if ($rc <= 0)
	{
		warning(0,0,"nmFrame: ImportKML aborted - resetDB returned $rc");
		return;
	}
	navOneTimeImport::run();
	$_->refresh() for $this->_findDatabasePanes();
	display(0,0,"nmFrame: ImportKML done");
}


sub _doSymMapping
{
	my ($this) = @_;
	my $changed = showSymMappingDialog($this);
	if ($changed)
	{
		$_->refresh() for $this->_findDatabasePanes();
	}
}


sub _doForceSymReset
{
	my ($this) = @_;
	my $changed = showForceSymResetDialog($this);
	if ($changed)
	{
		$_->refresh() for $this->_findDatabasePanes();
	}
}


sub _doOCPNSymMap
{
	my ($this) = @_;
	# The sym <-> OpenCPN icon map is consumed at push-out and ingest, not in
	# any open pane's current render, so there is nothing to refresh here.
	showOCPNSymMapDialog($this);
}


sub _doNewFSH
{
	my ($this) = @_;
	return if !_confirmDiscardFSH($this, 'create a new FSH');
	navFSH::newFSH();
	my $fsh = $this->findPane($WIN_FSH);
	if ($fsh)
		{ $fsh->refresh(); }
	else
		{ $this->createPane($WIN_FSH); }
}


sub _doOpenFSH
{
	my ($this) = @_;
	return if !_confirmDiscardFSH($this, 'open another FSH');
	my $default_dir = readConfig('fsh_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Open FSH File',
		$default_dir, '',
		'FSH files (*.fsh)|*.fsh|All files (*.*)|*.*',
		wxFD_OPEN | wxFD_FILE_MUST_EXIST);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('fsh_dir', $dialog->GetDirectory());
		if (navFSH::loadFSH($filename))
		{
			my $fsh = $this->findPane($WIN_FSH);
			if ($fsh)
				{ $fsh->refresh(); }
			else
				{ $this->createPane($WIN_FSH); }
		}
	}
	$dialog->Destroy();
}


sub _confirmDiscardFSH
	# Called by _doNewFSH, _doOpenFSH, and winFSH::closeOK (app exit) before
	# any action that would discard the in-memory FSH.  Returns 1 if it is
	# OK to proceed, 0 if the user cancelled.  Side effect: on "Save",
	# performs the save (or save-as when untitled) and returns 1 only if
	# the save succeeded.
{
	my ($this, $verb) = @_;
	return 1 if !$navFSH::fsh_db || !$navFSH::fsh_dirty;

	my $rslt = yesNoCancelDialog($this,
		"The FSH document has unsaved changes.\n\n".
		"Yes    = Save before you $verb\n".
		"No     = Discard changes\n".
		"Cancel = stay in this FSH",
		'FSH has unsaved changes');

	return 0 if $rslt < 0;     # Cancel
	return 1 if $rslt == 0;    # Discard

	# Yes -> Save (silent: skip the standard overwrite confirm, the user
	# is already in a serial dialog flow).
	if ($navFSH::fsh_filename)
	{
		return navFSH::saveFSH($navFSH::fsh_filename) ? 1 : 0;
	}
	return _saveFSHAsInteractive($this);
}


sub _saveFSHAsInteractive
	# File-dialog driven Save As.  Returns 1 on success, 0 on cancel/failure.
	# Shared by _doSaveFSHAs and the Yes branch of _confirmDiscardFSH.
{
	my ($this) = @_;
	my $default_dir = readConfig('fsh_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Save FSH File As',
		$default_dir, '',
		'FSH files (*.fsh)|*.fsh|All files (*.*)|*.*',
		wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
	my $rc = 0;
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('fsh_dir', $dialog->GetDirectory());
		if (navFSH::saveFSH($filename))
		{
			$navFSH::fsh_filename = $filename;
			my $fsh = $this->findPane($WIN_FSH);
			$fsh->onFilenameChanged() if $fsh;
			$rc = 1;
		}
	}
	$dialog->Destroy();
	return $rc;
}


sub _doSaveFSH
{
	my ($this) = @_;
	my $filename = $navFSH::fsh_filename;
	if (!$filename)
	{
		error("nmFrame: _doSaveFSH called with no current filename");
		return;
	}
	return if !yesNoDialog($this,
		"This will OVERWRITE the FSH file:\n\n$filename\n\nAre you sure?",
		'Save FSH File');
	navFSH::saveFSH($filename);
}


sub _doSaveFSHAs
{
	my ($this) = @_;
	_saveFSHAsInteractive($this);
}


sub _doConvertFSHToNavMate
{
	my ($this) = @_;
	if (!$navFSH::fsh_db)
	{
		error("nmFrame: _doConvertFSHToNavMate called with no FSH loaded");
		return;
	}
	my $stats = navFSH::convertToNavMate();
	my $fsh = $this->findPane($WIN_FSH);
	$fsh->refresh() if $fsh;

	my $msg;
	if (!$stats->{tracks_converted})
	{
		$msg = sprintf("No tracks needed conversion.\n\n%d single-segment track(s) unchanged.",
			$stats->{tracks_unchanged});
	}
	else
	{
		$msg = sprintf("Converted %d track(s) into %d segment(s).\n\n%d track(s) unchanged.\n\nUse FSH -> Save File (or Save As...) to persist.",
			$stats->{tracks_converted},
			$stats->{segments_created},
			$stats->{tracks_unchanged});
	}
	okDialog($this, $msg, 'Convert to navMate Working Copy');
}


sub _doRefreshE80Data
{
	my ($parent) = @_;
	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	my $track = $raydp ? $raydp->findImplementedService('TRACK') : undef;
	if (!($wpmgr && $track))
	{
		okDialog($parent, "The ESeries plotter is not connected - cannot refresh.", "Refresh ESeries");
		return;
	}
	if ($Pub::Ray::NET::d_WPMGR::query_in_progress ||
	    $Pub::Ray::NET::d_TRACK::query_in_progress)
	{
		okDialog($parent, "A query is already in progress - please wait.", "Refresh ESeries");
		return;
	}
	my $progress = Pub::WX::ProgressDialog::newProgressData(4, 2);
	$progress->{active} = 1;
	my $dlg = Pub::WX::ProgressDialog->new($parent, 'Refreshing ESeries...', 1, $progress);
	return if !$dlg;
	$wpmgr->queueRefresh($progress);
	$track->queueRefresh($progress);
}


sub _doRunNetWizard
	# Launch the standalone E-Series network wizard (netWizard).
	# Packaged: ShellExecute the sibling netWizard.exe in {app}/bin,
	# elevated via Start-Process -Verb RunAs (it also carries a
	# requireAdministrator manifest).  Dev: run the .pm via perl --
	# the wizard's Apply step self-annotates when not elevated.
{
	my ($this) = @_;
	if ($Cava::Packager::PACKAGED)
	{
		my $bin = Cava::Packager::GetBinPath();
		$bin =~ s{[\\/]+$}{};
		my $exe = "$bin/netWizard.exe";
		if (!-e $exe)
		{
			error("netWizard.exe not found at $exe");
			return;
		}
		(my $bin_w = $bin) =~ s{/}{\\}g;
		(my $exe_w = $exe) =~ s{/}{\\}g;
		my $ps = "Start-Process -FilePath '$exe_w' -WorkingDirectory '$bin_w' -Verb RunAs";
		system(1, "powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", $ps);
	}
	else
	{
		my $wiz = '/base/apps/navMate/_netWizard/netWizard.pm';
		system(1, $^X, "-I/base", $wiz);
	}
}


sub _doRunE80Mod
	# Launch the standalone E-Series firmware builder (e80Mod).  Packaged:
	# Start-Process the sibling e80Mod.exe in {app}/bin -- NOT elevated (unlike
	# netWizard): e80Mod is a pure offline file transform, no netsh, no NOR.  Dev:
	# run the .pm via perl.
{
	my ($this) = @_;
	if ($Cava::Packager::PACKAGED)
	{
		my $bin = Cava::Packager::GetBinPath();
		$bin =~ s{[\\/]+$}{};
		my $exe = "$bin/e80Mod.exe";
		if (!-e $exe)
		{
			error("e80Mod.exe not found at $exe");
			return;
		}
		(my $bin_w = $bin) =~ s{/}{\\}g;
		(my $exe_w = $exe) =~ s{/}{\\}g;
		my $ps = "Start-Process -FilePath '$exe_w' -WorkingDirectory '$bin_w'";
		system(1, "powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", $ps);
	}
	else
	{
		my $app = '/base/apps/navMate/_e80Mod/e80Mod.pm';
		system(1, $^X, "-I/base", $app);
	}
}


sub _doRevertDB
{
	my ($this) = @_;
	return if !yesNoDialog($this,
		"This will revert navMate.db to the last git-committed version.\n\nAre you sure?",
		'Revert navMate.db');
	my $out = qx(git -C "C:/dat/Rhapsody" restore navMate.db 2>&1);
	if ($?)
	{
		error("Revert navMate.db failed: $out");
		return;
	}
	display(0, 0, "nmFrame: navMate.db reverted to last committed version");
	my $rc = navDB::openDB();
	warning(0, 0, "nmFrame: openDB after revert returned $rc") if $rc <= 0;
	if ($rc > 0)
	{
		navDB::pruneDbVisibility();
		saveViewState();
	}
	my @dbs = $this->_findDatabasePanes();
	$_->refresh() for @dbs;
	$_->resyncDbToLeaflet() for @dbs;
}


sub _doCommitDB
{
	my ($this) = @_;
	my $dialog = Wx::TextEntryDialog->new(
		$this, 'Commit message:', 'Commit navMate.db', 'navMate.db update');
	my $result = $dialog->ShowModal();
	my $msg    = $dialog->GetValue();
	$dialog->Destroy();
	return if $result != wxID_OK || !$msg;

	my $tmp = 'C:/base_data/temp/raymarine/_db_commit_msg.txt';
	my $fh;
	if (!open($fh, '>', $tmp))
	{
		error("Commit navMate.db: cannot write temp file $tmp");
		return;
	}
	print $fh $msg;
	close $fh;

	my $out = qx(git -C "C:/dat/Rhapsody" add navMate.db 2>&1);
	if ($?)
	{
		error("Commit navMate.db git add failed: $out");
		return;
	}
	$out = qx(git -C "C:/dat/Rhapsody" commit -F "$tmp" 2>&1);
	if ($?)
	{
		error("Commit navMate.db git commit failed: $out");
		return;
	}
	display(0, 0, "nmFrame: navMate.db committed: $msg");
}


sub _doCompactDBPositions
{
	my ($this) = @_;
	return if !yesNoDialog($this,
		"This will renumber every container's child positions to 1.0, 2.0, 3.0, ...\n\n"
		. "Used once to normalize legacy zero-positions, and thereafter for precision-wall reclamation.\n\n"
		. "Proceed?",
		'Compact Database Positions');
	my $dbh = navDB::connectDB();
	if (!$dbh)
	{
		error("Compact Positions: could not open database");
		return;
	}
	my ($n_conts, $n_rows) = navDB::compactAllContainers($dbh);
	navDB::disconnectDB($dbh);
	if ($n_rows > 0)
	{
		display(0, 0, "nmFrame: compacted $n_rows row(s) across $n_conts container(s)");
		$_->refresh() for $this->_findDatabasePanes();
		okDialog($this,
			"Compacted $n_rows row(s) across $n_conts container(s).",
			'Compact Database Positions');
	}
	else
	{
		display(0, 0, "nmFrame: compact -- no changes needed; DB already compact");
		okDialog($this,
			"No compact needed -- all positions already normalized.",
			'Compact Database Positions');
	}
}


1;
