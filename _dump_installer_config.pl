use strict;
use warnings;
use Storable qw(retrieve);
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent   = 1;

for my $proj (qw(navMate buddy cm)) {
    my @files = glob("C:/base_dist/$proj/cava*/msw/installer.config");
    print "================ $proj ================\n";
    if (!@files) { print "  (no installer.config found)\n\n"; next; }
    for my $f (@files) {
        print "---- $f ----\n";
        my $h = eval { retrieve($f) };
        if ($@ || !defined $h) { print "  retrieve failed: ".($@||'undef')."\n\n"; next; }
        print Dumper($h);
        print "\n";
    }
}
