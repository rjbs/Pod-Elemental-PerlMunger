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

C<%arg> may contain any input for the underlying procedure.  The only key with
associated meaning is C<filename> which may be omitted.  If given, it should be
the name of the file whose contents are being munged.

The method will return a string containing the rewritten and combined document.

Classes including this role must implement a C<munge_perl_string> that expects
to be called like this:

  $object->munge_perl_string(\%doc, \%arg);

C<%doc> will have two entries:

  ppi - a PPI::Document of the Perl document with all its Pod removed
  pod - a Pod::Document with no transformations yet performed

This C<munge_perl_string> method should return a hashref in the same format as
C<%doc>.

=cut

use namespace::autoclean;

use PPI;

requires 'munge_perl_string';

around munge_perl_string => sub {
  my ($orig, $self, $perl, $arg) = @_;

  my $ppi_document = PPI::Document->new(\$perl);
  confess(PPI::Document->errstr) unless $ppi_document;

  my @pod_tokens = map {"$_"} @{ $ppi_document->find('PPI::Token::Pod') || [] };
  $ppi_document->prune('PPI::Token::Pod');

  if ($ppi_document->serialize =~ /^=[a-z]/m) {
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

  my $end = do {
    my $finder = sub {
      return 1 if $_[1]->isa('PPI::Statement::End') || $_[1]->isa('PPI::Statement::Data');
      return 0;
    };
    my $end_elem = $doc->{ppi}->find($finder);
    join q{}, @{ $end_elem || [] };
  };

  my $pruner = sub {
    return 1 if $_[1]->isa('PPI::Statement::End') || $_[1]->isa('PPI::Statement::Data');
    return 0;
  };

  $doc->{ppi}->prune($pruner);

  my $new_perl = $doc->{ppi}->serialize;

  return $end
         ? "$new_perl\n\n$new_pod\n\n$end"
         : "$new_perl\n__END__\n$new_pod\n";
};

1;
