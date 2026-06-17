#!/usr/bin/perl
#-------------------------------------------------------------------
# _e80ScreenGrab.pl   <ip>  <outfile>
#
# Capture the E80 screen at <ip> and write it as a true-color PNG to <outfile>.
# Thin CLI wrapper around the cleanroom e80ScreenGrab library (mod002 FAST path:
# one atomic on-device snapshot streamed over TCP/6668, composited on the host).
# READ-ONLY -- it never writes to or reboots the unit.
#
#   <ip>       E80 address (e.g. 10.0.240.83 for E80-2). The unit MUST be running
#              a mod002 build (the TCP/6668 grab service); a stock unit will refuse
#              the connection or never reply.
#   <outfile>  PNG path, absolute OR relative to the current dir ('.png' is appended
#              if absent). Missing parent directories are created. e.g.
#              ../temp/screen.png
#
# For a unit WITHOUT mod002, use the legacy mod001 peek-based grabber
# scripts/_oldE80GrabScreen.pl (slower, tear-prone, but needs no firmware mod).
#
#   /c/Perl/bin/perl.exe _e80ScreenGrab.pl 10.0.240.83 ../temp/screen.png
#-------------------------------------------------------------------
use strict;
use warnings;
use lib 'C:/base';                       # Pub::Utils (the library depends on it)
use FindBin;
use lib $FindBin::Bin;                    # the co-located e80ScreenGrab library
use e80ScreenGrab;                        # exports grabE80Screen()

$| = 1;                                   # autoflush so the library's progress shows live

@ARGV == 2
    or die "usage: _e80ScreenGrab.pl <ip> <outfile.png>\n"
         . "   e.g. perl _e80ScreenGrab.pl 10.0.240.83 ../temp/screen.png\n";

my ($ip, $out) = @ARGV;

my $ok = grabE80Screen($ip, $out);        # logs "wrote <path>" on success, error() on failure
exit($ok ? 0 : 1);
