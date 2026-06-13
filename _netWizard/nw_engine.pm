#---------------------------------------------
# nw_engine.pm
#---------------------------------------------
# The netWizard ENGINE: UI-free network work.  Depends only on the shared
# Pub::Ray::NET::a_defs (constants) and Pub::Utils -- nothing from navMate.
#
#   - probe_network()       one PowerShell call -> (\@adapters, $elevated)
#   - up_nics()             the adapters we can listen on
#   - search_open_all/...   listen for RAYDP on ALL up NICs at once; the NIC
#                           that HEARS the plotter is the SeaTalkHS path
#                           (authoritative -- gateway presence does NOT gate this)
#   - apply/revert_address  set the adapter to a static IP (replace), and back
#                           to Automatic (DHCP) -- the standard Windows model

package nw_engine;
use strict;
use warnings;
use Socket;
use Time::HiRes qw(time);
use IO::Select;
use IO::Socket::Multicast;
use Pub::Utils;
use Pub::Ray::NET::a_defs;
use nw_defs;


#------------------------------------------
# detection (read-only)
#------------------------------------------

sub probe_network
	# ONE PowerShell call: returns (\@adapters, $elevated).
	# each adapter = { alias, status, ipv4 (first), ipv4_all, gateway }
{
	my $ps = q{$e=[bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)); Write-Output ('ELEV|'+$e); Get-NetIPConfiguration | ForEach-Object { 'NIC|'+$_.InterfaceAlias+'|'+$_.NetAdapter.Status+'|'+(($_.IPv4Address.IPAddress) -join ',')+'|'+(($_.IPv4DefaultGateway.NextHop) -join ',') }};

	my @lines = `powershell -NoProfile -Command "$ps" 2>&1`;
	my @adapters;
	my $elev = 0;
	for my $line (@lines)
	{
		$line =~ s/[\r\n]//g;
		if ($line =~ /^ELEV\|(.*)/)
		{
			$elev = $1 =~ /True/i ? 1 : 0;
			next;
		}
		next if $line !~ /^NIC\|/;
		my (undef, $alias, $status, $ipv4, $gw) = split(/\|/, $line, 5);
		my ($first_ip) = split(/,/, ($ipv4 || ''));
		my $rec = {
			alias		=> $alias		// '',
			status		=> $status		// '',
			ipv4		=> $first_ip	// '',
			ipv4_all	=> $ipv4		// '',
			gateway		=> $gw			// '', };
		display($dbg_net+1, 1, "nic $rec->{alias} $rec->{status} ip($rec->{ipv4_all}) gw($rec->{gateway})");
		push @adapters, $rec;
	}
	display($dbg_net, 0, "probe_network: ".scalar(@adapters)." adapters, elevated=$elev");
	return (\@adapters, $elev);
}

sub is_apipa  { my ($ip)  = @_; return ($ip  && $ip  =~ /^169\.254\./) ? 1 : 0; }

sub on_seatalk
	# does this NIC have a 10.x address (i.e. can it reach the plotter)?
{
	my ($nic) = @_;
	return ($nic && $nic->{ipv4_all} && $nic->{ipv4_all} =~ /(^|,)\s*10\./) ? 1 : 0;
}

sub has_ip
{
	my ($nic, $ip) = @_;
	return ($nic && $nic->{ipv4_all} && $nic->{ipv4_all} =~ /(^|,)\s*\Q$ip\E\s*(,|$)/) ? 1 : 0;
}

sub up_nics
	# the NICs we can listen on: Up and with some IPv4 (APIPA included --
	# a link-local listener still hears the plotter's IDENT)
{
	my ($adapters) = @_;
	return grep { $_->{status} =~ /up/i && $_->{ipv4} ne '' } @$adapters;
}


#------------------------------------------
# RAYDP search on ALL up NICs at once
#------------------------------------------

sub parse_ident
	# mirrors c_RAYDP::parsePacket IDENT branch; returns a device hash or undef
{
	my ($raw) = @_;
	return undef if length($raw) < 24;
	return undef if unpack('v', substr($raw, 0, 2)) != 1;		# 1 == CMD_IDENT

	my $type_n	= unpack('V', substr($raw, 4, 4));
	my $id_hex	= unpack('H*', substr($raw, 8, 4));
	my $version	= unpack('V', substr($raw, 12, 4)) / 100;
	my $ip		= inet_ntoa(pack('N', unpack('V', substr($raw, 16, 4))));

	my $is_master = length($raw) == 56 ? unpack('v', substr($raw, 54, 2)) : -1;
	my $role =
		$is_master == -1 ? 'UNKNOWN' :
		$is_master       ? 'MASTER'  : 'SLAVE';

	return {
		id_hex	=> $id_hex,
		name	=> $KNOWN_DEVICES{$id_hex} || $id_hex,
		type	=> $DEVICE_TYPE{$type_n}  || "$type_n=unknown",
		version	=> $version,
		ip		=> $ip,
		role	=> $role, };
}

sub search_open_all
	# opens a RAYDP listener per up-NIC (explicit-interface join = the proven
	# spike idiom).  returns an arrayref of { alias, ip, sock, nic }.
{
	my ($nics) = @_;
	my @socks;
	for my $nic (@$nics)
	{
		my $ip = $nic->{ipv4};
		my $sock = IO::Socket::Multicast->new(
			LocalHost	=> $ip,
			LocalPort	=> $RAYDP_PORT,
			Proto		=> 'udp',
			ReuseAddr	=> 1 );
		if (!$sock)
		{
			display($dbg_search, 1, "skip $nic->{alias} ($ip): $!");
			next;
		}
		if (!$sock->mcast_add($RAYDP_IP, $ip))
		{
			display($dbg_search, 1, "join failed on $ip: $!");
			$sock->close();
			next;
		}
		display($dbg_search, 0, "listening on $nic->{alias} ($ip)");
		push @socks, { alias => $nic->{alias}, ip => $ip, sock => $sock, nic => $nic };
	}
	search_wake_all(\@socks, 10);
	return \@socks;
}

sub search_wake_all
	# resend wakeup packets to keep the inbound-multicast pinhole alive
{
	my ($socks, $count) = @_;
	return if !$socks;
	$count ||= 3;
	for my $s (@$socks)
	{
		$s->{sock}->send($RAYDP_WAKEUP_PACKET, 0, $RAYDP_ADDR) for (1 .. $count);
	}
}

sub search_poll_all
	# NON-BLOCKING: drains all listeners, adds new E80s to $devs (by id_hex,
	# each tagged with the NIC that heard it), filters self.  Returns NEW count.
{
	my ($socks, $devs) = @_;
	return 0 if !$socks;
	my $new = 0;
	for my $s (@$socks)
	{
		my $sel = IO::Select->new($s->{sock});
		while ($sel->can_read(0))
		{
			my $raw;
			my $peer = recv($s->{sock}, $raw, 4096, 0);
			last if !defined $peer;
			my $d = parse_ident($raw);
			next if !$d;
			next if $d->{id_hex} eq $SHARK_DEVICE_ID;	# our own shark identity
			next if $d->{id_hex} eq 'ffffffff';			# RNS (PC software) identity
			next if $devs->{$d->{id_hex}};
			$d->{nic} = $s->{nic};						# which adapter heard it
			$devs->{$d->{id_hex}} = $d;
			$new++;
			display($dbg_search, 1, "heard $d->{name} [$d->{id_hex}] ip($d->{ip}) on $s->{alias}");
		}
	}
	return $new;
}

sub search_close_all
{
	my ($socks) = @_;
	return if !$socks;
	for my $s (@$socks) { $s->{sock}->close() if $s->{sock}; }
}


#------------------------------------------
# netsh: set static (replace) / back to DHCP -- the standard single-address model
#------------------------------------------

sub address_cmd
	# set the adapter to a static IP -- this REPLACES its current IPv4 config,
	# exactly like the standard Windows "Use the following IP address" choice
{
	my ($nic, $ip, $mask) = @_;
	return qq{netsh interface ipv4 set address name="$nic->{alias}" static $ip $mask};
}

sub revert_cmd
	# back to Automatic (DHCP) -- the natural undo of the above
{
	my ($nic) = @_;
	return qq{netsh interface ipv4 set address name="$nic->{alias}" source=dhcp};
}

sub _run_netsh
{
	my ($cmd) = @_;
	display($dbg_net, 0, "running: $cmd");
	system($cmd);
	my $rc = $? >> 8;
	if ($rc)
	{
		error("netsh failed (exit $rc) -- run the wizard elevated (Administrator).");
		return 0;
	}
	return 1;
}

sub apply_address  { my ($nic, $ip, $mask) = @_; return _run_netsh(address_cmd($nic, $ip, $mask)); }
sub revert_address { my ($nic)             = @_; return _run_netsh(revert_cmd($nic)); }

1;
