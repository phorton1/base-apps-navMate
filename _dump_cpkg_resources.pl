use strict;
use warnings;
use DBI;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent   = 1;

for my $proj (qw(buddy navMate)) {
    my $db = "C:/base_dist/$proj/cava20.cpkgproj";
    print "################ $proj ($db) ################\n";
    if (!-e $db) { print " missing\n\n"; next; }
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db", "", "",
        { RaiseError => 1, sqlite_open_flags => 1 });   # 1 = SQLITE_OPEN_READONLY
    my $tables = $dbh->selectcol_arrayref(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
    print "tables: @$tables\n\n";
    for my $tbl (qw(config_values user_folder local_path additional_binary)) {
        next if !grep { $_ eq $tbl } @$tables;
        my $rows = $dbh->selectall_arrayref("SELECT * FROM $tbl", { Slice => {} });
        print "---- $tbl (".scalar(@$rows)." rows) ----\n";
        for my $r (@$rows) { print Dumper($r); }
        print "\n";
    }
    $dbh->disconnect;
    print "\n";
}
