use strict;
use warnings;
use Storable qw(retrieve nstore store);

my $f   = 'C:/base_dist/navMate/cava20/msw/installer.config';
my $bak = 'C:/base_data/temp/raymarine/installer.config.navMate.bak2';
my $pre = 'C:/base/apps/raymarine/apps/navMate/_installer/PreInstallApp.pm';

die "missing $f\n"            if !-e $f;
die "PreInstallApp missing: $pre\n" if !-e $pre;

# backup (idempotent)
if (!-e $bak) {
    open(my $in, '<:raw', $f) or die "read $f: $!";
    local $/; my $raw = <$in>; close $in;
    open(my $out, '>:raw', $bak) or die "write $bak: $!";
    print $out $raw; close $out;
    print "backup -> $bak (".length($raw)." bytes)\n";
} else {
    print "backup exists (kept)\n";
}

# preserve the original byte order
my $netorder = 0;
if (Storable->can('file_magic')) {
    my $m = Storable::file_magic($f);
    $netorder = ($m && $m->{netorder}) ? 1 : 0;
}
print "netorder=$netorder\n";

my $h = retrieve($f) or die "retrieve failed\n";
printf "before: pre_installer_script = '%s'\n", (defined $h->{pre_installer_script} ? $h->{pre_installer_script} : 'undef');

$h->{pre_installer_script} = $pre;

if ($netorder) { nstore($h, $f) or die "nstore failed\n"; }
else           { store($h, $f)  or die "store failed\n"; }

my $v = retrieve($f) or die "verify failed\n";
printf "after:  pre_installer_script = '%s'\n", $v->{pre_installer_script};
printf "        doinstaller=%s installer_capable=%s\n", $v->{doinstaller}, $v->{installer_capable};
