use strict;
use warnings;
use File::Copy;
use DBI;

my $src = $ARGV[0] || 'C:/base_dist/buddy/cava20.cpkgproj';
my $tmp = 'C:/_temp/base-apps-navMate/_cpkg_copy.sqlite';

copy($src, $tmp) or die "copy '$src' failed: $!";

my $dbh = DBI->connect("dbi:SQLite:dbname=$tmp", "", "", { RaiseError => 1, PrintError => 0 });

print "SOURCE: $src\n\n";

my $tables = $dbh->selectall_arrayref(
    "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name");

for my $t (@$tables) {
    my ($name, $sql) = @$t;
    my ($cnt) = $dbh->selectrow_array("SELECT COUNT(*) FROM \"$name\"");
    print "==== TABLE $name  ($cnt rows) ====\n";
    (my $oneline = $sql) =~ s/\s+/ /g;
    print "  SCHEMA: $oneline\n";
    if ($cnt > 0 && $cnt <= 60) {
        my $rows = $dbh->selectall_arrayref("SELECT * FROM \"$name\"", { Slice => {} });
        my $i = 0;
        for my $r (@$rows) {
            my @kv;
            for my $k (sort keys %$r) {
                my $v = $r->{$k};
                $v = '<null>' if !defined $v;
                $v =~ s/[\r\n\t]+/ /g;
                $v = substr($v, 0, 70) . '...(' . length($r->{$k} // '') . ')' if length($v) > 70;
                push @kv, "$k=$v";
            }
            printf "  [%02d] %s\n", $i++, join('  |  ', @kv);
        }
    } elsif ($cnt > 60) {
        print "  (",$cnt," rows -- likely a file/dependency list; not dumped)\n";
    }
    print "\n";
}
$dbh->disconnect;
unlink $tmp;
