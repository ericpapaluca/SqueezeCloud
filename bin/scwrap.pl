#!/usr/bin/perl
use strict;
use warnings;

# scwrap.pl — SqueezeCloud transcode wrapper (TEACHING EXAMPLE).
#
# Demonstrates how to pass a per-track value to ffmpeg when there is no
# custom-convert.conf placeholder for it. The value (a volume gain, in dB) is
# carried in the stream URL *fragment* the plugin appends (#scgain=<db>). This
# wrapper reads it, strips the fragment so ffmpeg fetches a clean/unmodified
# URL, then execs the real ffmpeg with a matching -af volume filter.
#
# It is intentionally BENIGN: it only adjusts playback volume. It does not
# decrypt anything.
#
# custom-convert.conf calls it as:
#     [perl] "<plugindir>/bin/scwrap.pl" <outfmt> $URL$ [extra ffmpeg args...]
# where <outfmt> is the -f value the rule needs: wav | s16le | flac.
#
# ---- Perl notes ----
#   * @ARGV holds the command-line arguments (like $URL$, expanded by LMS).
#   * my ($a, $b, @rest) = @ARGV;  unpacks the first two, rest into an array.
#   * $ENV{FOO} reads an environment variable; // provides a default.
#   * exec { PROGRAM } LIST replaces this process image with PROGRAM, passing
#     LIST as its full argv (argv[0] included). No shell is involved, so the URL
#     can't be re-interpreted by a shell.

my ($outfmt, $url, @extra) = @ARGV;
die "usage: scwrap.pl <outfmt> <url> [ffmpeg args...]\n"
	unless defined $outfmt && defined $url && length $url;

# 1. Pull the per-track value out of the URL fragment the plugin appended.
#    Matches e.g.  ...m3u8#scgain=3   or   ...#a=1&scgain=-2.5
my $gain = 0;
if ($url =~ /#[^#]*\bscgain=(-?\d+(?:\.\d+)?)/) {
	$gain = $1;
}

# 2. Strip the fragment (everything from the first '#') so ffmpeg receives the
#    exact URL the CDN signed — the fragment is our private side-channel only.
$url =~ s/#.*\z//s;

# 3. Build the real ffmpeg command. The interpreter path can be overridden with
#    the FFMPEG env var; otherwise rely on PATH.
my $ffmpeg = $ENV{FFMPEG} // 'ffmpeg';
my @cmd = ($ffmpeg, '-loglevel', 'quiet', '-i', $url, @extra);
push @cmd, '-af', "volume=${gain}dB" if $gain != 0;
push @cmd, '-f', $outfmt, '-';

# Trace to STDERR so the decision is visible in the LMS transcode log.
warn "scwrap: outfmt=$outfmt gain=${gain}dB extra=@extra\n";

# 4. Hand off to ffmpeg, replacing this process (no fork, no shell).
exec { $cmd[0] } @cmd or die "scwrap: exec $ffmpeg failed: $!\n";
