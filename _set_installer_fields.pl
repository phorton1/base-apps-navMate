use strict;
use warnings;
use Storable qw(retrieve nstore store);

my $f   = 'C:/base_dist/navMate/cava20/msw/installer.config';
my $bak = 'C:/base_data/temp/raymarine/installer.config.navMate.bak3';

die "missing $f\n" if !-e $f;

# backup (idempotent)
if (!-e $bak) {
    open(my $in, '<:raw', $f) or die "read $f: $!";
    local $/; my $raw = <$in>; close $in;
    open(my $out, '>:raw', $bak) or die "write $bak: $!";
    print $out $raw; close $out;
    print "backup -> $bak (".length($raw)." bytes)\n";
} else {
    print "backup exists (kept): $bak\n";
}

# preserve the original byte order
my $netorder = 0;
if (Storable->can('file_magic')) {
    my $m = Storable::file_magic($f);
    $netorder = ($m && $m->{netorder}) ? 1 : 0;
}
print "netorder=$netorder\n";

my $h = retrieve($f) or die "retrieve failed\n";
printf "before: require_privileges=%s  program_group='%s'\n",
    (defined $h->{require_privileges} ? $h->{require_privileges} : 'undef'),
    (defined $h->{program_group}      ? $h->{program_group}      : 'undef');

$h->{require_privileges} = 1;
$h->{program_group}      = 'navMate';

if ($netorder) { nstore($h, $f) or die "nstore failed\n"; }
else           { store($h, $f)  or die "store failed\n"; }

my $v = retrieve($f) or die "verify failed\n";
printf "after:  require_privileges=%s  program_group='%s'\n",
    $v->{require_privileges}, $v->{program_group};
printf "        (unchanged) name='%s'  toplevel_folder='%s'  doinstaller=%s\n",
    $v->{name}, $v->{toplevel_folder}, $v->{doinstaller};
printf "        (unchanged) pre_installer_script='%s'\n", $v->{pre_installer_script};
