package Pod::Elemental::PerlMunger;
# ABSTRACT: a thing that takes a string of Perl and rewrites its documentation

use Moose::Role;

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
use List::Util 1.33 qw(any max);
use Params::Util qw(_INSTANCE);
use PPI;

requires 'munge_perl_string';

around munge_perl_string => sub {
  my ($orig, $self, $perl, $arg) = @_;

  my $perl_utf8 = Encode::encode('utf-8', $perl, Encode::FB_CROAK);

  my $ppi_document = PPI::Document->new(\$perl_utf8);
  confess(PPI::Document->errstr) unless $ppi_document;

  my $last_code_elem;
  my $code_elems = $ppi_document->find(sub {
    return if grep { $_[1]->isa("PPI::Token::$_") }
                    qw(Comment Pod Whitespace Separator Data End);
    return 1;
  });

  $code_elems ||= [];
  for my $elem (@$code_elems) {
    # Really, we might get two elements on the same line, and one could be
    # later in position because it could have a later column — but we don't
    # care, because we're only thinking about Pod, which is linewise.
    next if $last_code_elem
        and $elem->line_number <= $last_code_elem->line_number;

    $last_code_elem = $elem;
  }

  my @pod_tokens;

  {
    my @queue = $ppi_document->children;
    while (my $element = shift @queue) {
      if ($element->isa('PPI::Token::Pod')) {
        my $after_last = $last_code_elem
                      && $last_code_elem->line_number > $element->line_number;
        my @replacements = $self->_replacements_for($element, $after_last);

        # save the text for use in building the Pod-only document
        push @pod_tokens, "$element";

        my $last = $element;
        while (my $next = shift @replacements) {
          my $ok = $last->insert_after($next);
          confess("error inserting replacement!") unless $ok;
          $last = $next;
        }

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
    return 1 if $_[1]->isa('PPI::Statement::End')
             || $_[1]->isa('PPI::Statement::Data');
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

  my $new_end;
  if (defined $end) {
    $new_end = Encode::decode(
      'utf-8',
      $end,
      Encode::FB_CROAK,
    );
  }

  return defined $end
         ? "$new_perl\n\n$new_pod\n\n$new_end"
         : "$new_perl\n\n__END__\n\n$new_pod\n";
};

=attr replacer

The replacer is either a method name or code reference used to produces PPI
elements used to replace removed Pod.  By default, it is
C<L</replace_with_nothing>>, which just removes Pod tokens entirely.  This
means that the line numbers of the code in the newly-produced document are
changed, if the Pod had been interleaved with the code.

See also C<L</replace_with_comment>> and C<L</replace_with_blank>>.

If no further code follows the Pod being replaced, C<L</post_code_replacer>> is
used instead.

=attr post_code_replacer

This attribute is used just like C<L</replacer>>, and defaults to its value,
but is used for building replacements for Pod removed after the last hunk of
code.  The idea is that if you're only concerned about altering your code's
line numbers, you can stop replacing stuff after there's no more code to be
affected.

=cut

has replacer => (
  is  => 'ro',
  default => 'replace_with_nothing',
);

has post_code_replacer => (
  is   => 'ro',
  lazy => 1,
  default => sub { $_[0]->replacer },
);

sub _replacements_for {
  my ($self, $element, $after_last) = @_;

  my $replacer = $after_last ? $self->replacer : $self->post_code_replacer;
  return $self->$replacer($element);
}

=method replace_with_nothing

This method returns nothing.  It's the default C<L</replacer>>.  It's not very
interesting.

=cut

sub replace_with_nothing { return }

=method replace_with_comment

This replacer replaces removed Pod elements with a comment containing their
text.  In other words:

  =head1 A header!

  This is great!

  =cut

...is replaced with:

  # =head1 A header!
  #
  # This is great!
  #
  # =cut

=cut

sub replace_with_comment {
  my ($self, $element) = @_;

  my $text = "$element";

  (my $pod = $text) =~ s/^(.)/#pod $1/mg;
  $pod =~ s/^$/#pod/mg;
  my $commented_out = PPI::Token::Comment->new($pod);

  return $commented_out;
}

=method replace_with_blank

This replacer replaces removed Pod elements with vertical whitespace of equal
line count.  In other words:

  =head1 A header!

  This is great!

  =cut

...is replaced with five blank lines.

=cut

sub replace_with_blank {
  my ($self, $element) = @_;

  my $text = "$element";
  my @lines = split /\n/, $text;
  my $blank = PPI::Token::Whitespace->new("\n" x (@lines));

  return $blank;
}


1;
