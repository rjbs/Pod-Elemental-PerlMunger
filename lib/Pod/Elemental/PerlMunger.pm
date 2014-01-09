package Pod::Elemental::PerlMunger;
use Moose::Role;
# ABSTRACT: a thing that takes a string of Perl and rewrites its documentation

=head1 OVERVIEW

This role is to be included in classes that rewrite the documentation of a Perl
document, stripping out all the Pod, munging it, and replacing it into the
Perl.

The only relevant method is C<munge_perl_string>, which must be implemented
with a different interface than will be exposed.

When calling the C<munge_perl_string> method, arguments should be passed like
this:

  $object->munge_perl_string($perl_string, \%arg);

C<$perl_string> should be a character string containing Perl source code.

C<%arg> may contain any input for the underlying procedure.  The only key with
associated meaning is C<filename> which may be omitted.  If given, it should be
the name of the file whose contents are being munged.

The method will return a character string containing the rewritten and combined
document.

Classes including this role must implement a C<munge_perl_string> that expects
to be called like this:

  $object->munge_perl_string(\%doc, \%arg);

C<%doc> will have two entries:

  ppi - a PPI::Document of the Perl document with all its Pod removed
  pod - a Pod::Elemental::Document with no transformations yet performed

This C<munge_perl_string> method should return a hashref in the same format as
C<%doc>.

=cut

use namespace::autoclean;

use Encode ();
use List::MoreUtils qw(any);
use Params::Util qw(_INSTANCE);
use PPI;

requires 'munge_perl_string';

around munge_perl_string => sub {
  my ($orig, $self, $perl, $arg) = @_;

  my $perl_utf8 = Encode::encode('utf-8', $perl, Encode::FB_CROAK);

  my $ppi_document = PPI::Document->new(\$perl_utf8);
  confess(PPI::Document->errstr) unless $ppi_document;

  # Use a depth-first queue search
  my @pod_tokens;

  {
    my @queue = $ppi_document->children;
    while (my $element = shift @queue) {
      if ($element->isa('PPI::Token::Pod')) {
        # Delete the child
        push @pod_tokens, "$element";

        my @lines = split /\n/, $pod_tokens[-1];
        my $blank = "\n" x (@lines);
        # my $replace_with = PPI::Token::Whitespace->new($blank);

        (my $pod = $pod_tokens[-1]) =~ s/^/# /mg;
        my $replace_with = PPI::Token::Comment->new($pod);

        my $ok = $element->insert_after($replace_with);

        $element->delete;

        next;
      }

      if ( _INSTANCE($element, 'PPI::Node') ) {
        # Depth-first keeps the queue size down
        unshift @queue, $element->children;
      }
    }
  }

  my $finder = sub {
    my $node = $_[1];
    return 0 unless any { $node->isa($_) }
       qw( PPI::Token::Quote PPI::Token::QuoteLike PPI::Token::HereDoc );
    return 1 if $node->content =~ /^=[a-z]/m;
    return 0;
  };

  if ($ppi_document->find_first($finder)) {
    $self->log(
      sprintf "can't invoke %s on %s: there is POD inside string literals",
        $self->plugin_name,
        (defined $arg->{filename} ? $arg->{filename} : 'input')
    );
  }

  # TODO: I should add a $weaver->weave_* like the Linewise methods to take the
  # input, get a Document, perform the stock transformations, and then weave.
  # -- rjbs, 2009-10-24
  my $pod_str = join "\n", @pod_tokens;
  my $pod_document = Pod::Elemental->read_string($pod_str);

  my $doc = $self->$orig(
    {
      ppi => $ppi_document,
      pod => $pod_document,
    },
    $arg,
  );

  my $new_pod = $doc->{pod}->as_pod_string;

  my $end_finder = sub {
    return 1 if $_[1]->isa('PPI::Statement::End') || $_[1]->isa('PPI::Statement::Data');
    return 0;
  };

  my $end = do {
    my $end_elem = $doc->{ppi}->find($end_finder);

    # If there's nothing after __END__, we can put the POD there:
    if (not $end_elem or (@$end_elem == 1 and
                          $end_elem->[0]->isa('PPI::Statement::End') and
                          $end_elem->[0] =~ /^__END__\s*\z/)) {
      $end_elem = [];
    }

    @$end_elem ? join q{}, @$end_elem : undef;
  };

  $doc->{ppi}->prune($end_finder);

  my $new_perl = Encode::decode(
    'utf-8',
    $doc->{ppi}->serialize,
    Encode::FB_CROAK,
  );

  s/\n\s*\z// for $new_perl, $new_pod;

  return defined $end
         ? "$new_perl\n\n$new_pod\n\n$end"
         : "$new_perl\n\n__END__\n\n$new_pod\n";
};

1;
