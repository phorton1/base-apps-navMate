use strict;
use warnings;
use DBI;
use File::Copy;

my $proj = 'C:/base_dist/navMate/cava20.cpkgproj';
my $bak  = 'C:/base_data/temp/raymarine/navMate_cpkgproj_preedit.sqlite';

copy($proj, $bak) or die "backup failed: $!";
print "backup copy -> $bak\n\n";

my $dbh = DBI->connect("dbi:SQLite:dbname=$proj", "", "",
    { RaiseError => 1, PrintError => 0, AutoCommit => 0 });

sub snap {
    my ($label) = @_;
    print "===== $label =====\n";
    for my $cn (qw(appfolder copyright)) {
        my ($v) = $dbh->selectrow_array(
            "SELECT config_value FROM config_values WHERE config_name=?", undef, $cn);
        print "  config_values.$cn = '" . (defined $v ? $v : '<null>') . "'\n";
    }
    my ($ep) = $dbh->selectrow_array(
        "SELECT config_value FROM local_config_values WHERE config_name='extrapaths'");
    print "  local_config_values.extrapaths = '" . (defined $ep ? $ep : '<null>') . "'\n";
    my $im = $dbh->selectall_arrayref(
        "SELECT module_key, module_name FROM include_module ORDER BY module_name");
    print "  include_module (" . scalar(@$im) . " rows):\n";
    print "    $_->[1]  ($_->[0])\n" for @$im;
}

snap("BEFORE");

print "\n--- applying 7 statements (single transaction) ---\n";
$dbh->do("UPDATE config_values SET config_value='navMate' WHERE config_name='appfolder'");
$dbh->do("UPDATE config_values SET config_value='Copyright (C) 2026 Patrick Horton' WHERE config_name='copyright'");
$dbh->do("UPDATE local_config_values SET config_value='C:/base' WHERE config_name='extrapaths'");
my $ins = $dbh->prepare("INSERT OR IGNORE INTO include_module (module_key, module_name) VALUES (?,?)");
$ins->execute(@$_) for (
    ['DBD/SQLite.pm',     'DBD::SQLite'],
    ['JSON/PP.pm',        'JSON::PP'],
    ['threads.pm',        'threads'],
    ['threads/shared.pm', 'threads::shared'],
);
$dbh->commit;
print "committed.\n\n";

snap("AFTER");
$dbh->disconnect;
print "\nDONE.\n";
