use strict;
use warnings;
use DBI;
use File::Copy;

my $db  = "C:/base_dist/navMate/cava20.cpkgproj";
my $bak = "C:/base_data/temp/raymarine/cava20.cpkgproj.bak";
copy($db, $bak) or warn "backup failed: $!";
print -e $bak ? "backup -> $bak\n" : "NO BACKUP\n";

my $res = 'C:/base/apps/raymarine/apps/navMate/_res';
my $rslt = eval {
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db", "", "", { RaiseError => 1 });
    my $n = $dbh->do(
        "UPDATE local_config_values SET config_value=? WHERE config_name='resource_path'",
        undef, $res);
    my $chk = $dbh->selectrow_arrayref(
        "SELECT config_value FROM local_config_values WHERE config_name='resource_path'");
    $dbh->disconnect;
    "resource_path updated ($n row); now = '$chk->[0]'";
};
print $@ ? "UPDATE FAILED: $@(is Cava open? the .cpkgproj would be locked)\n" : "$rslt\n";

# reference: how do buddy/cm carry their exe icon?
for my $proj (qw(buddy cm)) {
    my $p = "C:/base_dist/$proj/cava20.cpkgproj";
    next if !-e $p;
    my $d = DBI->connect("dbi:SQLite:dbname=$p", "", "", { RaiseError => 1, sqlite_open_flags => 1 });
    my $e = $d->selectall_arrayref("SELECT exec_name, icon_bundle FROM executable", { Slice => {} });
    my $a = $d->selectall_arrayref("SELECT config_value FROM config_values WHERE config_name='appinfo_iconfile'", { Slice => {} });
    print "=== $proj === icon_bundle: " . join(", ", map { "$_->{exec_name}=[$_->{icon_bundle}]" } @$e) . "\n";
    print "    appinfo_iconfile: [" . ($a->[0]{config_value} // '') . "]\n";
    $d->disconnect;
}
