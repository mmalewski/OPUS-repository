package LetsMT::Corpus;

=head1 NAME

LetsMT::Corpus - find matching documents in a corpus

=head1 DESCRIPTION
=cut

use strict;
use XML::LibXML;
use XML::Simple;

use open qw(:std :utf8);
use Encode qw(decode decode_utf8 is_utf8);

use String::Approx qw/amatch adistr/;
use File::Basename qw/basename dirname/;

use LetsMT::Tools::Strings;
use LetsMT::Lang::ISO639;
use LetsMT::WebService;

use LetsMT::Align::Documents qw/:all/;


use Log::Log4perl qw(get_logger :levels);

use Exporter 'import';
our @EXPORT = qw(
    is_file resource_exists resource_type
    get_resource_parameter get_user_parameter
    get_align_parameter get_import_parameter
    find_all_parallel find_sentence_aligned
    find_resources find_corpusfiles find_translations
);
our %EXPORT_TAGS = ( all => \@EXPORT );

# my $XmlParser = new XML::LibXML;

## Default search mode for finding parallel documents
## (comment out if you like to use the fuzzy search below)
my $DEFAULT_SEARCH = 'identical_with_lang';

## uncomment this one if you want to match similar file names as well
## (difference = language ID's + matching thresholds below)
##
## TODO: searching for similar files is less efficient!
##  --> need to check time/space complexities
##  --> especially for large corpora (= with many files)
# my $DEFAULT_SEARCH = 'similar';

## default thresholds for size ratio and name match
my $DEFAULT_SIZE_RATIO_THR = 0.7;
my $DEFAULT_NAME_MATCH_THR = 0.9;

## default interpolation weights for size ratio and name match
my $DEFAULT_SIZE_RATIO_WEIGHT = 0.2;
my $DEFAULT_NAME_MATCH_WEIGHT = 1 - $DEFAULT_SIZE_RATIO_WEIGHT;

# default parameters for searching parallel documents

our %DEFAULT_SEARCH_PARA = (
    search_parallel                   => $DEFAULT_SEARCH,
## old parameters - not used anymore!
#    search_parallel_min_size_ratio    => $DEFAULT_SIZE_RATIO_THR,
#    search_parallel_min_name_match    => $DEFAULT_NAME_MATCH_THR,
#    search_parallel_weight_size_ratio => $DEFAULT_SIZE_RATIO_WEIGHT,
#    search_parallel_weight_name_match => $DEFAULT_NAME_MATCH_WEIGHT
);

# default sentence aligner method for all parallel documents

# our $DEFAULT_ALIGNER = 'hunalign';
our $DEFAULT_ALIGNER = 'bisent-cautious';

## default alignment parameters:
## - search paramaters for finding parallel documents
## - aligner method

our %ALIGNPARA = %DEFAULT_SEARCH_PARA;
$ALIGNPARA{method} = $DEFAULT_ALIGNER;


=head1 FUNCTIONS

=head2 C<find_corpusfiles>

Returns a list of corpusfile resources within a given subtree.

=cut

sub find_corpusfiles {
    my $corpus    = shift;

    ## query the meta database
    my $response = LetsMT::WebService::get_meta(
        $corpus,
        'resource-type'  => 'corpusfile',
        type             => 'recursive'
    );

    ## TODO: why do we need to decode once again?
    # $response = decode( 'utf8', $response );

    ## parse the query result (matching files in entry-path)
    my @resources     = ();
    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string($response);
    my @nodes     = $dom->findnodes('//list/entry/@path');
    foreach my $n (@nodes) {
        my $file = $n->to_literal;
        push (@resources, LetsMT::Resource::make_from_storage_path($file) );
    }
    return @resources;
}


=head2 C<resources_type>

Returns resource-type

=cut

sub resource_type {
    my $resource    = shift;

    ## check whether there is metadata for the resource
    my $response = LetsMT::WebService::get_meta( $resource );
    # $response = decode( 'utf8', $response );

    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string( $response );
    my @nodes     = $dom->findnodes('//list/entry');

    if (@nodes){
	return $nodes[0]->findvalue('resource-type');
    }
    return undef;
}


=head2 C<is_file>

Returns 1 if the resource is a file, 0 otherwise

=cut

sub is_file {
    my $resource    = shift;

    ## TODO: is there no easier way of doing this?
    ## - get listing of the whole directory
    ## - find the entry that corresponds to the resource
    ## - check whether that is a file

    my $dir       = dirname($resource->storage_path);
    my $dir_res   = LetsMT::Resource::make_from_storage_path($dir);
    my $response  = LetsMT::WebService::get( $dir_res );
    # $response     = decode( 'utf8', $response );
    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string( $response );
    my @nodes     = $dom->findnodes('//list/entry/name[text()="'.basename($resource).'"]');

    if (@nodes == 1){
	my $parent = $nodes[0]->parentNode;
	return 1 if ($parent->findvalue('@kind') eq 'file');
    }
    return 0;
}



=head2 C<resource_exists>

Returns 1 if the resource exists, 0 otherwise

=cut

sub resource_exists {
    my $resource    = shift;
    my $response  = LetsMT::WebService::get( $resource );
    # $response     = decode( 'utf8', $response );
    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string( $response );
    my @nodes     = $dom->findnodes('//list/entry');
    return 1 if (@nodes);
    return 0;
}


# ###############################################
# ### TODO: this is not used anymore, is it?
# ###############################################

# =head2 C<find_parallel_resources>

# Returns a list of matching resources.
# NOTE: DEPRECATED FUNCTION!

# =cut

# sub find_parallel_resources {
#     my $corpus    = shift;
#     my $resources = shift || [];               # list of resources
#     my %args      = @_ ? @_ : %DEFAULT_SEARCH_PARA;

#     # make sure we have an array of resources
#     unless ( ref($resources) eq 'ARRAY' ) { $resources = [$resources]; }

#     my %parallel = ();

#     # always include already aligned documents
#     if ( @{$resources} ) {
#         foreach my $res ( @{$resources} ) {
# 	    my @aligned = find_aligned_documents($res);
# 	    my $file1   = $res->storage_path;
# 	    foreach my $file2 (@aligned) {
# 		$parallel{$file1}{$file2} =
# 		    &LetsMT::Resource::make_from_storage_path($file2);
# 	    }
#         }
#     }

#     # find documents with identical names
#     if ( @{$resources} && $args{search_parallel} eq 'identical' ) {
#         foreach my $res ( @{$resources} ) {
# 	    my @identical = find_parallel_documents( $corpus, $res );
# 	    my $file1 = $res->storage_path;
# 	    foreach my $file2 (@identical) {
# 		$parallel{$file1}{$file2} =
# 		    &LetsMT::Resource::make_from_storage_path($file2);
# 	    }
#         }
#     }

#     # search similar names
#     else {
#         my %possible = find_all_parallel( $corpus, %args );
#         foreach my $file1 ( keys %possible ) {
#             foreach my $lang ( keys %{ $possible{$file1} } ) {
#                 ## matching document sorted by match-score
#                 my @matches = sort {
#                         $possible{$file1}{$lang}{$b}{match}
#                         <=>
#                         $possible{$file1}{$lang}{$a}{match}
#                     } keys %{ $possible{$file1}{$lang} };
#                 if (@matches) {
#                     $parallel{$file1}{ $matches[0] } =
#                       LetsMT::Resource::make_from_storage_path( $matches[0] );
#                 }
#             }
#         }
#     }

#     return %parallel;
# }


=head2 C<find_translated_resources>

Returns a list of resources that are potential translations
of the given resources. If no resources are given: search for 
all matching corpusfiles.

=cut

sub find_translations {
    my $corpus    = shift;
    my $resources = shift || [];               # list of resources

    ## set parameters (with increasing priority):
    ## - default parameters
    ## - resource-specific parameters
    ## - function-call specific parameters

    my %para = @_;
    my %args = %DEFAULT_SEARCH_PARA;
    my %AlignPara = @{$resources} ? 
	&get_align_parameter( $$resources[0] ) : 
	&get_align_parameter( $corpus );
    foreach (keys %AlignPara){ $args{$_} = $AlignPara{$_}; };
    foreach (keys %para){      $args{$_} = $para{$_};      };


    ## get parallel corpusfiles
    my %parallel = ();

    ## if there are given resources:
    ## search only for those resources (their basename without lang/subdir)
    ## TODO: this might become expensive if there are many resources!
    ## ---> could we simply have an upper limit of resources that we can serve here?
    ##      now: not more than 100 ....
    if (@{$resources}  && (scalar @{$resources} <= 100)){
	my %basepaths = ();
	foreach my $r (@{$resources}){
	    my $base = $r->basename;
	    $basepaths{$base}++;
	}
	foreach my $f (keys %basepaths){
	    &resources_with_identical_names($corpus, \%parallel, $f);
	    # _find_matching_corpusfiles($corpus, \%parallel, $f);
	}
    }

    ## otherwise: search in the entire corpus
    ## TODO: this can be a big query (retrieve all corpusfiles)
    else{

	## trust language links first if there are any
	## (from HTML imports)
	&resources_with_language_links($corpus, \%parallel);

	## secondly: match documents with identical names
	&resources_with_identical_names($corpus, \%parallel);

	## third: some more fuzzy name matching
	##
	#if ($args{search_parallel}=~/with_lang/){
	#    &resources_with_langids( $corpus, \%parallel, %args );
	#}
	if ($args{search_parallel}=~/(similar|fuzzy|with_lang)/){
	    &resources_match_no_lang( $corpus, \%parallel, %args );
	    # &resources_with_similar_names( $corpus, \%parallel, %args );
	}

	# _find_matching_corpusfiles($corpus, \%parallel);
	my %translations = ();
	foreach my $base ( keys %parallel ){
	    my @lang = sort keys %{$parallel{$base}};
	    while (@lang){
		my $src = shift(@lang);
		foreach my $trg (@lang){
		    $translations{$parallel{$base}{$src}}{$parallel{$base}{$trg}} = 
			&LetsMT::Resource::make_from_storage_path($parallel{$base}{$trg});
		}
	    }
	}
	return %translations;
    }

    ## TODO: do we want to do some more fuzzy matching?
    ## --> if there is no translation for a specific file 
    ##     in one of the corpus languages: try to find one?
    ## --> file names that include language names / IDs?
    ## (How can we do that efficient with TokyoTyrant?)

    if ($args{search_parallel}=~/(similar|fuzzy|with_lang)/){
	&resources_match_no_lang( $corpus, \%parallel, %args );
	# &resources_with_similar_names( $corpus, \%parallel, %args );
	# &_add_similar_corpusfiles( $corpus, \%parallel, %args );
    }

    my %translations = ();
    foreach my $r (@{$resources}){
	my $base = $r->basename;
	my $path = $r->storage_path;
	my $src  = $r->language;
	if (exists $parallel{$base} ){
	    foreach my $trg (keys %{$parallel{$base}}){
		next if ($trg eq $src);
		## only one direction! TODO: is this OK?
		if (exists $translations{$parallel{$base}{$trg}}){
		    next if (exists $translations{$parallel{$base}{$trg}}{$path});
		}
		$translations{$path}{$parallel{$base}{$trg}} = 
		    &LetsMT::Resource::make_from_storage_path($parallel{$base}{$trg});
	    }
	}
    }
    return %translations;
}




## MOVED TO LetsMT::Align::Documents


# ## try to find corpus files with similar names
# ## for languages that do not have a match yet in the given 
# ## hash of parallel documents

# sub _add_similar_corpusfiles{
#     my $corpus   = shift;
#     my $parallel = shift || {};
#     my %args     = @_;

#     return 0 unless (keys %{$parallel});


#     ## get all registered languages in the corpus

#     my $response  = &LetsMT::WebService::get_meta( $corpus );
#     $response     = decode( 'utf8', $response );
#     my $XmlParser = new XML::LibXML;
#     my $dom       = $XmlParser->parse_string( $response );
#     my @nodes     = $dom->findnodes('//list/entry');
#     my @langs     = split( /,/, $nodes[0]->findvalue('langs') );


#     ## for each file base in parallel: check whether a language is missing
#     ## and collect all those languages

#     my %missing = ();
#     foreach my $f (keys %{$parallel}){
# 	my $filebase = basename($f);
# 	$filebase =~s/\.xml$//;
# 	next unless ($filebase=~/\p{L}/);  # skip names without any letters
# 	foreach my $l (@langs){
# 	    $missing{$l}++ unless (exists $$parallel{$f}{$l});
# 	}
#     }


#     ## get all files for all languages with missing documents

#     my %query = ( 'resource-type'  => 'corpusfile',
# 		  type             => 'recursive' );

#     my $slot = $corpus->slot;
#     my $branch = $corpus->user;
#     my %corpusfiles = ();
#     foreach my $l (keys %missing){

# 	## make the language-specific resource
# 	my $langres = LetsMT::Resource::make( $slot, $branch, 'xml/'.$l );

# 	# query the database
# 	my $response  = LetsMT::WebService::get_meta( $langres, %query );
# 	$response     = decode( 'utf8', $response );
# 	my %files     = ();
# 	my $XmlParser = new XML::LibXML;
# 	my $dom       = $XmlParser->parse_string($response);
# 	my @nodes     = $dom->findnodes('//list/entry/@path');

# 	$corpusfiles{$l} = [];
# 	foreach my $n (@nodes) {
# 	    my @path = split( /\/+/, $n->to_literal );
# 	    shift(@path); # slot
# 	    shift(@path); # branch
# 	    shift(@path); # xml
# 	    shift(@path); # lang
# 	    if (@path){
# 		$path[-1]=~s/\.xml$//;
# 		push(@{$corpusfiles{$l}},join('/',@path));
# 	    }
# 	}
#     }

#     ## run through the document base names again
#     ## and find similar files for the languages that are missing
#     my $count = 0;
#     foreach my $f (keys %{$parallel}){

# 	# my $filebase = basename($f);
# 	# my $filedir  = dirname($f);
# 	my $filebase = $f;
# 	$filebase =~s/\.xml$//;
# 	next unless (basename($filebase)=~/\p{L}/);  # skip file names without any letters

# 	foreach my $l (@langs){
# 	    next if (exists $$parallel{$f}{$l});
# 	    next unless (@{$corpusfiles{$l}});
# 	    my @matches = amatch( $filebase, @{$corpusfiles{$l}} );
# 	    # more than 1? sorting according to distance!
# 	    # see https://metacpan.org/pod/String::Approx
# 	    if ($#matches){
# 		my %dist;
# 		@dist{@matches} = map { abs } adistr( $filebase, @matches );
# 		@matches = sort { $dist{$a} <=> $dist{$b} } @matches;
# 	    }
# 	    if (@matches){
# 		$matches[0] .= '.xml';
# 		$$parallel{$f}{$l} = join( '/',( $slot, $branch, 'xml', $l, $matches[0]) );
# 		$count++;
# 	    }
# 	}
#     }
#     return $count;
# }

# sub _find_matching_corpusfiles{
#     my $corpus   = shift;
#     my $parallel = shift || {};
#     my $filename = shift;

#     ## query the meta database
#     my %query = ( 'resource-type'  => 'corpusfile',
# 		  type             => 'recursive' );
#     $query{'ENDS_WITH__ID_'} = $filename if ($filename);
#     my $response = LetsMT::WebService::get_meta( $corpus, %query );
#     $response = decode( 'utf8', $response );

#     ## parse the query result (matching files in entry-path)
#     my %files     = ();
#     my $XmlParser = new XML::LibXML;
#     my $dom       = $XmlParser->parse_string($response);
#     my @nodes     = $dom->findnodes('//list/entry/@path');

#     foreach my $n (@nodes) {
#         my $file     = $n->to_literal;
#         my $newres   = LetsMT::Resource::make_from_storage_path($file);
# 	my $lang     = $newres->language;
# 	my $basename = $newres->basename;
#         unless ( $filename && ($basename ne $filename) ) {
# 	    $$parallel{$basename}{$lang} = $file;
#         }
#     }
#     return $parallel;
# }




=head2 C<find_parallel_documents>

 @docs = LetsMT::Corpus::find_parallel_documents ($corpus, $resource)

Input parameters:

=over 2

=item C<$corpus>

Resource object for the selected corpus.

=item C<$resource>

Resource for which matching documents need to be found.

=back

Result:
A list of resources.

=cut

sub find_parallel_documents {
    my $corpus   = shift;
    my $resource = shift;

    my $StoragePath = $resource->storage_path;
    my $basename    = $resource->basename;

    ## query the meta database
    my $response = LetsMT::WebService::get_meta(
        $corpus,
        'resource-type'  => 'corpusfile',
        'ENDS_WITH__ID_' => $basename,
        type             => 'recursive'
    );

    ## TODO: why do we need to decode once again?
    # $response = decode( 'utf8', $response );

    ## parse the query result (matching files in entry-path)
    my @files     = ();
    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string($response);
    my @nodes     = $dom->findnodes('//list/entry/@path');
    foreach my $n (@nodes) {
        my $file = $n->to_literal;
        ## check whether the new resource really has an identical file name
        my $newres = LetsMT::Resource::make_from_storage_path($file);
        if ( $newres->basename eq $basename ) {
            push( @files, $file ) if ( $file ne $StoragePath );
        }
    }
    return @files;
}


=head2 C<find_aligned_documents>

=cut

sub find_aligned_documents {
    my $resource = shift;

    my $StoragePath = $resource->storage_path;
    my $basename    = $resource->basename;

    ## query the meta database
    my $response = LetsMT::WebService::get_meta( $resource );

    ## TODO: why do we need to decode once again?
    # $response = decode( 'utf8', $response );

    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string( $response );
    my @nodes     = $dom->findnodes('//list/entry');

    my $repo = $resource->slot . '/' . $resource->user;

    my @files = ();
    foreach my $n (@nodes) {
        my @aligned = split( /,/, $n->findvalue('aligned_with') );
        map( $_ = $repo . '/' . $_, @aligned );
        return @aligned;
    }
}


=head2 C<find_sentence_aligned>

Search for all sentence alignment files.

Returns a hash reference of aligned documents.

=cut

sub find_sentence_aligned {
    my $corpus = shift;
    my $args = shift;

    # ensure $args points to a hash
    $args = {} unless (ref($args) eq 'HASH');

    my $files  = {};

    # read meta data or search for 'sentalign'
    my $response;
    if ($corpus->type eq 'xces') {
        $response = LetsMT::WebService::get_meta( $corpus, %{$args} );
    }
    else{
        $response = LetsMT::WebService::get_meta(
            $corpus,
            'resource-type' => 'sentalign',
            type            => 'recursive',
            action          => 'list_all',
            %{$args}
        );
    }

    ## TODO: why do we need to decode once again?
    # $response = decode( 'utf8', $response );

    my $repo = $corpus->slot . '/' . $corpus->user;

    ## parse the query result (matching files in entry-path)

    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string( $response );
    my @nodes     = $dom->findnodes('//list/entry');
    foreach my $n (@nodes) {
        my $algfile  = $n->findvalue('@path');
        my ($srcdoc) = $n->findvalue('source-document');
        my ($trgdoc) = $n->findvalue('target-document');
        $$files{ $repo . '/' . $srcdoc }{ $repo . '/' . $trgdoc } = $algfile;
        $$files{ $repo . '/' . $trgdoc }{ $repo . '/' . $srcdoc } = $algfile;
    }
    return $files;
}


=head2 C<find_all_parallel>

 $parallel = LetsMT::Corpus::find_all_parallel ($corpus)

Find all parallel documents in C<$corpus>.

Returns a hash reference.

NOTE: THIS MAY CAUSE TROUBLE WITH BIG REPOSITORIES THAT INCLUDE MANY FILES
---> PROBABLY DON'T WANT TO USE THIS IN GENERAL ...

=cut


###############################################
## TODO: should we get rid of this function?
##       it is still used by LetsMT::Admin (and letsmt_admin)
###############################################

sub find_all_parallel {
    my $corpus = shift;
    my %args   = @_;

    my $size_weight = $args{search_parallel_weight_size_ratio}
      ||      $DEFAULT_SEARCH_PARA{search_parallel_weight_size_ratio};
    my $name_weight = $args{search_parallel_weight_name_match}
      ||      $DEFAULT_SEARCH_PARA{search_parallel_weight_name_match};

    my $size_threshold = $args{search_parallel_min_size_ratio}
      ||         $DEFAULT_SEARCH_PARA{search_parallel_min_size_ratio};
    my $name_threshold = $args{search_parallel_min_name_match}
      ||         $DEFAULT_SEARCH_PARA{search_parallel_min_name_match};

    my $parallel = {};

    ## find all sentence alignment files
    ## (this is better than trusting the aligned_with field because
    ##  sentence alignment may be deleted without updating the aligned_with
    ##  field in the metadata of previously aligned documents)

    my $aligned = find_sentence_aligned($corpus) unless ( $args{skip_aligned} );

    ## query the meta database to get ALL corpus files
    ## TODO: response can be quite big!!!!!!

    my $response = LetsMT::WebService::get_meta(
        $corpus,
        'resource-type' => 'corpusfile',
        type            => 'recursive',
        action          => 'list_all'
    );

    ## TODO: why do we need to decode once again?
    # $response = decode( 'utf8', $response );

    ## parse the query result (matching files in entry-path)
    my %files     = ();
    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string($response);
    my @nodes     = $dom->findnodes('//list/entry');
    foreach my $n (@nodes) {
        my $file = $n->findvalue('@path');
        $files{$file}{lang}     = $n->findvalue('language');
        $files{$file}{size}     = $n->findvalue('size');
        $files{$file}{basename} = basename($file);

        ##---------------------------
        ## OLD: read 'aligned_with' to store already aligned documents
        ## NOW: use the find_sentence_aligned function above ....
        ##---------------------------
        # my @aligned = split(/,/,$n->findvalue('aligned_with'));
        # my $repo = $corpus->slot . '/' . $corpus->user;

        # # store already aligned file names
        # foreach (@aligned){
        #     $files{$file}{aligned}{$repo.'/'.$_} = 1;
        # }
    }

    ## list of files names
    my @list = sort keys %files;

    ## run through the list and thry to match all possible combinations
    while (@list) {
        my $file1 = shift @list;
        next unless (length $file1);    # no empty names!

        foreach my $file2 (@list) {
            next unless (length $file2);
            next if ( $files{$file1}{lang} eq $files{$file2}{lang} );

            my $lang1 = $files{$file1}{lang};
            my $lang2 = $files{$file2}{lang};

            ##=============================================================
            ## 0) already aligned file pairs --> classify as perfect match
            ##    (except skip_aligned is set)
            unless ( $args{skip_aligned} ) {
                if ( exists $$aligned{$file1} ) {
                    if ( exists $$aligned{$file1}{$file2} ) {
                        $$parallel{$file1}{$lang2}{$file2}{match}   = 1;
                        $$parallel{$file2}{$lang1}{$file1}{match}   = 1;
                        $$parallel{$file1}{$lang2}{$file2}{aligned} = 1;
                        $$parallel{$file2}{$lang1}{$file1}{aligned} = 1;
                        next;
                    }
                }
            }

            ##=============================================================
            ## 1) identical files names --> perfect match!!!
            if ( $file1 eq $file2 ) {
                $$parallel{$file1}{$file2} = 1;
                last;
            }

            # next if ($name_threshold == 1);

            ##=============================================================
            ## 2) try to match file names and compute size ratios

            ## corpus size ratio (nr of sentences)
            my $size_ratio = 0;
            if ( $files{$file1}{size} && $files{$file2}{size} ) {
                $size_ratio =
                    $files{$file1}{size} > $files{$file2}{size}
                  ? $files{$file2}{size} / $files{$file1}{size}
                  : $files{$file1}{size} / $files{$file2}{size};
            }
            next if ( $size_ratio < $size_threshold );

            my $len1       = length($file1);
            my $len2       = length($file2);
            my $name_ratio = $len1 > $len2 ? $len2 / $len1 : $len2 / $len1;

            ##-------------------------------------------------------------
            ## 2a) file base names match (but not directories)
            if ( $files{$file1}{basename} eq $files{$file2}{basename} ) {
                next if ( $name_ratio < $name_threshold );

                $$parallel{$file1}{$lang2}{$file2}{name_match} = $name_ratio;
                $$parallel{$file1}{$lang2}{$file2}{size_match} = $size_ratio;

                ## some simple interpolation with size ratio
                ## (give more weight to name matching!)
                $$parallel{$file1}{$lang2}{$file2}{match} =
                  $name_weight * $name_ratio + $size_weight * $size_ratio;

                ## save also the other way around
                $$parallel{$file2}{$lang1}{$file1}{size_match} =
                  $$parallel{$file1}{$lang2}{$file2}{size_match};

                $$parallel{$file2}{$lang1}{$file1}{name_match} =
                  $$parallel{$file1}{$lang2}{$file2}{name_match};

                $$parallel{$file2}{$lang1}{$file1}{match} =
                  $$parallel{$file1}{$lang2}{$file2}{match};

                next;
            }

            ##-------------------------------------------------------------
            ## 2b) get string difference and match language IDs

            my $base1 = $files{$file1}{basename};
            my $base2 = $files{$file2}{basename};

            ## if the file basenames include language IDs:
            ##   save the file pair as possible candidate

            if ( _match_lang( $files{$file1}{lang}, $base1 ) ) {
                if ( _match_lang( $files{$file2}{lang}, $base2 ) ) {

                    ## get the remaining string difference between
                    ## the file base names
                    ## (Note: _match_lang removes language ID's)
                    my ( $diff1, $diff2 ) = infix_diff( $base1, $base2 );

                    my $base_len1 = length( $files{$file1}{basename} );
                    my $base_len2 = length( $files{$file2}{basename} );

                    ## the score is 1 - ratio between the lengths
                    ## of the non-language parts and the lengths
                    ## of the file base names
                    if ( $base_len1 || $base_len2 ) {
                        my $lang1 = $files{$file1}{lang};
                        my $lang2 = $files{$file2}{lang};

                        my $score =
                          1 -
                          ( length($diff1) + length($diff2) ) /
                          ( $base_len1 + $base_len2 );
                        $score *= $name_ratio;

                        next if ( $score < $name_threshold );

                        $$parallel{$file1}{$lang2}{$file2}{name_match} = $score;
                        $$parallel{$file1}{$lang2}{$file2}{size_match} =
                          $size_ratio;

                        ## again: interpolate this with the size ratio
                        $$parallel{$file1}{$lang2}{$file2}{match} =
                          $name_weight * $score + $size_weight * $size_ratio;

                        $$parallel{$file2}{$lang1}{$file1}{size_match} =
                          $$parallel{$file1}{$lang2}{$file2}{size_match};

                        $$parallel{$file2}{$lang1}{$file1}{name_match} =
                          $$parallel{$file1}{$lang2}{$file2}{name_match};

                        $$parallel{$file2}{$lang1}{$file1}{match} =
                          $$parallel{$file1}{$lang2}{$file2}{match};
                    }
                }
            }
        }
    }
    ## return possibly matching files (together with match score) ....
    return %{$parallel};
}




=head2 C<find_resources>

 @files = LetsMT::Corpus::find_resources ($corpus [,%args] )

Returns an array of resources within the branch of $corpus

=cut

sub find_resources {
    my $corpus = shift;
    my $args = shift;

    # ensure $args points to a hash
    $args = {} unless (ref($args) eq 'HASH');

    # read meta data or search for 'sentalign'
    my $response = LetsMT::WebService::get_meta(
        $corpus,
        type => 'recursive',
        %{$args}
    );

    ## TODO: why do we need to decode once again?
    # $response = decode( 'utf8', $response );

    ## parse the query result (matching files in entry-path)

    my @files     = ();
    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string( $response );
    my @nodes     = $dom->findnodes('//list/entry');
    foreach my $n (@nodes) {
        push( @files, $n->findvalue('@path') );
    }
    return @files;
}




=head2 C<get_import_parameter>

 my %para = get_import_parameter ($resource)

Returns a hash of import parameters.

It will set default parameters and will try to overwrite them with:
 - user-specific parameters
 - type-specific parameters (meta of slot/branch/uploads/type)
 - resource-specific parameters (meta of path/to/resource metadata)

Possible parameters are:

 splitter ..... text splitter (sentence boundary detection)
 tokenizer .... tokenizer
 normalizer ... comma-separated chain of text normalizers

Special parameters for PDF:

 mode .................... layout|raw|standard (default=layout)

=cut

sub get_import_parameter {
    my $resource = shift;
    my $para = shift || {};

    my $user    = $resource->user;
    my $doctype = $resource->type();
    my $corpus = LetsMT::Resource::make(
        $resource->slot,
        $resource->user,
    );
    my $uploads = LetsMT::Resource::make(
        $resource->slot,
        $resource->user,
        'uploads'
    );
    my $prefix  = 'ImportPara_';

    # load parameters from various levels:
    # 1) user-specific
    # 2) corpus-specifc (metadata in uploads)
    # 3) resource-specifc

    &get_user_parameter( $user, $prefix, $para, $doctype );
    &get_resource_parameter( $corpus,   $prefix, $para, $doctype );
    &get_resource_parameter( $uploads,  $prefix, $para, $doctype );
    &get_resource_parameter( $resource, $prefix, $para, $doctype );
    return %{$para};
}


=head2 C<get_align_parameter>

 my %para = get_align_parameter ($resource)

Returns a hash of alignment parameters.

It will set default parameters and will try to overwrite them with:
 - user-specific parameters
 - corpus-specific parameters (meta of slot/branch/uploads metadata)
 - resource-specific parameters (meta of path/to/resource metadata)

Possible parameters for finding parallel documents:

    search_parallel ........................ identical|similar
    search_parallel_min_size_ratio ......... [0.0,1.0]
    search_parallel_min_name_match ......... [0.0,1.0]
    search_parallel_weight_size_ratio ...... [0.0,1.0]
    search_parallel_weight_name_match ...... [0.0,1.0]

Possible parameters for sentence alignment:

    method ...... one-to-one|GaleChurch|hunalign|bisent

For the Gale & Church aligner:

    mean ........... mean length-diff distribution (default=1)
    variance ....... variance of length-diff distribution (default=6.8)
    search_window .. max distance from diagonal (default=50)
    pillow ......... [0|1] 1 = create pillow-shaped search space
                           (default=1)

For hunalign (see hunalign for possible parameters):

    dic ............ path to bilingual dictionary (default: empty dic)
    para ........... hunalign parameters (default: '-realign')

Default hunalign parameter for bisent: 'realign -cautious'

=cut

sub get_align_parameter {
    my ($resource) = @_;

    # initialize parameters with default settings
    my %para = %ALIGNPARA;

    my $prefix  = 'AlignPara_';
    my $user    = $resource->user;

    my $corpus = LetsMT::Resource::make(
        $resource->slot,
        $resource->user
    );
    my $uploads = LetsMT::Resource::make(
        $resource->slot,
        $resource->user,
        'uploads'
    );

    # overwrite them with user/corpus/resource-specific settings
    &get_user_parameter( $user, $prefix, \%para );
    &get_resource_parameter( $corpus,   $prefix, \%para );
    &get_resource_parameter( $uploads,  $prefix, \%para );
    &get_resource_parameter( $resource, $prefix, \%para );

    return %para;
}


=head2 C<get_user_parameter>

=cut

sub get_user_parameter {
    my $user   = shift;          # name of the user
    my $prefix = shift;          # key prefix in metadata
    my $para   = shift || {};    # hash-reference (result)
    my $type   = shift;          # optional document type

    my $xml = &LetsMT::WebService::get_group($user, $user, undef,
					     action => 'showinfo');

    return $para if ($xml=~/500 Can\'t connect/);
    my $data = XMLin($xml);
    if ( ref($data) eq 'HASH' ) {
        if ( ref( $$data{list} ) eq 'HASH' ) {
            if ( ref( $$data{list}{entry} ) eq 'HASH' ) {
                foreach my $key ( keys %{ $$data{list}{entry} } ) {
		    if ( $key =~ /^$prefix(.*)$/ ) {
                        $$para{$1} = $$data{list}{entry}{$key};
		    }
		}
	    }
	}
    }
    return $para;
}


=head2 C<get_resource_parameter>

Return parameters stored in the metadata record attached to $resource.
Parameters are all key-value pairs for which the key starts with $prefix
($prefix will be deleted!).

=cut

sub get_resource_parameter {
    my $resource = shift;          # resource object
    my $prefix   = shift;          # key prefix in metadata
    my $para     = shift || {};    # hash-reference (result)
    my $type     = shift;          # optional document type

    my $response = &LetsMT::WebService::get_meta($resource);

    return $para if ($response=~/500 Can\'t connect/);
    my $data = XMLin($response);
    if ( ref($data) eq 'HASH' ) {
        if ( ref( $$data{list} ) eq 'HASH' ) {
            if ( ref( $$data{list}{entry} ) eq 'HASH' ) {
                foreach my $key ( keys %{ $$data{list}{entry} } ) {
                    if ( $key =~ /^$prefix(.*)$/ ) {
                        $$para{$1} = $$data{list}{entry}{$key};
                    }

                    # if a doc type is given: check if a doctype-specific
                    # parameter is given
                    if ($type) {
                        if ( $key =~ /^$prefix$type\_(.*)$/ ) {
                            $$para{$1} = $$data{list}{entry}{$key};
                        }
                    }
                }
            }
        }
    }
    return $para;
}


sub _match_lang {
    my $iso2 = shift;
    my $iso3 = iso639_TwoToThree($iso2);
    my $lang = iso639_ThreeToName($iso3) || 'unknown';

    ## match language ID's and remove them
    ## (.*?) --> remove last matching one
    return 1 if ( $_[0] =~ s/$lang(.*?)$/$1/i );
    return 1 if ( $_[0] =~ s/$iso3(.*?)$/$1/i );
    return 1 if ( $_[0] =~ s/$iso2(.*?)$/$1/i );
    return 0;
}


1;

#
# This file is part of LetsMT! Resource Repository.
#
# LetsMT! Resource Repository is free software: you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# LetsMT! Resource Repository is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with LetsMT! Resource Repository.  If not, see
# <http://www.gnu.org/licenses/>.
#
