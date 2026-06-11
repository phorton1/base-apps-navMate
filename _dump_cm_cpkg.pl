use strict;
use warnings;
use DBI;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent   = 1;

my $db = "C:/base_dist/cm/cava20.cpkgproj";
die "missing $db\n" if !-e $db;
my $dbh = DBI->connect("dbi:SQLite:dbname=$db", "", "",
    { RaiseError => 1, sqlite_open_flags => 1 });

# row count of every table
my $tables = $dbh->selectcol_arrayref(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
print "== table row counts ==\n";
for my $t (@$tables) {
    my ($n) = $dbh->selectrow_array("SELECT COUNT(*) FROM \"$t\"");
    printf "  %-22s %d\n", $t, $n;
}
print "\n";

# show user_folder schema (even if empty) + dump the file-ish tables
my ($uf_sql) = $dbh->selectrow_array(
    "SELECT sql FROM sqlite_master WHERE type='table' AND name='user_folder'");
print "== user_folder schema ==\n$uf_sql\n\n";

for my $tbl (qw(user_folder local_path additional_binary shared_library local_config_values)) {
    next if !grep { $_ eq $tbl } @$tables;
    my $rows = $dbh->selectall_arrayref("SELECT * FROM $tbl", { Slice => {} });
    print "---- $tbl (".scalar(@$rows)." rows) ----\n";
    for my $r (@$rows) { print Dumper($r); }
    print "\n";
}
$dbh->disconnect;
