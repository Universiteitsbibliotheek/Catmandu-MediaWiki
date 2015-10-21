package Catmandu::Importer::MediaWiki;
use Catmandu::Sane;
use MediaWiki::API;
use Catmandu::Util qw(:is :check array_includes);
use Moo;

#only generators that generate pages, and that have generators
my $generators = [qw(
    alllinks
    allpages
    allredirects
    alltransclusions
    backlinks
    categorymembers
    embeddedin
    exturlusage
    imageusage
    iwbacklinks
    langbacklinks
    pageswithprop
    prefixsearch
    random
    recentchanges
    watchlist
    watchlistraw
)];
my $default_args = {
    prop => "revisions",
    rvprop => "ids|flags|timestamp|user|comment|size|content",
    rvlimit => 'max',
    gaplimit => 100,
    gapfilterredir => "nonredirects"
};

has url => (
    is => 'ro',
    isa => sub { check_string($_[0]); }
);
#cf. https://www.mediawiki.org/wiki/API:Login
has lgname => ( is => 'ro' );
has lgpassword => ( is => 'ro' );
#cf. http://www.mediawiki.org/wiki/API:Lists
#cf. http://www.mediawiki.org/wiki/API:Query#Generators
has generate => (
    is => 'ro',
    isa => sub {
        array_includes($generators,$_[0]) or die("invalid generator");
    },
    lazy => 1,
    default => sub { "allpages"; }
);
has args => (
    is => 'ro',
    isa => sub { check_hash_ref($_[0]); },
    lazy => 1,
    default => sub { $default_args },
    coerce => sub {
        my $l = $_[0];
        my $h = is_hash_ref($l) ? +{ %$default_args,%$l } : $default_args;
        for(keys %$h){
            delete $h->{$_} unless defined $h->{$_};
        }
        $h;
    }
);

with 'Catmandu::Importer';

sub _build_mw {
    my $self = $_[0];
    my $mw = MediaWiki::API->new( { api_url => $self->url() }  );

    my $ua = $mw->{ua};

    if(is_string($ENV{LWP_TRACE})){
        $ua->add_handler("request_send",  sub { shift->dump; return });
        $ua->add_handler("response_done", sub { shift->dump; return });
    }

    $mw;
}
sub _fail {
    my $err = $_[0];
    die( $err->{code}.': '.$err->{details} );
}

sub generator {
    my $self = $_[0];

    my $generator = $self->generate();
    my $args = $self->args();

    sub {
        state $mw = $self->_build_mw();
        state $pages = [];
        state $cont_args = { continue => '' };
        state $logged_in = 0;

        unless($logged_in){
            #only try to login when both arguments are set
            if(is_string($self->lgname) && is_string($self->lgpassword)){
                $mw->login({ lgname => $self->lgname, lgpassword => $self->lgpassword }) or _fail($mw->{error});
            }
            $logged_in = 1;
        }

        unless(@$pages){
            return unless defined $cont_args;

            my $a = {
                %$args,
                %$cont_args,
                action => "query",
                indexpageids => 1,
                generator => $generator,
                format => "json"
            };
            #will work with generator in the future
            delete $a->{rvlimit};
            my $res = $mw->api($a) or _fail($mw->{error});
            return unless defined $res;

            $cont_args = $res->{'continue'};

            if(exists($res->{'query'}->{'pageids'})){

                for my $pageid(@{ $res->{'query'}->{'pageids'} }){
                    #'titles, pageids or a generator was used to supply multiple pages, but the limit, startid, endid, dirNewer, user, excludeuser, start and end parameters may only be used on a single page.'
                    #which means: cannot repeat pageids when asking for full history
                    my $page = $res->{'query'}->{'pages'}->{$pageid};
                    if(is_string($args->{rvlimit})){

                        my $a = {
                            action => "query",
                            format => "json",
                            pageids => $pageid,
                            prop => "revisions",
                            rvprop => $default_args->{rvprop},
                            rvlimit => $args->{rvlimit}
                        };
                        my $res2 = $mw->api($a) or _fail($mw->{error});
                        $page->{revisions} = $res2->{'query'}->{'pages'}->{$pageid}->{revisions} if $res2->{'query'}->{'pages'}->{$pageid}->{revisions};

                    }
                    push @$pages,$res->{'query'}->{'pages'}->{$pageid};
                }
            }
        }

        shift @$pages;
    };
}

=head1 NAME

Catmandu::Importer::MediaWiki - Catmandu importer that imports pages from mediawiki

=head1 DESCRIPTION

This importer uses the query api from mediawiki to get a list of pages
that match certain requirements.

It retrieves a list of pages and their content by using the generators
from mediawiki:

L<http://www.mediawiki.org/wiki/API:Query#Generators>

The default generator is 'allpages'.

The list could also be retrieved with the module 'list':

L<http://www.mediawiki.org/wiki/API:Lists>

But this module 'list' is very limited. It retrieves a list of pages
with a limited set of attributes (pageid, ns and title).

The module 'properties' on the other hand lets you add properties:

L<http://www.mediawiki.org/wiki/API:Properties>

But the selecting parameters (titles, pageids and revids) are too specific
to execute a query in one call. One should execute a list query, and then
use the pageids to feed them to the submodule 'properties'.

To execute a query, and add properties to the pages in one call can be
accomplished by use of generators.

L<http://www.mediawiki.org/wiki/API:Query#Generators>

These parameters are set automatically, and cannot be overwritten:

action = "query"
indexpageids = 1
generator = <generate>
format = "json"

Additional parameters can be set in the constructor argument 'args'.
Arguments for a generator origin from the list module with the same name,
but must be prepended with 'g'.

=head1 ARGUMENTS

=over 4

=item generate

type: string

explanation:    type of generator to use. For a complete list, see L<http://www.mediawiki.org/wiki/API:Lists>.
                because Catmandu::Iterable already defines 'generator', this parameter has been renamed
                to 'generate'.

default: 'allpages'.

=item args

type: hash

explanation: extra arguments. These arguments are merged with the defaults.

default:

    {
        prop => "revisions",
        rvprop => "ids|flags|timestamp|user|comment|size|content",
        gaplimit => 100,
        gapfilterredir => "nonredirects"
    }

which means:

    prop             add revisions to the list of page attributes
    rvprop           specific properties for the list of revisions
    gaplimit         limit for generator 'allpages' (every 'generator' has its own limit).
    gapfilterredir   filter out redirect pages

=item lgname

type: string

explanation:    login name. Only used when both lgname and lgpassword are set.

L<https://www.mediawiki.org/wiki/API:Login>

=item lgpassword

type: string

explanation:    login password. Only used when both lgname and lgpassword are set.

=back

=head1 SYNOPSIS

    use Catmandu::Sane;
    use Catmandu::Importer::MediaWiki;

    binmode STDOUT,":utf8";

    my $importer = Catmandu::Importer::MediaWiki->new(
        url => "http://en.wikipedia.org/w/api.php",
        generate => "allpages",
        args => {
            prop => "revisions",
            rvprop => "ids|flags|timestamp|user|comment|size|content",
            gaplimit => 100,
            gapprefix => "plato",
            gapfilterredir => "nonredirects"
        }
    );
    $importer->each(sub{
        my $r = shift;
        my $content = $r->{revisions}->[0]->{"*"};
        say $r->{title};
    });

=head1 AUTHORS

Nicolas Franck C<< <nicolas.franck at ugent.be> >>

=head1 SEE ALSO

L<Catmandu>, L<MediaWiki::API>

=cut

1;
