#!/usr/bin/perl
# Exercise the API 800 (r6p0) compatibility of mali.ko through /dev/mali.
use strict;
use warnings;
use Errno;

my $V800 = (800 << 16) | 800;
my $V900 = (900 << 16) | 900;
my $GET_API_V2   = 0xC0108203;             # _IOWR(0x82, 3, 16)
my $ALLOC_R6P0   = 0xC0208300;             # _IOWR(0x83, 0, 32)
my $ALLOC_900    = 0xC0288300;             # _IOWR(0x83, 0, 40)
my $FREE         = 0xC0108301;             # _IOWR(0x83, 1, 16)
my $GP_R6P0      = 0xC0708500;             # _IOWR(0x85, 0, 112)
my $GP_900       = 0xC0688500;             # _IOWR(0x85, 0, 104)
my $fails = 0;

sub check { my ($ok, $what) = @_; print(($ok ? "ok   " : "FAIL ") . "$what\n"); $fails++ unless $ok; }

sub session {
	my ($ver) = @_;
	open(my $fh, '+<', '/dev/mali') or die "open /dev/mali: $!";
	my $buf = pack('QLl', 0, $ver, 0);
	my $r = ioctl($fh, $GET_API_V2, $buf);
	my (undef, $got, $compat) = unpack('QLl', $buf);
	return ($fh, $r, $got, $compat);
}

# 1. handshakes
my ($s8, $r8, $v8, $c8) = session($V800);
check($r8 && $c8 == 1 && $v8 == $V800, sprintf("API 800 handshake: compatible=%d version=%#x", $c8, $v8));
my ($s9, $r9, $v9, $c9) = session($V900);
check($r9 && $c9 == 1 && $v9 == $V900, sprintf("API 900 handshake: compatible=%d version=%#x", $c9, $v9));
my ($s7, $r7, $v7, $c7) = session((700 << 16) | 700);
check($r7 && $c7 == 0 && $v7 == $V900, sprintf("API 700 refused: compatible=%d version=%#x", $c7, $v7));

# 2. r6p0 allocation (32 bytes) in the 800 session, then free it
my $va = 0x10000000;
# backend_handle is not filled in by either release, only handed back
my $buf = pack('QLLLLQ', 0, $va, 0x10000, 0x10000, 0, 0x5a5a);
my $r = ioctl($s8, $ALLOC_R6P0, $buf);
my $handle = (unpack('QLLLLQ', $buf))[5];
check($r && $handle == 0x5a5a, sprintf("r6p0 MEM_ALLOC: %s, backend_handle=%#x", $r ? "ok" : "$!", $handle));
$buf = pack('QLL', 0, $va, 0);
$r = ioctl($s8, $FREE, $buf);
check($r, "MEM_FREE of it: " . ($r ? "ok" : "$!"));

# 3. each version's own numbers only
$buf = pack('QLLLLQ', 0, $va, 0x10000, 0x10000, 0, 0);
$r = ioctl($s9, $ALLOC_R6P0, $buf);
check(!$r && $!{ENOTTY}, "r6p0 MEM_ALLOC refused in an API 900 session: " . ($r ? "accepted" : "$!"));
$buf = "\0" x 112;
$r = ioctl($s9, $GP_R6P0, $buf);
check(!$r && $!{ENOTTY}, "r6p0 GP_START_JOB refused in an API 900 session: " . ($r ? "accepted" : "$!"));
$buf = "\0" x 104;
$r = ioctl($s8, $GP_900, $buf);
check(!$r && $!{ENOTTY}, "API 900 GP_START_JOB refused in an r6p0 session: " . ($r ? "accepted" : "$!"));

close($s8); close($s9); close($s7);
print $fails ? "$fails FAILED\n" : "all passed\n";
exit($fails ? 1 : 0);
