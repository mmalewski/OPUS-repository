package LetsMT::Import::tar;

=head1 NAME

LetsMT::Import::tar - import handler for C<tar> archives

=cut

use strict;
use parent 'LetsMT::Import::Generic';

use utf8;
use File::Basename qw/basename dirname/;
use Data::Dumper;
use XML::LibXML;
use Encode qw(encode decode decode_utf8 is_utf8);

use LetsMT::Tools;
use LetsMT::WebService;
use LetsMT::Import::Archive;


=head1 CONSTRUCTOR

=cut

sub new {
    my $class = shift;
    my %self  = @_;
    bless \%self, $class;
    return \%self;
}


=head1 METHODS

=head2 C<validate>

=cut

sub validate {
    my $self  = shift;
    my ($resource,$meta_resource) = @_;

    my @errors = grep {/^tar: /} @{
        &LetsMT::Tools::scrape_cmd_out_err( 
             'tar --warning=no-unknown-keyword -t',
             &_file_arg( $resource->local_path ) )
        };
    if ( scalar @errors ) {
        return [ [ $resource, import_log => 'failed to validate as tar' ] ];
    }
    else {
        return [];
    }
}


=head2 C<convert>

=cut

sub convert {
    my $self = shift;
    my ( $resource, $importer, $meta_resource ) = @_;

    # Get requested resource if necessary
    if ( ( !-e $resource->local_path ) || $self->{-always_fetch} ) {
        return 0 unless ( &LetsMT::WebService::get_resource($resource) );
    }

    my @new_resources;

    # initialize archive extraction
    my ($resource_home, $local_home) = 
        $self->initialize_import($resource,$meta_resource);

    # unpack the tar archive

    ## TODO: do we need this?
    local $ENV{LC_ALL} = 'en_US.UTF-8';
    my $cmd_reader
        = &LetsMT::Tools::cmd_out_reader( 'tar --warning=no-unknown-keyword -xv',
        &_file_arg( $resource->local_path ),
        '-C',
        &safe_path( $local_home ) );

    my @done = @{$self->{success}};


    # run through all unpacked resources and import them

    while ( my $exfile = &$cmd_reader ) {
        chomp $exfile;
	$exfile = &utf8_to_perl($exfile);
        next if ($exfile =~ /\/$/ );              # skip directories
	next if (basename($exfile)=~/^\./);       # skip files starting with .
	next if grep($_ eq $exfile,@done);        # skip files that have been done already

	# resource object for extracted file
	my $ex_resource = $resource->clone;
	$ex_resource->path( join( '/', $resource_home, $exfile ) );

	# metadata object for extracted file (only if meta_resource exists)
	my $exmeta_resource = $meta_resource ? $ex_resource : undef;

	my $cex_resources = 
	    $importer->convert_resource($ex_resource,$exmeta_resource);

	# update metadata information (if meta_resource exists)
	$self->update_import_meta($meta_resource, $exfile, $cex_resources);

	# add all new resources to our list of imported files
	if (ref($cex_resources) eq 'ARRAY'){
	    # my $origin = &utf8_to_perl( $resource->path.':'.$exfile );
	    my $origin = $resource->path.':'.$exfile;
	    foreach my $cex_resource (@$cex_resources) {
		push @new_resources, $cex_resource;
		&LetsMT::WebService::post_meta(
		    $cex_resource->{resource},
		    "imported_from" => $origin );
	    }
        }
    }
    return \@new_resources;
}





sub initialize_import{
    my $self=shift;
    my ($resource,$meta_resource) = @_;

    my $resource_path = dirname($resource->path);
    # $resource_path =~s/\.[^.]+(\.gz)?$// or $resource_path .= '.extracted';
    my $homedir_resource = $resource->clone;
    $homedir_resource->path( $resource_path );

    my $local_path = $homedir_resource->local_path;
    &LetsMT::Tools::mkdir( $local_path );

    # delete previous import counts
    # and safe extraction homedir 
    # to make metadata for extracted files accessible

    $self->{success}     = [] unless (ref($self->{success}) eq 'ARRAY');
    $self->{empty}       = [] unless (ref($self->{empty}) eq 'ARRAY');
    $self->{failed}      = [] unless (ref($self->{failed}) eq 'ARRAY');

    $self->{countOK}     = 0 unless ($self->{countOK});
    $self->{countEmpty}  = 0 unless ($self->{countEmpty});
    $self->{countFailed} = 0 unless ($self->{countFailed});

    if ($meta_resource){
	# my $response = LetsMT::WebService::get_meta( $meta_resource );
	# $response = decode( 'utf8', $response );
	# my $XmlParser = new XML::LibXML;
	# my $dom       = $XmlParser->parse_string($response);
	# my @nodes     = $dom->findnodes('//list/entry');
	# if (@nodes){
	#     ## status = 're-import'? --> start from scratch!
	#     ## TODO: should we even delete old files that had been imported before?
	#     my $status = $nodes[0]->findvalue('status');
	#     $self->{reimport} = 1 if ($status=~/re-?import/);
	#     unless ($self->{reimport}){
	# 	# @{$self->{success}}  = split(/\,/,$nodes[0]->findvalue('import_success'));
	# 	@{$self->{failed}}   = split(/\,/,$nodes[0]->findvalue('import_failed'));
	# 	@{$self->{empty}}    = split(/\,/,$nodes[0]->findvalue('import_empty'));
	# 	$self->{countOK}     = $nodes[0]->findvalue('import_success_count') || 0;
	# 	$self->{countFailed} = $nodes[0]->findvalue('import_failed_count') || 0;
	# 	$self->{countEmpty}  = $nodes[0]->findvalue('import_empty_count') || 0;
	#     }
	# }
        &LetsMT::WebService::post_meta(
             $meta_resource,
             "import_homedir"       => $resource_path);
    }

    ## NEW: make metadata query to find successfully imported files
    ##      instead of storing all of them in one record
    ## WHY? this can be a very long list! We don't want to create a
    ##      huge metadata record

    unless ($self->{status}=~/re-?import/){
	my $slot   = $resource->slot();
	my $branch = $resource->user();
	my $corpus = &LetsMT::Resource::make( $slot, $branch, 'xml' );
	my $path   = $resource->path;

	## query the metadata DB for all files that have been imported from
	## the current resource (this can be quite a long list!)
	my $response = LetsMT::WebService::get_meta( $corpus, 
						     STARTS_WITH_imported_from => $path.":",
						     uid    => $branch,
						     type   => 'recursive',
						     action => 'list_all' );

	## TODO: decode seems to fail sometimes
	## --> use utf8::decode instead to avoid breaking
	## --> find some more principles way to handle unicode ...
	# $response = decode( 'utf8', $response );
	# my $DecodeSuccess = utf8::decode($response);

	## NEW: do this only if decoding succeeds
	# utf8::decode($response);
	# if (utf8::is_utf8($response)){
	    my $XmlParser = new XML::LibXML;
	    my $dom       = $XmlParser->parse_string($response);
	    my @nodes     = $dom->findnodes('//list/entry/imported_from');
	    foreach my $n (@nodes){
		my ( $tarfile, $file ) = split( /\:/, $n->to_literal() );
		## TODO: try again to decode?
		# utf8::decode($file) unless ($DecodeSuccess);
		push( @{$self->{success}}, $file );
	    }
	# }
    }

    return ($resource_path, $local_path);
}

sub update_import_meta{
    my $self      = shift;
    my ($resource,$filename,$imported) = @_;

    # do nothing if no resource is given
    return unless $resource;

#    $filename = &utf8_to_perl($filename);  ## TODO: do we need this?

    ## check whether there is already some metadata about the file
    my $MarkedAsSuccess = grep($_ eq $filename, @{$self->{success}} ) ? 1 : 0;
    my $MarkedAsFailed = grep($_ eq $filename, @{$self->{failed}} ) ? 1 : 0;
    my $MarkedAsEmpty = grep($_ eq $filename, @{$self->{empty}} ) ? 1 : 0;

    ## TODO: those lists can become VERY big
    ##       for some tar files
    ## --> do we need to be careful in registrering every single document?
    ##
    ## NEW: only register failed and empty but not successfully imported files
    ## --> we can get success from the metadata of the successfully imported files
    ##
    ## TODO: should we also ignore empty imports and do not store information about
    ##       them in the database? (so, just store failed imports?)

    if ($imported){
        if (scalar @$imported){
	    if ($MarkedAsFailed || $MarkedAsEmpty){
		&LetsMT::WebService::del_meta(
		     $resource,
		     "import_failed" => $filename,
		     "import_empty" => $filename);
	    }
            # &LetsMT::WebService::put_meta(
            #     $resource,
            #     "import_success" => $filename);
	    push(@{$self->{success}},$filename);
        } else {
	    if ($MarkedAsFailed || $MarkedAsSuccess){
		&LetsMT::WebService::del_meta(
		     $resource,
		     # "import_success" => $filename,
		     "import_failed" => $filename);
	    }
            &LetsMT::WebService::put_meta(
                $resource,
                "import_empty" => $filename);
	    push(@{$self->{empty}},$filename);
        }
    } else {
	if ($MarkedAsEmpty || $MarkedAsSuccess){
	    &LetsMT::WebService::del_meta(
		 $resource,
		 # "import_success" => $filename,
		 "import_empty" => $filename);
	}
        &LetsMT::WebService::put_meta(
            $resource,
            "import_failed" => $filename);
	    push(@{$self->{failed}},$filename);
    }


    ## update counts

    $self->{countOK}     = scalar @{$self->{success}};
    $self->{countFailed} = scalar @{$self->{failed}};
    $self->{countEmpty}  = scalar @{$self->{empty}};

    &LetsMT::WebService::post_meta(
        $resource,
        "import_success_count" => $self->{countOK},
        "import_failed_count"  => $self->{countFailed},
        "import_empty_count"   => $self->{countEmpty}
    );
}


=head1 CLASS METHOD (private)

=head2 C<_file_arg>

=cut

sub _file_arg {
    my ($file) = @_;
    if ( $file =~ /gz$/ ) {
        return '-zf ' . safe_path($file);
    }
    else {
        return '-f ' . safe_path($file);
    }
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
