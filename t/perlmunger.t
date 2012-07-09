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
  my ($name, $in, $out) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  eq_or_diff(Pod_Identity->munge_perl_string($in), $out, $name);
}

#=====================================================================
test 'POD after END' => <<'END IN 1', <<'END OUT 1';
my $hello = 'world';

__END__

=head1 NAME

Hello World

END IN 1
my $hello = 'world';

__END__

=pod

=head1 NAME

Hello World

=cut
END OUT 1

#---------------------------------------------------------------------
test 'no END' => <<'END IN 2', <<'END OUT 2';
my $hello = 'world';

=head1 NAME

Hello World

END IN 2
my $hello = 'world';

__END__

=pod

=head1 NAME

Hello World

=cut
END OUT 2

#---------------------------------------------------------------------
test 'before and after END' => <<'END IN 3', <<'END OUT 3';
my $hello = 'world';

=head1 NAME

Hello World

=cut

__END__

=head2 DESCRIPTION

No biggie.

END IN 3
my $hello = 'world';

__END__

=pod

=head1 NAME

Hello World

=cut

=head2 DESCRIPTION

No biggie.

=cut
END OUT 3

#---------------------------------------------------------------------
test 'extra whitespace' => <<'END IN 4', <<'END OUT 4';
my $hello = 'world';



__END__



=head1 NAME

Hello World

END IN 4
my $hello = 'world';

__END__

=pod

=head1 NAME

Hello World

=cut
END OUT 4

#---------------------------------------------------------------------
test 'DATA section' => <<'END IN 5', <<'END OUT 5';
my $hello = 'world';

=head1 NAME

Hello World

=cut

__DATA__

To be read.
END IN 5
my $hello = 'world';

=pod

=head1 NAME

Hello World

=cut
=cut

__DATA__

To be read.
END OUT 5

#---------------------------------------------------------------------
done_testing;
