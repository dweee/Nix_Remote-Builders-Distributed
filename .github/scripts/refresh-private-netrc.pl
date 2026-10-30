#!/usr/bin/perl
# Atomically combine daemon-only credentials without placing secrets in the store.
use strict;
use warnings;
use Fcntl qw(:flock :DEFAULT);
use File::Basename qw(dirname);
use File::Temp qw(tempfile);

@ARGV == 3 or die "Expected two sources and a destination.\n";
my ($attic, $managed, $dest) = @ARGV;
my $dir = dirname($dest);
umask 0077;
if (!-d $dir) { mkdir($dir, 0700) || -d $dir or die "Cannot create private credential directory.\n"; }
(-d $dir && !-l $dir) or die "Invalid private credential directory.\n";
(stat($dir))[4] == $> or die "Private credential directory has the wrong owner.\n";
chmod(0700, $dir) or die "Cannot protect credential directory.\n";
!-l "$dir/refresh.lock" or die "Invalid credential refresh lock.\n";
sysopen(my $lock, "$dir/refresh.lock", O_WRONLY | O_CREAT, 0600)
    or die "Cannot open credential refresh lock.\n";
flock($lock, LOCK_EX) or die "Cannot acquire credential refresh lock.\n";
my ($out, $temporary) = tempfile('netrc.XXXXXXXX', DIR => $dir, UNLINK => 1);
binmode($out);
for my $source ($attic, $managed) {
    if (!open(my $in, '<', $source)) {
        warn "Attic netrc unavailable; private cache authentication will be retried.\n" if $source eq $attic;
        next;
    } else {
        binmode($in);
        while (1) {
            my $bytes = read($in, my $buffer, 65536);
            defined($bytes) or die "Cannot read a credential source.\n";
            last if $bytes == 0;
            print {$out} $buffer or die "Cannot write private credentials.\n";
        }
        close($in) or die "Cannot close a credential source.\n";
        print {$out} "\n" or die "Cannot write private credentials.\n";
    }
}
close($out) or die "Cannot close private credentials.\n";
chmod(0600, $temporary) or die "Cannot protect private credentials.\n";
rename($temporary, $dest) or die "Cannot install private credentials.\n";
