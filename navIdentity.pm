#---------------------------------------------
# navIdentity.pm
#---------------------------------------------
# Shared identity layer for the OpenCPN (oESeries) spoke.  Promoted out of
# navGPX.pm so the GPX spoke, navOCPN / nmOCPNDirectOps, and the DB layer all
# use ONE codec (protocol.md sec 4).
#
# navMate uuid (16 lower-hex chars = 8 bytes / 64 bits)  <->  OpenCPN GUID
# (128 bits, 36-char hyphenated 8-4-4-4-12).
#
#   - navMate-ORIGIN objects synthesize a reversible RFC-4122-v4-shaped GUID
#     that embeds the 64-bit uuid plus a "navMate" MAGIC tag, routed AROUND the
#     fixed version (byte 6 high nibble) and variant (byte 8 top 2 bits) so it
#     survives byte-for-byte AND reverses with ZERO storage.
#   - FOREIGN (OpenCPN-born) GUIDs are opaque 128-bit randoms; they reverse ONLY
#     via a persisted map (the DB ocpn_guid_map, or an in-memory map in the ocdb
#     for the harness), minting a 0x4f-tagged uuid on first sight.
#
# Provenance byte (uuid byte 1): 0x4e navMate, 0x46 FSH, 0x4f OpenCPN.

package navIdentity;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
	navUuidToOcpnGuid
	ocpnGuidToNavUuid
	makeOCPNUUID
	reconcileGuidToUuid
	projectUuidToGuid
);

my $NM_GUID_MAGIC = '6e61764d617465';   # ascii "navMate"


#-----------------------------------------------------------------------
# the reversible navMate-origin codec (verbatim from navGPX.pm:40-85)
#-----------------------------------------------------------------------
#   G1(8) = uuid[0:8]
#   G2(4) = MAGIC[0:4]
#   G3(4) = '4' . MAGIC[4:7]     (version 4)
#   G4(4) = '8' . MAGIC[7:10]    (variant 10xx)
#   G5(12)= uuid[8:16] . MAGIC[10:14]

sub navUuidToOcpnGuid
{
	my ($u) = @_;
	return undef if !defined $u || $u !~ /^[0-9a-fA-F]{16}$/;
	$u = lc $u;
	my $m = $NM_GUID_MAGIC;
	return substr($u,0,8) . '-'
		. substr($m,0,4) . '-'
		. '4' . substr($m,4,3) . '-'
		. '8' . substr($m,7,3) . '-'
		. substr($u,8,8) . substr($m,10,4);
}

sub ocpnGuidToNavUuid
{
	my ($g) = @_;
	return undef if !defined $g;
	$g = lc $g;
	return undef if $g !~ /^([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})$/;
	my ($g1,$g2,$g3,$g4,$g5) = ($1,$2,$3,$4,$5);
	my $m = $NM_GUID_MAGIC;
	return undef unless $g2          eq substr($m,0,4);
	return undef unless substr($g3,1,3) eq substr($m,4,3);
	return undef unless substr($g4,1,3) eq substr($m,7,3);
	return undef unless substr($g5,8,4) eq substr($m,10,4);
	return $g1 . substr($g5,0,8);
}


#-----------------------------------------------------------------------
# makeOCPNUUID -- mint a 0x4f-tagged uuid for a foreign OpenCPN object
#-----------------------------------------------------------------------
# Mirrors n_utils::makeUUID (0x4e) / makeFSHUUID (0x46): byte 1 = 0x4f ('O'),
# bytes 4-5 = little-endian counter, remaining bytes random.

sub makeOCPNUUID
{
	my ($counter) = @_;
	return sprintf("%02x4f%04x%s%04x",
		int(rand(256)),
		int(rand(65536)),
		unpack('H*', pack('v', $counter)),
		int(rand(65536)));
}


#-----------------------------------------------------------------------
# reconcileGuidToUuid($guid, $map) -- wire GUID -> navMate uuid
#-----------------------------------------------------------------------
# $map is a plain in-memory reconciliation map (the harness/ocdb form of the
# DB ocpn_guid_map):
#     { fwd => { <foreign guid> => <uuid> },
#       rev => { <uuid> => <foreign guid> },
#       counter => <int> }
# navMate-origin GUIDs reverse table-free via the codec (and are recorded in
# rev so projection can re-emit the exact same guid).  A foreign GUID reuses its
# existing mapping, or mints a fresh 0x4f uuid on first sight -- idempotent, so
# re-enumerating the same inventory never duplicates.

sub reconcileGuidToUuid
{
	my ($guid, $map) = @_;
	return undef if !defined $guid;
	$map->{fwd}     ||= {};
	$map->{rev}     ||= {};
	$map->{counter} ||= 0;

	my $native = ocpnGuidToNavUuid($guid);
	if (defined $native)
	{
		$map->{rev}{$native} = $guid;
		return $native;
	}
	return $map->{fwd}{$guid} if exists $map->{fwd}{$guid};

	my $uuid = makeOCPNUUID(++$map->{counter});
	$map->{fwd}{$guid} = $uuid;
	$map->{rev}{$uuid} = $guid;
	return $uuid;
}


#-----------------------------------------------------------------------
# projectUuidToGuid($uuid, $map) -- navMate uuid -> wire GUID
#-----------------------------------------------------------------------
# The inverse of reconcile, for OUTBOUND projection.  A foreign-origin uuid
# (0x4f, born from an OpenCPN GUID we mapped) MUST re-emit its original opaque
# guid from the rev map -- NOT a synthesized navMate-magic guid.  A navMate/FSH
# uuid synthesizes its reversible guid via the codec.

sub projectUuidToGuid
{
	my ($uuid, $map) = @_;
	return undef if !defined $uuid;
	return $map->{rev}{$uuid} if $map && $map->{rev} && exists $map->{rev}{$uuid};
	return navUuidToOcpnGuid($uuid);
}


1;
