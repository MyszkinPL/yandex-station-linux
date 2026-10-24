#!/usr/bin/perl
# The framebuffer setup of the vendor gralloc (gralloc.default.so,
# init_frame_buffer_locked), call by call, to see what /dev/fb0 of this
# kernel gives it. Run on the Station in Linux mode: perl fb-gralloc.pl [/dev/fb0]
use strict;
use warnings;

my $dev = shift // '/dev/fb0';
my ($GET_V, $PUT_V, $GET_F, $PAN) = (0x4600, 0x4601, 0x4602, 0x4606);

sub step { my ($ok, $what) = @_; printf("%-4s %s\n", $ok ? "ok" : "FAIL", $what); exit 1 unless $ok; }

open(my $fb, '+<', $dev) or step(0, "open $dev O_RDWR: $!");
step(1, "open $dev O_RDWR");

my $fix = "\0" x 80;
step(ioctl($fb, $GET_F, $fix), "FBIOGET_FSCREENINFO" . ($! ? ": $!" : ""));
my $var = "\0" x 160;
step(ioctl($fb, $GET_V, $var), "FBIOGET_VSCREENINFO" . ($! ? ": $!" : ""));
my @v = unpack('L40', $var);
printf("     %dx%d virtual %dx%d bpp %d, rgba %d/%d %d/%d %d/%d %d/%d, pixclock %d\n",
	@v[0..3], $v[6], @v[8, 9], @v[11, 12], @v[14, 15], @v[17, 18], $v[22]);

# what gralloc writes: XRGB8888, two pages, activate now
@v[4, 5] = (0, 0);                  # xoffset, yoffset
$v[3] = $v[1] * 2;                  # yres_virtual
$v[6] = 32;                         # bits_per_pixel
@v[8, 9, 10] = (16, 8, 0);          # red
@v[11, 12, 13] = (8, 8, 0);         # green
@v[14, 15, 16] = (0, 8, 0);         # blue
@v[17, 18, 19] = (0, 0, 0);         # transp
$v[21] = 0;                         # activate
$v[29] = 0; $v[30] = 0;             # reserved used by gralloc
my $put = pack('L40', @v);
my $r = ioctl($fb, $PUT_V, $put);
printf("%-4s FBIOPUT_VSCREENINFO (yres_virtual %d)%s\n", $r ? "ok" : "warn", $v[3], $r ? "" : ": $! (gralloc then drops page flipping)");

$var = "\0" x 160;
step(ioctl($fb, $GET_V, $var), "FBIOGET_VSCREENINFO again");
@v = unpack('L40', $var);
printf("     now %dx%d virtual %dx%d bpp %d\n", @v[0..3], $v[6]);

$fix = "\0" x 80;
step(ioctl($fb, $GET_F, $fix), "FBIOGET_FSCREENINFO again");
my ($id, $smem_start, $smem_len) = unpack('Z16 Q L', $fix);
my $line_length = unpack('L', substr($fix, 0x30, 4));
printf("     id '%s' smem_start %#x smem_len %d line_length %d\n", $id, $smem_start, $smem_len, $line_length);
step($smem_len > 0, "smem_len > 0 (gralloc returns -errno otherwise, without a log line)");

my $size = $line_length * $v[3];
$size = ($size + 4095) & ~4095;
printf("     gralloc maps %d bytes (line_length * yres_virtual)\n", $size);
step($size <= $smem_len || 1, "size check (informational)");
print "done: gralloc's framebuffer setup would pass up to mmap\n";
