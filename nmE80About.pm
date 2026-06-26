#!/usr/bin/perl
#-------------------------------------------------------------------------
# nmE80About.pm
#-------------------------------------------------------------------------
# "About E80" -- a modal dialog that lists the E80 units advertising on the
# network (RAYDP) and, for the selected unit, shows its full identity and
# firmware build stamp.
#
# Two tiers of information:
#
#   Tier 1 -- RAYDP (every unit, zero network round-trips): the discovery
#     records already in memory (machine label, firmware version, ip, role)
#     plus the implemented services THIS unit advertises.
#
#   Tier 2 -- SysInfo (modified firmware only, one diagnostics peek): the
#     unit's SysInfo singleton, read live over the mod001 peek channel
#     (UDP 6667).  A single 0x18c-byte peek at the fixed image address
#     0x016b55c4 returns the machine id, model, version code, build date,
#     build descriptor and build host.  See Pub::Ray e80_firmware
#     architecture/runtime.md ("The SysInfo singleton") and deployment/
#     mod001.md (the peek/poke/call wire protocol).  Stock units have no
#     diagnostics channel, so Tier 2 is unavailable on them -- the dialog
#     falls back to Tier 1 and says so.
#
# Peeks are LAZY (only the selected unit) and run on a detached worker
# thread so the wx loop never blocks; a Wx::Timer harvests the result and
# updates the detail pane.  The peek transaction mirrors e80Config.pm's
# proven _txn (that cleanroom library is sacrosanct, so its private peek is
# not reused; only the minimal one-shot read is replicated here).

package nmE80About;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Socket::INET;
use Socket qw(sockaddr_in inet_aton);
use Wx qw(:everything);
use Wx::Event qw(EVT_LISTBOX EVT_TIMER EVT_BUTTON EVT_CLOSE);
use Pub::Utils qw(display getAppFrame);
use Pub::WX::Dialogs;
use Pub::Ray::NET::c_RAYDP;
use nmE80DirectOps;
use base qw(Wx::Dialog);

my $dbg = 0;

# ---- mod001 diagnostic peek (mirrors e80Config.pm's wire constants) ----
my $DIAG_PORT  = 6667;          # mod001 diagnostic command port on the E80
my $REPLY_PORT = 9973;          # whitelisted local listener port (host firewall rule)
my $DIAG_MAGIC = 0xdddd0005;    # mod001 peek/poke/call command word
my $SUBOP_PEEK = 0;             # read memory -> hex reply

# ---- SysInfo singleton (architecture/runtime.md "The SysInfo singleton") ----
my $SYSINFO_ADDR = 0x016b55c4;  # fixed .bss address in the final-firmware image
my $SYSINFO_LEN  = 0x18c;       # a peek this long captures every field below
my $SI_MACHINE   = 0x50;        # uint32 LE   -- unit identity (machine id)
my $SI_MODEL     = 0x60;        # char[16]    -- model
my $SI_VERSION   = 0x88;        # uint16      -- version code (major*100 + minor)
my $SI_BDATE     = 0xdc;        # char[32]    -- build date
my $SI_BDESC     = 0xfc;        # char[32]    -- build descriptor
my $SI_BHOST     = 0x11c;       # char[16]    -- build host
my $SI_MIN_LEN   = 0x12c;       # last field end (BHOST + 16) -- shortest usable record

# ---- wx control ids (>= 200 per Pub::WX convention) ----
my $ID_LIST    = 200;
my $ID_REFRESH = 201;
my $ID_TIMER   = 202;

my $DLG_TITLE = 'About E80';

# Worker -> main-thread hand-off for the in-flight peek.  The worker writes scalar
# fields into $worker_result and sets {ready}; the Timer harvests it.  Only one peek
# is in flight at a time (the $worker_busy guard), so one slot suffices.
my $worker_result :shared = shared_clone({ ready => 0 });
my $worker_busy   :shared = 0;


#-------------------------------------------------------
# low-level SysInfo read (blocking -- call off the wx main thread)
#-------------------------------------------------------

sub readSysInfo
    # Read and decode the SysInfo singleton from the E80 at $ip over the mod001 peek
    # channel.  Returns a decoded hash on success, or { error => ... } if the unit does
    # not answer the diagnostics channel (e.g. stock firmware).  BLOCKS.
{
    my ($ip) = @_;
    return { error => 'no ip' } if !$ip;

    my $sock = IO::Socket::INET->new(
        LocalPort => $REPLY_PORT,
        Proto     => 'udp',
        Timeout   => 2 );
    return { error => "cannot bind UDP reply port $REPLY_PORT: $!" } if !$sock;

    my $hex = _peekHex($sock, $ip, $SYSINFO_ADDR, $SYSINFO_LEN);
    $sock->close();

    return { error => "no reply from $ip -- diagnostics channel unavailable "
                    . "(unit not running modified firmware?)" }
        if !defined($hex) || length($hex) != 2 * $SYSINFO_LEN;

    return _decodeSysInfo(pack('H*', $hex));
}


sub _peekHex
    # One mod001 PEEK transaction: request $nbytes at $addr, return the hex string of the
    # bytes read (or undef).  Mirrors e80Config::_txn's peek path -- drain stale datagrams,
    # send, then read several replies and accept the one whose length matches the request.
{
    my ($sock, $ip, $addr, $nbytes) = @_;

    my $want = 2 * $nbytes;
    my $pkt = pack('V', $DIAG_MAGIC)
            . pack('v', $REPLY_PORT)
            . pack('v', 0)
            . pack('C', $SUBOP_PEEK)
            . "\x00\x00\x00"
            . pack('V*', $addr, $nbytes, 0, 0, 0);
    my $dest = sockaddr_in($DIAG_PORT, inet_aton($ip));

    my $rin = '';
    vec($rin, fileno($sock), 1) = 1;
    for my $try (1 .. 5)
    {
        while (select(my $drain = $rin, undef, undef, 0.05))
        {
            my $junk;
            $sock->recv($junk, 4096);
        }
        $sock->send($pkt, 0, $dest) or return undef;
        for my $rd (1 .. 8)
        {
            last if !select(my $ready = $rin, undef, undef, 0.6);
            my $resp;
            $sock->recv($resp, 4096);
            my $payload = substr($resp, 10);        # 10-byte reply header precedes the hex
            next if !defined($payload) || $payload !~ /^[0-9a-fA-F]*$/ || length($payload) % 2;
            return $payload if length($payload) == $want;
        }
    }
    return undef;
}


sub _decodeSysInfo
    # Decode the raw SysInfo bytes per architecture/runtime.md's field table.
{
    my ($buf) = @_;
    return { error => 'short sysinfo record' } if length($buf) < $SI_MIN_LEN;

    my $machine = unpack('V', substr($buf, $SI_MACHINE, 4));
    my $vcode   = unpack('v', substr($buf, $SI_VERSION, 2));
    return {
        machine_id       => $machine,
        model            => _cstr(substr($buf, $SI_MODEL, 16)),
        version_code     => $vcode,
        version          => $vcode ? sprintf("%d.%02d", int($vcode / 100), $vcode % 100) : '',
        build_date       => _cstr(substr($buf, $SI_BDATE, 32)),
        build_descriptor => _cstr(substr($buf, $SI_BDESC, 32)),
        build_host       => _cstr(substr($buf, $SI_BHOST, 16)),
    };
}


sub _cstr
    # A NUL-terminated single-byte ASCII field -> a trimmed printable string.
{
    my ($raw) = @_;
    $raw =~ s/\x00.*$//s;            # stop at the first NUL
    $raw =~ s/[^\x20-\x7e]//g;       # printable ASCII only
    $raw =~ s/^\s+//;
    $raw =~ s/\s+$//;
    return $raw;
}


#-------------------------------------------------------
# unit enumeration (Tier 1, all in-memory)
#-------------------------------------------------------

sub _enumerateUnits
    # The live E80 units (by ip), each with its RAYDP discovery fields and the implemented
    # services it advertises.  Built from the authoritative FILESYS list (every E80 advertises
    # FILESYS), enriched from the RAYDP IDENT device records matched by ip.
{
    my @devs  = nmE80DirectOps::filesysDevices();       # ({ip, device_id}) sorted by ip
    my $raydp = Pub::Ray::NET::c_RAYDP::getRayDP();

    my %byip;
    if ($raydp)
    {
        my $recs = $raydp->{devices} || {};
        for my $d (values %$recs)
        {
            next if !$d || !$d->{ip};
            $byip{$d->{ip}} = $d;
        }
    }

    my @units;
    for my $dev (@devs)
    {
        my $ip  = $dev->{ip};
        my $rec = $byip{$ip};
        push(@units, {
            ip        => $ip,
            device_id => $dev->{device_id},
            label     => nmE80DirectOps::deviceLabel($ip, $dev->{device_id}),
            version   => $rec ? $rec->{version} : undef,
            role      => $rec ? $rec->{role}    : undef,
            services  => join(' ', _implementedServicesForIp($ip)),
        });
    }
    return @units;
}


sub _implementedServicesForIp
    # The names of the officially-implemented services (the RAYDP defs navMate marks
    # implemented) that the unit at $ip advertises -- deduped and sorted.  Per the
    # ports_by_addr records, filtered to this ip and {implemented}.
{
    my ($ip) = @_;
    my $raydp = Pub::Ray::NET::c_RAYDP::getRayDP();
    return () if !$raydp;
    my $ports = $raydp->getServicePortsByAddr();
    return () if !$ports;

    my %seen;
    for my $addr (keys %$ports)
    {
        my $sp = $ports->{$addr};
        next if !$sp || !$sp->{implemented};
        my $sip = $sp->{ip};
        $sip = $1 if !$sip && $addr =~ /^([^:]+):/;      # fall back to the addr's ip half
        next if !$sip || $sip ne $ip;
        $seen{$sp->{name}} = 1 if defined($sp->{name}) && $sp->{name} ne '';
    }
    return sort keys %seen;
}


#-------------------------------------------------------
# interactive entry (menu)
#-------------------------------------------------------

sub doAbout
    # Menu command: enumerate the units and show the modal dialog.
{
    my ($frame) = @_;
    $frame ||= getAppFrame();

    my @units = _enumerateUnits();
    if (!@units)
    {
        okDialog($frame, "No E80 is reachable on the network.", $DLG_TITLE);
        return;
    }

    my $dlg = nmE80About->new($frame, \@units);
    $dlg->ShowModal();
    $dlg->Destroy();
}


#-------------------------------------------------------
# the dialog
#-------------------------------------------------------

sub new
{
    my ($class, $frame, $units) = @_;
    my $this = $class->SUPER::new($frame, -1, $DLG_TITLE,
        wxDefaultPosition, [600, 480], wxDEFAULT_DIALOG_STYLE);

    $this->{units}      = $units;
    $this->{cache}      = {};           # ip -> { ok, ... } once peeked (main-thread only)
    $this->{current_ip} = undef;

    # reset the shared worker slot for this dialog instance
    {
        lock($worker_result);
        $worker_result->{ready} = 0;
    }
    {
        lock($worker_busy);
        $worker_busy = 0;
    }

    my $mono = Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);

    Wx::StaticText->new($this, -1,
        "E80 units on the network.  Select one to see its identity and firmware build.",
        [15, 10], [570, 18]);

    $this->{list} = Wx::ListBox->new($this, $ID_LIST,
        [15, 34], [570, 120], [], wxLB_SINGLE);
    $this->{list}->SetFont($mono);

    Wx::StaticText->new($this, -1, 'Details:', [15, 162], [570, 18]);

    $this->{detail} = Wx::TextCtrl->new($this, -1, '',
        [15, 182], [570, 228],
        wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
    $this->{detail}->SetFont($mono);

    Wx::Button->new($this, $ID_REFRESH, 'Refresh', [15, 420], [90, 28]);
    my $close = Wx::Button->new($this, wxID_CANCEL, 'Close', [495, 420], [90, 28]);
    $close->SetDefault();

    EVT_LISTBOX($this, $ID_LIST,     \&onSelect);
    EVT_BUTTON($this,  $ID_REFRESH,  \&onRefresh);
    EVT_BUTTON($this,  wxID_CANCEL,  \&onClose);
    EVT_CLOSE($this,                 \&onClose);

    $this->_populateList();
    $this->{list}->SetSelection(0);
    $this->{current_ip} = $units->[0]{ip};
    $this->_renderDetail();

    $this->{timer} = Wx::Timer->new($this, $ID_TIMER);
    EVT_TIMER($this, $ID_TIMER, \&onTimer);
    $this->{timer}->Start(250);

    return $this;
}


sub _rowText
    # One listbox line for a unit (Tier 1, plus the peek state in brackets).
{
    my ($this, $unit) = @_;
    my $ip = $unit->{ip};
    my $fw = !exists($this->{cache}{$ip}) ? '?'
           : $this->{cache}{$ip}{ok}      ? 'modified'
           :                                'stock';
    return sprintf("%-12s %-15s  v%-6s %-9s [%s]",
        substr($unit->{label}, 0, 12),
        $ip,
        (defined($unit->{version}) ? $unit->{version} : '?'),
        ($unit->{role} // '?'),
        $fw);
}


sub _populateList
{
    my ($this) = @_;
    $this->{list}->Clear();
    $this->{list}->Append($this->_rowText($_)) for @{$this->{units}};
}


sub _updateRowFirmware
    # Repaint just the row for $ip (its bracketed peek state changed).
{
    my ($this, $ip) = @_;
    for my $i (0 .. $#{$this->{units}})
    {
        next if $this->{units}[$i]{ip} ne $ip;
        $this->{list}->SetString($i, $this->_rowText($this->{units}[$i]));
        last;
    }
}


sub _renderDetail
    # Render the detail pane for the currently-selected unit: Tier 1 always, Tier 2 from
    # the cache (or "reading..." while a peek is in flight, or the failure reason on stock).
{
    my ($this) = @_;
    my $ip = $this->{current_ip};
    return if !defined($ip);
    my ($unit) = grep { $_->{ip} eq $ip } @{$this->{units}};
    return if !$unit;

    my $t = sprintf("%s   (%s)\n\n", $unit->{label}, $ip);

    $t .= "RAYDP (network discovery)\n";
    $t .= sprintf("  %-14s %s\n", 'machine',    $unit->{label});
    $t .= sprintf("  %-14s %s\n", 'firmware',   defined($unit->{version}) ? $unit->{version} : '?');
    $t .= sprintf("  %-14s %s\n", 'ip address', $ip);
    $t .= sprintf("  %-14s %s\n", 'role',       $unit->{role} // '?');
    $t .= sprintf("  %-14s %s\n", 'services',   $unit->{services} ne '' ? $unit->{services} : '(none)');
    $t .= "\n";

    $t .= "System Info (mod001 diagnostics)\n";
    my $c = $this->{cache}{$ip};
    if (!$c)
    {
        $t .= "  reading from $ip ...\n";
    }
    elsif (!$c->{ok})
    {
        $t .= "  unavailable -- " . ($c->{error} // 'no response') . "\n";
        $t .= "  (build details require the modified firmware's diagnostics channel)\n";
    }
    else
    {
        my $m = $c->{machine_id};
        $t .= sprintf("  %-14s 0x%08X   (marker 0x%02X, unit 0x%06X)\n",
            'machine id', $m, ($m >> 24) & 0xff, $m & 0xffffff);
        $t .= sprintf("  %-14s %s\n", 'model', $c->{model} ne '' ? $c->{model} : '(blank)');

        my $vnote = '';
        if (defined($unit->{version}) && $c->{version} ne '')
        {
            $vnote = (abs($unit->{version} - $c->{version}) < 0.005)
                ? '   (matches RAYDP)'
                : "   (RAYDP reports $unit->{version})";
        }
        $t .= sprintf("  %-14s %s%s\n", 'version',    $c->{version} ne '' ? $c->{version} : '?', $vnote);
        $t .= sprintf("  %-14s %s\n",   'build date', $c->{build_date} ne '' ? $c->{build_date} : '(blank)');
        $t .= sprintf("  %-14s %s\n",   'build host', $c->{build_host} ne '' ? $c->{build_host} : '(blank)');
        $t .= sprintf("  %-14s %s\n",   'build info', $c->{build_descriptor} ne '' ? $c->{build_descriptor} : '(blank)');
    }

    $this->{detail}->SetValue($t);
}


sub onSelect
    # A listbox row was selected: switch the detail pane.  The peek (if needed) is launched
    # by the Timer, which keeps thread bookkeeping in one place.
{
    my ($this, $event) = @_;
    my $sel = $this->{list}->GetSelection();
    return if $sel < 0;
    $this->{current_ip} = $this->{units}[$sel]{ip};
    $this->_renderDetail();
}


sub onTimer
    # Harvest a finished peek into the cache and repaint; then, if the selected unit is not
    # yet peeked and no peek is running, launch one.
{
    my ($this) = @_;

    my $done;
    {
        lock($worker_result);
        if ($worker_result->{ready})
        {
            $done = { map { $_ => $worker_result->{$_} } keys %$worker_result };
            $worker_result->{ready} = 0;
        }
    }

    if ($done)
    {
        my $ip = $done->{ip};
        if (defined($ip))
        {
            $this->{cache}{$ip} = $done->{ok}
                ? { ok => 1, map { $_ => $done->{$_} }
                        qw(machine_id model version version_code build_date build_descriptor build_host) }
                : { ok => 0, error => $done->{error} };
            $this->_updateRowFirmware($ip);
            $this->_renderDetail() if ($this->{current_ip} // '') eq $ip;
        }
    }

    my $ip = $this->{current_ip};
    if (defined($ip) && !exists($this->{cache}{$ip}))
    {
        my $busy;
        {
            lock($worker_busy);
            $busy = $worker_busy;
        }
        _spawnPeek($ip) if !$busy;
    }
}


sub _spawnPeek
    # Launch the detached worker that reads SysInfo for $ip, writing the outcome into the
    # shared $worker_result slot for the Timer to harvest.
{
    my ($ip) = @_;

    {
        lock($worker_busy);
        return if $worker_busy;
        $worker_busy = 1;
    }
    {
        lock($worker_result);
        $worker_result->{ready} = 0;
        $worker_result->{ip}    = $ip;
    }

    display($dbg, 0, "nmE80About: peeking SysInfo on $ip");

    threads->create(sub {
        my $info = readSysInfo($ip);
        {
            lock($worker_result);
            $worker_result->{ip} = $ip;
            if (ref($info) eq 'HASH' && !$info->{error})
            {
                $worker_result->{ok} = 1;
                $worker_result->{$_} = $info->{$_}
                    for qw(machine_id model version version_code build_date build_descriptor build_host);
            }
            else
            {
                $worker_result->{ok}    = 0;
                $worker_result->{error} = (ref($info) eq 'HASH' ? $info->{error} : undef) // 'no response';
            }
            $worker_result->{ready} = 1;
        }
        {
            lock($worker_busy);
            $worker_busy = 0;
        }
    })->detach();
}


sub onRefresh
    # Re-enumerate the RAYDP units and re-peek (clears the cache).
{
    my ($this) = @_;
    my @units = _enumerateUnits();
    my $keep  = $this->{current_ip};

    $this->{units} = \@units;
    $this->{cache} = {};
    $this->_populateList();

    if (!@units)
    {
        $this->{current_ip} = undef;
        $this->{detail}->SetValue("No E80 is reachable on the network.\n");
        return;
    }

    my $sel = 0;
    for my $i (0 .. $#units)
    {
        if (defined($keep) && $units[$i]{ip} eq $keep)
        {
            $sel = $i;
            last;
        }
    }
    $this->{list}->SetSelection($sel);
    $this->{current_ip} = $units[$sel]{ip};
    $this->_renderDetail();
}


sub onClose
    # Stop the timer and end the modal loop.  A peek still in flight (detached) simply
    # finishes into the shared slot with nobody harvesting -- harmless.
{
    my ($this, $event) = @_;
    $this->{timer}->Stop() if $this->{timer};
    $this->EndModal(wxID_OK);
}


1;
