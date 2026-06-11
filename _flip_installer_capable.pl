use strict;
use warnings;
use Storable qw(retrieve nstore store);
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent   = 1;

my $f   = 'C:/base_dist/navMate/cava20/msw/installer.config';
my $bak = 'C:/base_data/temp/raymarine/installer.config.navMate.bak';

die "missing $f\n" if !-e $f;

# 1. backup raw bytes (idempotent)
if (!-e $bak) {
    open(my $in, '<:raw', $f) or die "read $f: $!";
    local $/; my $raw = <$in>; close $in;
    open(my $out, '>:raw', $bak) or die "write $bak: $!";
    print $out $raw; close $out;
    print "backup -> $bak (".length($raw)." bytes)\n";
} else {
    print "backup exists -> $bak (kept)\n";
}

# 2. detect original byte order so we re-serialize in the same format
my $netorder = 0;
if (Storable->can('file_magic')) {
    my $m = Storable::file_magic($f);
    $netorder = ($m && $m->{netorder}) ? 1 : 0;
}
print "original netorder=$netorder\n";

# 3. retrieve + show before
my $h = retrieve($f) or die "retrieve failed\n";
printf "before: doinstaller=%s installer_capable=%s\n",
    (defined $h->{doinstaller}       ? $h->{doinstaller}       : 'undef'),
    (defined $h->{installer_capable} ? $h->{installer_capable} : 'undef');

# 4. flip exactly the two flags
$h->{doinstaller}       = 1;
$h->{installer_capable} = 1;

# 5. write back preserving the original format
if ($netorder) { nstore($h, $f) or die "nstore failed\n"; }
else           { store($h, $f)  or die "store failed\n"; }
print "wrote $f (".($netorder ? 'nstore' : 'store').")\n";

# 6. verify by re-reading
my $v = retrieve($f) or die "verify retrieve failed\n";
printf "after:  doinstaller=%s installer_capable=%s\n",
    $v->{doinstaller}, $v->{installer_capable};
print "full verify:\n", Dumper($v);
