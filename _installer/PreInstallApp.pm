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

my $unused_release_dir = $ARGV[0];
my $installer_dir      = $ARGV[1];
my $iss_file           = "$installer_dir/innosetup.iss";

my $in_languages = 0;

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
