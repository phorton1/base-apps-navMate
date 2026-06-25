#---------------------------------------------
# PreInstallApp.pm  (navMate)
#---------------------------------------------
# Run by Cava Packager after the build but BEFORE the Inno Setup compile.
# Cava (2.0, abandonware) emits an innosetup.iss for an older Inno Setup;
# this script rewrites it for the installed Inno Setup 5.5.9, which would
# otherwise fail the compile.  Modelled on apps/buddy/_installer/PreInstallApp.pm,
# trimmed to the 5.5.9 compatibility fixups (navMate needs no PATH code) PLUS two
# feature injections Cava can't express: (1) the optional post-install "run the
# network wizard" checkbox ([Run] -> {app}\bin\netWizard.exe), and (2) idempotent
# Windows Firewall inbound-allow rules for the three exes so RAYDP discovery never
# trips the "allow access" prompt (with matching [UninstallRun] cleanup).
#
# Cava invokes:   perl PreInstallApp.pm <release_dir> <installer_dir>
# The file rewritten is <installer_dir>/innosetup.iss.
#
# Fixups (each is an ISCC fatal under 5.5.9):
#   MinVersion=,<nt>           legacy two-part (9x,NT) form; 9x support was
#                              dropped in 5.5.x so the comma form is invalid.
#   OutputManifestFile=<path>  a path is no longer accepted; reduced to the
#                              bare filename (re-emitted in [Setup]).
#   [Languages] ...            Cava lists ~20 languages incl. Basque/Slovak
#                              whose .isl files no longer ship; the whole
#                              section is removed (default English messages).

use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path);

my $release_dir   = $ARGV[0];
my $installer_dir = $ARGV[1];
my $iss_file      = "$installer_dir/innosetup.iss";

my $in_languages = 0;

# e80Mod's ONLY runtime data dependency is the firmware mod records
# (mods/e80_mod*.txt).  Those records are sacrosanct (upstream-projected,
# alongside the e80*.pm libs at the repo root) and are NOT a Cava resource, so
# the build DENORMALIZES a copy of them into the freshly built release resource
# tree, from which Inno's recursesubdirs [Files] installs them to {app}\res\mods.
# Packaged e80Mod reads them from $resource_dir/mods (em_defs::mods_dir).  We glob
# EVERY e80_mod*.txt so a newly-added record ships automatically -- the build
# remembers, so we don't have to.
my $MODS_SRC = 'C:/base/apps/navMate/mods';

sub shipModRecords
{
	my ($release_dir) = @_;
	my $dst = "$release_dir/res/mods";
	my @recs = glob("$MODS_SRC/e80_mod*.txt");
	if (!@recs)
	{
		warn "PreInstallApp: no mod records found in $MODS_SRC -- e80Mod will not build when installed\n";
		return;
	}
	if (!-d $dst && !make_path($dst))
	{
		warn "PreInstallApp: cannot create $dst: $!\n";
		return;
	}
	for my $src (@recs)
	{
		(my $name = $src) =~ s{^.*/}{};
		if (copy($src, "$dst/$name"))
		{
			print "PreInstallApp: shipped mod record $name -> res/mods/\n";
		}
		else
		{
			warn "PreInstallApp: cannot copy $src -> $dst/$name: $!\n";
		}
	}
}

# Programs that open inbound (RAYDP discovery) sockets.  Pre-authorize them in
# Windows Firewall during install so the user never sees the "allow access"
# prompt.  Emitted delete-then-add (idempotent -- no duplicate rules accumulate
# across reinstalls), with a matching delete in [UninstallRun].
my @FIREWALL_RULES = (
	[ 'navMate'        => 'navMate.exe'    ],
	[ 'navMate GUI'    => 'navMateGUI.exe' ],
	[ 'navMate Wizard' => 'netWizard.exe'  ],
);

sub firewallRunLines
	# [Run] block: per exe, delete any prior rule of this name (harmless if
	# none match) then add the inbound allow rule.  RunHidden, during install.
	# remoteip=10.0.0.0/8 scopes the allow to the RAYNET /8 the wizard configures,
	# so the program is unreachable on any non-10.x network.  (The host firewall
	# only ever governs same-LAN peers regardless -- NAT blocks the internet.)
{
	my $out = "; added by PreInstallApp.pm -- pre-authorize inbound RAYDP so no firewall prompt\n";
	for my $r (@FIREWALL_RULES)
	{
		my ($name, $exe) = @$r;
		$out .= qq(Filename: "{sys}\\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""$name"""; Flags: runhidden\n);
		$out .= qq(Filename: "{sys}\\netsh.exe"; Parameters: "advfirewall firewall add rule name=""$name"" dir=in action=allow program=""{app}\\bin\\$exe"" enable=yes profile=any remoteip=10.0.0.0/8"; Flags: runhidden\n);
	}
	return $out;
}

sub firewallUninstallSection
	# A whole [UninstallRun] section that removes the rules on uninstall.
{
	my $out = "; added by PreInstallApp.pm -- remove the firewall rules on uninstall\n[UninstallRun]\n";
	for my $r (@FIREWALL_RULES)
	{
		my ($name) = @$r;
		$out .= qq(Filename: "{sys}\\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""$name"""; Flags: runhidden\n);
	}
	return $out;
}


sub agreementsCodeSection
	# A [Code] section (Cava emits none) that replaces Inno's native license page with
	# two consistent custom pages, inserted after the Welcome page in order:
	#   1. Notice to Mariners      2. License Agreement (GPL3)
	# Each is a read-only memo of its document -- extracted at install time from the
	# dontcopy [Files] payload, so the source files stay the single source of truth --
	# plus an "I agree" checkbox.  The checkbox is SCROLL-GATED: the instant it is
	# ticked we sample the memo's vertical scrollbar via GetScrollInfo, and if the user
	# has not reached the bottom we un-tick it and prompt.  Sampling at click time
	# catches every scroll method (wheel, scrollbar, keyboard) -- the only reliable way
	# under Inno 5.x, which lacks the CreateCallback timers Inno 6 would use to watch
	# scrolling live.  A document short enough to need no scrollbar counts as read, so
	# Next enables immediately.  CreateCustomPage anchors on wpWelcome regardless of
	# whether the Welcome page is itself displayed, so the ordering holds either way.
{
	return <<"EOC";

; added by PreInstallApp.pm -- Notice to Mariners + License agreement (scroll-gated checkbox pages)
[Code]
type
  TScrollInfo = record
    cbSize: Cardinal;
    fMask: Cardinal;
    nMin: Integer;
    nMax: Integer;
    nPage: Cardinal;
    nPos: Integer;
    nTrackPos: Integer;
  end;

function GetScrollInfo(hWnd: HWND; BarFlag: Integer; var ScrollInfo: TScrollInfo): BOOL;
  external 'GetScrollInfo\@user32.dll stdcall';

const
  SB_VERT = 1;
  SIF_RANGE = 1;
  SIF_PAGE = 2;
  SIF_POS = 4;

var
  NoticePageID, LicensePageID: Integer;
  NoticeMemo, LicenseMemo: TNewMemo;
  NoticeCheck, LicenseCheck: TNewCheckBox;

function ScrolledToBottom(Memo: TNewMemo): Boolean;
var
  SI: TScrollInfo;
begin
  SI.cbSize := SizeOf(SI);
  SI.fMask := SIF_RANGE or SIF_PAGE or SIF_POS;
  if GetScrollInfo(Memo.Handle, SB_VERT, SI) then
    Result := (SI.nMax <= 0) or (SI.nPos >= SI.nMax - Integer(SI.nPage))
  else
    Result := True;
end;

procedure GateCheck(Memo: TNewMemo; Check: TNewCheckBox);
begin
  if Check.Checked and not ScrolledToBottom(Memo) then
  begin
    Check.Checked := False;
    MsgBox('Please scroll to the bottom of the document before accepting.', mbInformation, MB_OK);
  end;
  WizardForm.NextButton.Enabled := Check.Checked;
end;

procedure NoticeCheckClick(Sender: TObject);
begin
  GateCheck(NoticeMemo, NoticeCheck);
end;

procedure LicenseCheckClick(Sender: TObject);
begin
  GateCheck(LicenseMemo, LicenseCheck);
end;

function MakeAgreementPage(AfterID: Integer; ACaption, ADescription, ADocFile, ACheckCaption: String; var Memo: TNewMemo; var Check: TNewCheckBox): Integer;
var
  Page: TWizardPage;
  A: AnsiString;
  S: String;
begin
  Page := CreateCustomPage(AfterID, ACaption, ADescription);

  Memo := TNewMemo.Create(WizardForm);
  Memo.Parent := Page.Surface;
  Memo.Left := 0;
  Memo.Top := 0;
  Memo.Width := Page.SurfaceWidth;
  Memo.Height := Page.SurfaceHeight - ScaleY(28);
  Memo.ReadOnly := True;
  Memo.WordWrap := True;
  Memo.ScrollBars := ssVertical;
  ExtractTemporaryFile(ADocFile);
  if LoadStringFromFile(ExpandConstant('{tmp}\\' + ADocFile), A) then
  begin
    // A Windows edit control breaks lines only on CRLF; normalize so the memo
    // wraps correctly whether the source file is LF or CRLF.
    S := A;
    StringChangeEx(S, #13#10, #10, True);
    StringChange(S, #10, #13#10);
    Memo.Text := S;
  end
  else
    Memo.Text := '(' + ADocFile + ' could not be loaded)';

  Check := TNewCheckBox.Create(WizardForm);
  Check.Parent := Page.Surface;
  Check.Left := 0;
  Check.Top := Page.SurfaceHeight - ScaleY(22);
  Check.Width := Page.SurfaceWidth;
  Check.Height := ScaleY(20);
  Check.Caption := ACheckCaption;

  Result := Page.ID;
end;

procedure InitializeWizard();
begin
  NoticePageID := MakeAgreementPage(wpWelcome, 'Notice to Mariners', 'Please read this notice carefully before continuing.', 'NOTICE_TO_MARINERS.txt', 'I have read and agree to this Notice to Mariners.', NoticeMemo, NoticeCheck);
  NoticeCheck.OnClick := \@NoticeCheckClick;

  LicensePageID := MakeAgreementPage(NoticePageID, 'License Agreement', 'Please read the following license agreement.', 'LICENSE.TXT', 'I have read and agree to the terms and conditions.', LicenseMemo, LicenseCheck);
  LicenseCheck.OnClick := \@LicenseCheckClick;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = NoticePageID then
    WizardForm.NextButton.Enabled := NoticeCheck.Checked
  else if CurPageID = LicensePageID then
    WizardForm.NextButton.Enabled := LicenseCheck.Checked;
end;
EOC
}


sub processLine
{
	my ($line) = @_;

	# The [Languages] section runs to EOF; comment all of it out.
	if ($in_languages)
	{
		return $line =~ /\S/ ? "; $line" : $line;
	}
	if ($line eq '[Languages]')
	{
		$in_languages = 1;
		return "; [Languages] removed by PreInstallApp.pm ".
			"(Basque/Slovak .isl no longer ship in Inno 5.5.9)\n; $line";
	}

	# Re-emit the 5.5.9-safe directives right after the [Setup] header.
	if ($line eq '[Setup]')
	{
		return $line."\n".
			"; added by PreInstallApp.pm\n".
			"CloseApplications=force\n".
			"OutputManifestFile=innosetup.manifest";
	}

	# NOTE: the GPL3 license is NOT wired to Inno's native LicenseFile= page (which
	# carries the "I do not accept" radio Patrick dislikes and can't scroll-gate).
	# Both the Notice to Mariners and the license are custom scroll-gated checkbox
	# pages built in the [Code] section (see agreementsCodeSection); the documents are
	# carried as dontcopy [Files] payload and extracted at run time.

	# First-time install: seed the user's data dir.  onlyifdoesntexist => fresh
	# machines only, never clobber an existing hub; uninsneveruninstall => never
	# removed on uninstall.  Target is the user's OWN Documents (user-writable, no
	# admin).  Sourced from _installer/examples (installer payload, NOT _res -- the
	# app never reads these at runtime).
	if ($line eq '[Files]')
	{
		my $ex = 'C:\\base\\apps\\navMate\\_installer\\examples';
		return $line."\n".
			"; added by PreInstallApp.pm -- seed user data on a fresh install\n".
			qq(Source: "$ex\\example.db"; DestDir: "{userdocs}\\phorton1\\navMate"; DestName: "navMate.db"; Flags: onlyifdoesntexist uninsneveruninstall\n).
			qq(Source: "$ex\\*"; DestDir: "{userdocs}\\phorton1\\navMate\\examples"; Flags: ignoreversion uninsneveruninstall\n).
			"; added by PreInstallApp.pm -- agreement docs, extracted at run time by the Notice/License [Code] pages (dontcopy = not installed)\n".
			qq(Source: "C:\\base\\apps\\navMate\\NOTICE_TO_MARINERS.txt"; Flags: dontcopy\n).
			qq(Source: "C:\\base\\apps\\navMate\\LICENSE.TXT"; Flags: dontcopy);
	}

	# Append the optional post-install "run the network wizard" checkbox.
	# The installer runs elevated (PrivilegesRequired=admin), so this launches
	# the (requireAdministrator) wizard already elevated -- no extra UAC prompt.
	if ($line eq '[Run]')
	{
		return $line."\n".
			firewallRunLines().
			"; added by PreInstallApp.pm -- optional post-install launch of the network wizard\n".
			'Filename: {app}\bin\netWizard.exe; Description: "Run the navMate network wizard now (set up your E-Series connection)"; WorkingDir: {app}\bin; Flags: postinstall nowait skipifsilent runascurrentuser 32bit; StatusMsg: "Launching the network wizard ...";';
	}

	# Inject an [UninstallRun] section (Cava emits none) right before [Icons].
	if ($line eq '[Icons]')
	{
		return firewallUninstallSection()."\n".$line;
	}

	# Drop the lines Inno 5.5.9 rejects.
	if ($line =~ /^MinVersion=/ ||         # legacy 9x,NT form -- invalid
		$line =~ /^OutputManifestFile=/)   # path form -- re-added bare in [Setup]
	{
		return "; commented by PreInstallApp.pm\n; $line";
	}

	return $line;
}


# Ship e80Mod's firmware mod records into the release resource tree (must happen
# every build so a new record is never left behind).
shipModRecords($release_dir);

# Read, rewrite, write back.  No die/exit -- a failure just warns (Cava
# captures it) and leaves the file untouched.

my $in;
if (open($in, '<', $iss_file))
{
	my @lines = <$in>;
	close($in);

	my $text = '';
	for my $line (@lines)
	{
		chomp $line;
		$text .= processLine($line)."\n";
	}

	# Append the Notice + License [Code] pages (Cava emits no [Code] section).
	$text .= agreementsCodeSection();

	my $out;
	if (open($out, '>', $iss_file))
	{
		print $out $text;
		close($out);
		print "PreInstallApp: rewrote $iss_file for Inno 5.5.9\n";
	}
	else
	{
		warn "PreInstallApp: cannot write $iss_file: $!\n";
	}
}
else
{
	warn "PreInstallApp: cannot read $iss_file: $!\n";
}

1;
