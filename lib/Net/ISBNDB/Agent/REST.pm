###############################################################################
#
# This file copyright (c) 2006 by Randy J. Ray, all rights reserved
#
# Copying and distribution are permitted under the terms of the Artistic
# License as distributed with Perl versions 5.005 and later. See
# http://language.perl.com/misc/Artistic.html
#
###############################################################################
#
#   $Id: REST.pm 5 2006-09-13 07:44:49Z  $
#
#   Description:    This is the protocol-implementation class for making
#                   requests via the REST interface. At present, this is the
#                   the only supported interface.
#
#   Functions:      parse_authors
#                   parse_books
#                   parse_categories
#                   parse_publishers
#                   parse_subjects
#                   request
#                   request_method
#                   request_uri
#
#   Libraries:      Class::Std
#                   Error
#                   XML::LibXML
#
#   Global Consts:  $VERSION
#                   $BASEURL
#
###############################################################################

package Net::ISBNDB::Agent::REST;

use 5.6.0;
use strict;
use warnings;
use vars qw($VERSION);
use base 'Net::ISBNDB::Agent';

use Class::Std;
use Error;
use XML::LibXML;

$VERSION = "0.10";

my %baseurl    : ATTR(:name<baseurl>    :default<"http://isbndb.com">);
my %authors    : ATTR(:name<authors>    :default<"/api/authors.xml">);
my %books      : ATTR(:name<books>      :default<"/api/books.xml">);
my %categories : ATTR(:name<categories> :default<"/api/categories.xml">);
my %publishers : ATTR(:name<publishers> :default<"/api/publishers.xml">);
my %subjects   : ATTR(:name<subjects>   :default<"/api/subjects.xml">);

my %API_MAP = (
    API        => {},
    Authors    => \%authors,
    Books      => \%books,
    Categories => \%categories,
    Publishers => \%publishers,
    Subjects   => \%subjects,
);

my %parse_table = (
    Authors    => \&parse_authors,
    Books      => \&parse_books,
    Categories => \&parse_categories,
    Publishers => \&parse_publishers,
    Subjects   => \&parse_subjects,
);

###############################################################################
#
#   Sub Name:       request_method
#
#   Description:    Return the HTTP method used for requests
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object
#                   $obj      in      ref       Object from the API hierarchy
#                   $args     in      hashref   Arguments to the request
#
#   Returns:        'GET'
#
###############################################################################
sub request_method : RESTRICTED
{
    'GET';
}

###############################################################################
#
#   Sub Name:       request_uri
#
#   Description:    Return a URI object representing the target URL for the
#                   request.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object
#                   $obj      in      ref       Object from the API hierarchy
#                   $args     in      hashref   Arguments to the request
#
#   Returns:        Success:    URI instance
#                   Failure:    throws Error::Simple
#
###############################################################################
sub request_uri : RESTRICTED
{
    my ($self, $obj, $args) = @_;

    my $id = ident $self;

    # $obj should already have been resolved, so the methods on it should work
    my $key = $obj->get_api_key;
    my $apiloc = $API_MAP{$obj->get_type}->{$id};
    my $argscopy = { %$args };

    # If $apiloc is null, we can't go on
    throw Error::Simple("No API URL for the type '" . $obj->get_type . "'")
        unless $apiloc;

    # Only add the "access_key" argument if it isn't already present. They may
    # have overridden it.
    $argscopy->{access_key} = $key unless $argscopy->{access_key};
    # Build the request parameters list
    my @args = ();
    for $key (sort keys %$argscopy)
    {
        if (ref $argscopy->{$key})
        {
            # Some params, like "results", can appear multiple times. This is
            # implemented as the value being an array reference.
            for (@{$argscopy->{$key}})
            {
                push(@args, "$key=$_");
            }
        }
        else
        {
            # Normal, one-shot argument
            push(@args, "$key=$argscopy->{$key}");
        }
    }

    URI->new("$baseurl{$id}$apiloc?" . join('&', @args));
}

###############################################################################
#
#   Sub Name:       request
#
#   Description:
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object
#                   $obj      in      scalar    Object or type name or class
#                   $args     in      hashref   Hash reference of arguments to
#                                                 the raw request
#                   $single   in      boolean   True/false whether we are to
#                                                 return a singular or plural
#                                                 result
#
#   Returns:        Success:    based on $single, a API-derived object or list
#                   Failure:    throws Error::Simple
#
###############################################################################
sub request : RESTRICTED
{
    my ($self, $obj, $args, $single) = @_;
    $obj = $self->resolve_obj($obj);

    # Do we overwrite $obj with the new data, return it instead of a new
    # object? We do this in "single" mode when $obj is an object instead of a
    # type-name or full class-name.
    my $overwrite = ($single and ref($obj)) ? 1 : 0;

    my $content = $self->raw_request($obj, $args);

    # First off, parse $content as XML
    my $parser = XML::LibXML->new();
    my $dom = eval { $parser->parse_string($$content); };
    throw Error::Simple("XML parse error: $@") if $@;

    my $top_elt = $dom->documentElement();
    my ($value, $stats) = $parse_table{$obj->get_type}->($self, $top_elt);

    $obj->copy(ref($value) ? $value->[0] : $value) if $overwrite;

    $value;
}

###############################################################################
#
#   Sub Name:       parse_authors
#
#   Description:
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object
#                   $root_elt in      ref       XML::LibXML::Node object
#
#   Returns:        Success:    listref
#                   Failure:    throws Error::Simple
#
###############################################################################
sub parse_authors : RESTRICTED
{
    my ($self, $root_elt) = @_;

    my ($total_results, $page_size, $page_number, $shown_results, $list_elt,
        @authorblocks, $authors, $one_author, $authorref, $tmp);
    # The class should already be loaded before we got to this point:
    my $class = Net::ISBNDB::API->class_for_type('Authors');

    # For now, we aren't interested in the root element (the only useful piece
    # of information in it is the server-time of the request). So skip down a
    # level-- there should be exactly one AuthorList element.
    ($list_elt) = $root_elt->getElementsByTagName('AuthorList');
    throw Error::Simple("No <AuthorList> element found in response")
        unless (ref $list_elt);

    # These attributes live on the AuthorList element
    $total_results = $list_elt->getAttribute('total_results');
    $page_size     = $list_elt->getAttribute('page_size');
    $page_number   = $list_elt->getAttribute('page_number');
    $shown_results = $list_elt->getAttribute('shown_results');

    # Start with no categories in the list, and get the <CategoryData> nodes
    $authors = [];
    @authorblocks = $list_elt->getElementsByTagName('AuthorData');
    throw Error::Simple("Number of <AuthorData> blocks does not match " .
                        "'shown_results' value")
        unless ($shown_results == @authorblocks);
    for $one_author (@authorblocks)
    {
        # Clean slate
        $authorref = {};

        # ID is an attribute of AuthorData
        $authorref->{id} = $one_author->getAttribute('person_id');
        # Name is just text
        if (($tmp) = $one_author->getElementsByTagName('Name'))
        {
            $authorref->{name} = $self->_lr_trim($tmp->textContent);
        }
        # The <Details> element holds some data in attributes
        if (($tmp) = $one_author->getElementsByTagName('Details'))
        {
            $authorref->{first_name} =
                $self->_lr_trim($tmp->getAttribute('first_name'));
            $authorref->{last_name} =
                $self->_lr_trim($tmp->getAttribute('last_name'));
            $authorref->{dates} = $tmp->getAttribute('dates');
            $authorref->{has_books} = $tmp->getAttribute('has_books');
        }
        # Look for a list of categories and save the IDs
        if (($tmp) = $one_author->getElementsByTagName('Categories'))
        {
            my $categories = [];
            foreach ($tmp->getElementsByTagName('Category'))
            {
                push(@$categories, $_->getAttribute('category_id'));
            }

            $authorref->{categories} = $categories;
        }
        # Look for a list of subjects. We save those in a special format, here.
        if (($tmp) = $one_author->getElementsByTagName('Subject'))
        {
            my $subjects = [];
            foreach ($tmp->getElementsByTagName('Subject'))
            {
                push(@$subjects, join(':',
                                      $_->getAttribute('subject_id'),
                                      $_->getAttribute('book_count')));
            }

            $authorref->{subjects} = $subjects;
        }

        push(@$authors, $class->new($authorref));
    }

    return ($authors, { total_results => $total_results,
                        page_size => $page_size,
                        page_number => $page_number,
                        shown_results => $shown_results });
}

###############################################################################
#
#   Sub Name:       parse_books
#
#   Description:    Parse the XML resulting from a call to the books API.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object
#                   $root_elt in      ref       XML::LibXML::Node object
#
#   Returns:        Success:    listref
#                   Failure:    throws Error::Simple
#
###############################################################################
sub parse_books : RESTRICTED
{
    my ($self, $root_elt) = @_;

    my ($total_results, $page_size, $page_number, $shown_results, $list_elt,
        @bookblocks, $books, $one_book, $bookref, $tmp);
    # The class should already be loaded before we got to this point:
    my $class = Net::ISBNDB::API->class_for_type('Books');

    # For now, we aren't interested in the root element (the only useful piece
    # of information in it is the server-time of the request). So skip down a
    # level-- there should be exactly one BookList element.
    ($list_elt) = $root_elt->getElementsByTagName('BookList');
    throw Error::Simple("No <BookList> element found in response")
        unless (ref $list_elt);

    # These attributes live on the BookList element
    $total_results = $list_elt->getAttribute('total_results');
    $page_size     = $list_elt->getAttribute('page_size');
    $page_number   = $list_elt->getAttribute('page_number');
    $shown_results = $list_elt->getAttribute('shown_results');

    # Start with no books in the list, and get the <BookData> nodes
    $books = [];
    @bookblocks = $list_elt->getElementsByTagName('BookData');
    throw Error::Simple("Number of <BookData> blocks does not match " .
                        "'shown_results' value")
        unless ($shown_results == @bookblocks);
    for $one_book (@bookblocks)
    {
        # Clean slate
        $bookref = {};

        # ID and ISBN are attributes of BookData
        $bookref->{id} = $one_book->getAttribute('book_id');
        $bookref->{isbn} = $one_book->getAttribute('isbn');
        # Title is just text
        if (($tmp) = $one_book->getElementsByTagName('Title'))
        {
            $bookref->{title} = $self->_lr_trim($tmp->textContent);
        }
        # TitleLong is just text
        if (($tmp) = $one_book->getElementsByTagName('TitleLong'))
        {
            $bookref->{longtitle} = $self->_lr_trim($tmp->textContent);
        }
        # AuthorsText is just text
        if (($tmp) = $one_book->getElementsByTagName('AuthorsText'))
        {
            $bookref->{authors_text} = $self->_lr_trim($tmp->textContent);
        }
        # PublisherText also identifies the publisher record by ID
        if (($tmp) = $one_book->getElementsByTagName('PublisherText'))
        {
            $bookref->{publisher} = $tmp->getAttribute('publisher_id');
            $bookref->{publisher_text} = $self->_lr_trim($tmp->textContent);
        }
        # Look for a list of subjects
        if (($tmp) = $one_book->getElementsByTagName('Subjects'))
        {
            my $subjects = [];
            foreach ($tmp->getElementsByTagName('Subject'))
            {
                push(@$subjects, $_->getAttribute('subject_id'));
            }

            $bookref->{subjects} = $subjects;
        }
        # Look for the list of author records, for their IDs
        if (($tmp) = $one_book->getElementsByTagName('Authors'))
        {
            my $authors = [];
            foreach ($tmp->getElementsByTagName('Person'))
            {
                push(@$authors, $_->getAttribute('person_id'));
            }

            $bookref->{authors} = $authors;
        }

        push(@$books, $class->new($bookref));
    }

    return ($books, { total_results => $total_results, page_size => $page_size,
                      page_number => $page_number,
                      shown_results => $shown_results });
}

###############################################################################
#
#   Sub Name:       parse_categories
#
#   Description:
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object
#                   $root_elt in      ref       XML::LibXML::Node object
#
#   Returns:        Success:    listref
#                   Failure:    throws Error::Simple
#
###############################################################################
sub parse_categories : RESTRICTED
{
    my ($self, $root_elt) = @_;

    my ($total_results, $page_size, $page_number, $shown_results, $list_elt,
        @catblocks, $cats, $one_cat, $catref, $tmp);
    # The class should already be loaded before we got to this point:
    my $class = Net::ISBNDB::API->class_for_type('Categories');

    # For now, we aren't interested in the root element (the only useful piece
    # of information in it is the server-time of the request). So skip down a
    # level-- there should be exactly one CategoryList element.
    ($list_elt) = $root_elt->getElementsByTagName('CategoryList');
    throw Error::Simple("No <CategoryList> element found in response")
        unless (ref $list_elt);

    # These attributes live on the CategoryList element
    $total_results = $list_elt->getAttribute('total_results');
    $page_size     = $list_elt->getAttribute('page_size');
    $page_number   = $list_elt->getAttribute('page_number');
    $shown_results = $list_elt->getAttribute('shown_results');

    # Start with no categories in the list, and get the <CategoryData> nodes
    $cats = [];
    @catblocks = $list_elt->getElementsByTagName('CategoryData');
    throw Error::Simple("Number of <CategoryData> blocks does not match " .
                        "'shown_results' value")
        unless ($shown_results == @catblocks);
    for $one_cat (@catblocks)
    {
        # Clean slate
        $catref = {};

        # ID, book count, marc field, marc indicator 1 and marc indicator 2
        # are all attributes of SubjectData
        $catref->{id} = $one_cat->getAttribute('category_id');
        $catref->{parent} = $one_cat->getAttribute('parent_id');
        # Name is just text
        if (($tmp) = $one_cat->getElementsByTagName('Name'))
        {
            $catref->{name} = $self->_lr_trim($tmp->textContent);
        }
        # The <Details> element holds some data in attributes
        if (($tmp) = $one_cat->getElementsByTagName('Details'))
        {
            $catref->{summary} =
                $self->_lr_trim($tmp->getAttribute('summary'));
            $catref->{depth} = $tmp->getAttribute('depth');
            $catref->{element_count} = $tmp->getAttribute('element_count');
        }
        # Look for a list of sub-categories and save the IDs
        if (($tmp) = $one_cat->getElementsByTagName('SubCategories'))
        {
            my $sub_categories = [];
            foreach ($tmp->getElementsByTagName('SubCategory'))
            {
                push(@$sub_categories, $_->getAttribute('id'));
            }

            $catref->{sub_categories} = $sub_categories;
        }

        push(@$cats, $class->new($catref));
    }

    return ($cats, { total_results => $total_results, page_size => $page_size,
                     page_number => $page_number,
                     shown_results => $shown_results });
}

###############################################################################
#
#   Sub Name:       parse_publishers
#
#   Description:
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object
#                   $root_elt in      ref       XML::LibXML::Node object
#
#   Returns:        Success:    listref
#                   Failure:    throws Error::Simple
#
###############################################################################
sub parse_publishers : RESTRICTED
{
    my ($self, $root_elt) = @_;

    my ($total_results, $page_size, $page_number, $shown_results, $list_elt,
        @pubblocks, $pubs, $one_pub, $pubref, $tmp);
    # The class should already be loaded before we got to this point:
    my $class = Net::ISBNDB::API->class_for_type('Publishers');

    # For now, we aren't interested in the root element (the only useful piece
    # of information in it is the server-time of the request). So skip down a
    # level-- there should be exactly one PublisherList element.
    ($list_elt) = $root_elt->getElementsByTagName('PublisherList');
    throw Error::Simple("No <PublisherList> element found in response")
        unless (ref $list_elt);

    # These attributes live on the PublisherList element
    $total_results = $list_elt->getAttribute('total_results');
    $page_size     = $list_elt->getAttribute('page_size');
    $page_number   = $list_elt->getAttribute('page_number');
    $shown_results = $list_elt->getAttribute('shown_results');

    # Start with no publishers in the list, and get the <PublisherData> nodes
    $pubs = [];
    @pubblocks = $list_elt->getElementsByTagName('PublisherData');
    throw Error::Simple("Number of <PublisherData> blocks does not match " .
                        "'shown_results' value")
        unless ($shown_results == @pubblocks);
    for $one_pub (@pubblocks)
    {
        # Clean slate
        $pubref = {};

        # ID is an attribute of PublisherData
        $pubref->{id} = $one_pub->getAttribute('publisher_id');
        # Name is just text
        if (($tmp) = $one_pub->getElementsByTagName('Name'))
        {
            $pubref->{name} = $self->_lr_trim($tmp->textContent);
        }
        # Details gives the location in an attribute
        if (($tmp) = $one_pub->getElementsByTagName('Details'))
        {
            $pubref->{location} = $tmp->getAttribute('location');
        }
        # Look for a list of categories and save the IDs
        if (($tmp) = $one_pub->getElementsByTagName('Categories'))
        {
            my $categories = [];
            foreach ($tmp->getElementsByTagName('Category'))
            {
                push(@$categories, $_->getAttribute('category_id'));
            }

            $pubref->{categories} = $categories;
        }

        push(@$pubs, $class->new($pubref));
    }

    return ($pubs, { total_results => $total_results, page_size => $page_size,
                     page_number => $page_number,
                     shown_results => $shown_results });
}

###############################################################################
#
#   Sub Name:       parse_subjects
#
#   Description:
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object
#                   $root_elt in      ref       XML::LibXML::Node object
#
#   Returns:        Success:    listref
#                   Failure:    throws Error::Simple
#
###############################################################################
sub parse_subjects : RESTRICTED
{
    my ($self, $root_elt) = @_;

    my ($total_results, $page_size, $page_number, $shown_results, $list_elt,
        @subjectblocks, $subjects, $one_subject, $subjectref, $tmp);
    # The class should already be loaded before we got to this point:
    my $class = Net::ISBNDB::API->class_for_type('Subjects');

    # For now, we aren't interested in the root element (the only useful piece
    # of information in it is the server-time of the request). So skip down a
    # level-- there should be exactly one SubjectList element.
    ($list_elt) = $root_elt->getElementsByTagName('SubjectList');
    throw Error::Simple("No <SubjectList> element found in response")
        unless (ref $list_elt);

    # These attributes live on the SubjectList element
    $total_results = $list_elt->getAttribute('total_results');
    $page_size     = $list_elt->getAttribute('page_size');
    $page_number   = $list_elt->getAttribute('page_number');
    $shown_results = $list_elt->getAttribute('shown_results');

    # Start with no subjects in the list, and get the <SubjectData> nodes
    $subjects = [];
    @subjectblocks = $list_elt->getElementsByTagName('SubjectData');
    throw Error::Simple("Number of <SubjectData> blocks does not match " .
                        "'shown_results' value")
        unless ($shown_results == @subjectblocks);
    for $one_subject (@subjectblocks)
    {
        # Clean slate
        $subjectref = {};

        # ID, book count, marc field, marc indicator 1 and marc indicator 2
        # are all attributes of SubjectData
        $subjectref->{id} = $one_subject->getAttribute('subject_id');
        $subjectref->{book_count} = $one_subject->getAttribute('book_count');
        $subjectref->{marc_field} = $one_subject->getAttribute('marc_count');
        $subjectref->{marc_indicator_1} =
            $one_subject->getAttribute('marc_indicator_1');
        $subjectref->{marc_indicator_2} =
            $one_subject->getAttribute('marc_indicator_2');
        # Name is just text
        if (($tmp) = $one_subject->getElementsByTagName('Name'))
        {
            $subjectref->{name} = $self->_lr_trim($tmp->textContent);
        }
        # Look for a list of categories and save the IDs
        if (($tmp) = $one_subject->getElementsByTagName('Categories'))
        {
            my $categories = [];
            foreach ($tmp->getElementsByTagName('Category'))
            {
                push(@$categories, $_->getAttribute('category_id'));
            }

            $subjectref->{categories} = $categories;
        }

        push(@$subjects, $class->new($subjectref));
    }

    return ($subjects, { total_results => $total_results,
                         page_size => $page_size,
                         page_number => $page_number,
                         shown_results => $shown_results });
}

1;

=pod

=head1 NAME

Net::ISBNDB::Agent::REST - Agent sub-class that implements a REST protocol

=head1 SYNOPSIS

This module should not be directly used by user applications.

=head1 DESCRIPTION

This module implements the REST-based communication protocol for getting data
from the B<isbndb.com> service. At present, this is the only protocol the
service supports.

=head1 METHODS

This class provides the following methods, most of which are restricted to
this class and any sub-classes of it that may be written:

=over 4

=item parse_authors($ROOT) (R)

=item parse_books($ROOT) (R)

=item parse_categories($ROOT) (R)

=item parse_publishers($ROOT) (R)

=item parse_subjects($ROOT) (R)

Each of these parses the XML response for the corresponding API call. The
C<$ROOT> parameter is a B<XML::LibXML::Node> object, obtained from parsing
the XML returned by the service.

Each of these returns a list-reference of objects, even when there is only
one result value. All of these methods are restricted to this class and
its decendants.

=item request($OBJ, $ARGS, $SINGLE) (R)

Use the B<LWP::UserAgent> object to make a request on the remote service.
C<$OBJ> indicates what type of data request is being made, and C<$ARGS> is a
hash-reference of arguments to be passed in the request. The value C<$SINGLE>
is a boolean that indicates whether a single value should be returned, or all
values that result from parsing.

This method is restricted to this class, and is the required overload of the
request() method from the parent class (L<Net::ISBNDB::Agent>).

=item request_method($OBJ, $ARGS)

Returns the HTTP method (GET, POST, etc.) to use when making the request. The
C<$OBJ> and C<$ARGS> parameters may be used to determine the method (in the
case of this protocol, they are ignored since B<GET> is always the chosen
HTTP method).

=item request_uri($OBJ, $ARGS)

Returns the complete HTTP URI to use in making the request. C<$OBJ> is used
to derive the type of data being fetched, and thus the base URI to use. The
key/value pairs in the hash-reference provided by C<$ARGS> are used in the
REST protocol to set the query parameters that govern the request.

=back

=head1 CAVEATS

The data returned by this class is only as accurate as the data retrieved from
B<isbndb.com>.

The list of results from calling search() is currently limited to 10 items.
This limit will be removed in an upcoming release, when iterators are
implemented.

=head1 SEE ALSO

L<Net::ISBNDB::Agent>, L<LWP::UserAgent>

=head1 AUTHOR

Randy J. Ray E<lt>rjray@blackperl.comE<gt>

=head1 COPYRIGHT

This module and the code within are copyright (c) 2006 by Randy J. Ray and
released under the terms of the Artistic License
(http://www.opensource.org/licenses/artistic-license.php). This
code may be redistributed under either the Artistic License or the GNU
Lesser General Public License (LGPL) version 2.1
(http://www.opensource.org/licenses/lgpl-license.php).

=cut
