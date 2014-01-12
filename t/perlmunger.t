use strict;
use warnings;

use Test::More 0.88;        # done_testing
plan tests => 5;            # Comment this line out while adding tests

# Load Test::Differences, if available:
BEGIN {
  # SUGGEST PREREQ: Test::Differences
  if (eval "use Test::Differences; 1") {
    # Not all versions of Test::Differences support changing the style:
    eval { Test::Differences::unified_diff() }
  } else {
    *eq_or_diff = \&is;         # Just use "is" instead
  }
} # end BEGIN

#---------------------------------------------------------------------
# The simplest possible POD munger:
{
  package Pod_Identity;

  use Pod::Elemental;
  use Moose;
  with 'Pod::Elemental::PerlMunger';

  sub munge_perl_string { return $_[1] }
}

#---------------------------------------------------------------------
sub test
{
  my ($name, $in, $out, $arg) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  open my $in_fh, "<:raw:bytes", "t/corpus/$in"
    or die "error opening $in: $!";
  my $in_pod = do { local $/; <$in_fh> };

  open my $out_fh, "<:raw:bytes", "t/corpus/$out"
    or die "error opening $out: $!";
  my $want = do { local $/; <$out_fh> };

  my $have = Pod_Identity->new($arg ? $arg : ())->munge_perl_string($in_pod);

  eq_or_diff($have, $want, $name);
}

test 'no END' => "simple.in.txt", "simple.out.txt";

test 'POD after END' => "after-end.txt", "simple.out.txt";

test 'before and after END' => "straddle-end.in.txt", "straddle-end.out.txt";

test 'extra whitespace' => "extra-ws.in.txt", "simple.out.txt";

test 'DATA section' => "data-section.in.txt", "data-section.out.txt";

done_testing;
