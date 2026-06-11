use strict;
use warnings;
use DBI;
use File::Copy;

my $proj = 'C:/base_dist/navMate/cava20.cpkgproj';
my $bak  = 'C:/base_data/temp/raymarine/navMate_cpkgproj_preedit2.sqlite';

copy($proj, $bak) or die "backup failed: $!";
print "backup copy -> $bak\n\n";

my $dbh = DBI->connect("dbi:SQLite:dbname=$proj", "", "",
    { RaiseError => 1, PrintError => 0, AutoCommit => 0 });

sub snap {
    my ($label) = @_;
    print "===== $label =====\n";
    my ($cm) = $dbh->selectrow_array("SELECT config_value FROM config_values WHERE config_name='codemask'");
    print "  config_values.codemask = '" . (defined $cm ? $cm : '<null>') . "'\n";
    my $sc = $dbh->selectall_arrayref("SELECT script_key, codemask FROM script");
    print "  script.$_->[0].codemask = $_->[1]\n" for @$sc;
    my ($ep) = $dbh->selectrow_array("SELECT config_value FROM local_config_values WHERE config_name='extrapaths'");
    print "  local.extrapaths = '" . (defined $ep ? $ep : '<null>') . "'\n";
}

snap("BEFORE");

print "\n--- applying (single transaction) ---\n";
$dbh->do("UPDATE config_values SET config_value='1' WHERE config_name='codemask'");
$dbh->do("UPDATE script SET codemask=1");
$dbh->do("UPDATE local_config_values SET config_value='C:/base;C:/base/apps/raymarine/apps/navMate' WHERE config_name='extrapaths'");
$dbh->commit;
print "committed.\n\n";

snap("AFTER");
$dbh->disconnect;
print "\nDONE.\n";
