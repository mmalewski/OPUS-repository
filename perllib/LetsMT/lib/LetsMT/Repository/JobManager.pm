package LetsMT::Repository::JobManager;

=head1 NAME

LetsMT::Repository::JobManager - manager for the job API

=head1 DESCRIPTION

Interacts with the Oracle (Sun) Grid Engine.

=cut

use strict;

use open qw(:std :utf8);

use XML::LibXML;
use File::Basename 'basename';
use File::Temp 'tempfile';
use File::Path;
use Encode qw(decode decode_utf8 is_utf8);


use LetsMT::Repository::MetaManager;
use LetsMT::Resource;
use LetsMT::WebService;
use LetsMT::Tools;
use LetsMT::Repository::Safesys;
use LetsMT::Corpus;
use LetsMT::Align;
use LetsMT::Align::Words;
use LetsMT::Tools::UD;

use Cwd;
use Data::Dumper;
use LetsMT::Repository::Err;
use Log::Log4perl qw(get_logger :levels);


=head1 FUNCTIONS

=head2 C<create_job>

 LetsMT::Repository::JobManager::create_job (
     path     => $path,
     uid      => $uid,
     commands => $commands,
     walltime => $walltime,
 )

Create a job descriptions file with the given command list and walltime
and upload it to the repository at the given path.

Returns: resource object of the created job

=cut

sub create_job {
    my %args = @_;

    my $path     = $args{'path'}     or raise( 12, 'path',         'error' );
    my $user     = $args{'uid'}      or raise( 12, 'user',         'error' );
    my $commands = $args{'commands'} or raise( 12, 'command list', 'error' );
    my $walltime = $args{'walltime'} || 10;
    my $queue    = $args{'queue'}    || 'letsmt';

    push my @cmd_array, map { { "command" => $_ } } $commands;

    # Build hash structure for XML job description
    my $hash_structure = {
        'wallTime' => [ $args{'walltime'} ],
        'queue'    => [ $args{'queue'} ],
        'commands' => @cmd_array,
    };

    # Get parser and write out to XML
    my $xmlParser = XML::Simple->new;
    my $xml       = $xmlParser->XMLout(
        $hash_structure,
        RootName      => 'letsmt-job',
        SuppressEmpty => 1
    );

    # upload xml string as file to repository
    my ( $fh, $file_name ) = tempfile(
        'job_description_XXXXXXXX',
        DIR    => $ENV{UPLOADDIR},
        UNLINK => 1,
    );

    # it seems that 'tempfile' is NOT affected by 'use open' above :-(
    binmode( $fh, ':encoding(utf8)' );

    print $fh $xml;
    close($fh) || raise( 8, 'could not close tmp job description file' );

    my $resource = LetsMT::Resource::make_from_path($path);
    LetsMT::WebService::post_file( $resource, $file_name, uid => $user )
        || raise( 8, 'could not upload job description file');

    # don't wait for cleanup but just remove the job description file 
    unlink($file_name);

    return $resource;
}


=head2 C<job_maker>

 LetsMT::Repository::JobManager::job_maker (
    $command,
    $path_elements,
    $args
 )

Create a job that will create jobs (running $command) for resources in the given path and submit them to the SGE using the letsmt_maker script.

=cut

sub job_maker{
    my ($command,$path_elements,$args) = @_;

    my $slot = shift(@{$path_elements});
    my $branch = shift(@{$path_elements});

    # create a new alignment job
    my $jobfile = join( '/',
        'storage', $slot, $branch,
        'jobs', 'run', @{$path_elements}
    );
    $jobfile .= '.'.$command;

    my $relative_path = join('/',@{$path_elements});

    my $argstr = '';
    foreach (keys %{$args}) {
        next if ($_ eq 'run');
        $argstr .=
            ' ' . &safe_path( $_ ) .
            ' ' . &safe_path( $args->{$_} );
    }

    # create job
    LetsMT::Repository::JobManager::create_job(
        path     => $jobfile,
        uid      => $args->{uid},
        walltime => 5,
        queue    => 'letsmt',
        commands => [
            'letsmt_make'
            . ' -u ' . &safe_path( $args->{uid} )
            . ' -s ' . &safe_path( $slot )
            . ' -p ' . &safe_path( $relative_path )
            . ' '    . &safe_path( $command )
            . $argstr
        ]
    );

    # and submit job
    my $message;
    &submit(
        message => \$message,
        path    => $jobfile,
        uid     => $args->{uid},
    );
    return $jobfile;
}


=head2 C<run>

 LetsMT::Repository::JobManager::run (
    $command,
    $path_elements,
    $args
 )

Create jobs (running $command) for resources in the given path and submit them to the SGE.

=cut

sub run {
    my ($command,$path_elements,$args) = @_;

    if ($command eq 'align'){
        return run_align($path_elements, $args);
    }
    if ($command eq 'detect_translations'){
        return run_detect_translations($path_elements, $args);
    }
    if ($command eq 'detect_unaligned'){
        return run_detect_translations($path_elements, $args, 1);
    }
    if ($command eq 'align_candidates'){
        return run_align_candidates($path_elements, $args);
    }
    if ($command eq 'realign'){
        return run_realign($path_elements, $args);
    }
    if ($command eq 'import'){
        return run_import($path_elements, $args);
    }
    ## activate overwriting 
    if ($command eq 'reimport'){
        return run_import($path_elements, $args, 1);
    }
    if ($command eq 'setup_isa'){
        return run_setup_isa($path_elements, $args);
    }
    if ($command eq 'setup_ida'){
        return run_setup_ida($path_elements, $args);
    }
    if ($command eq 'upload_isa'){
        return run_upload_isa($path_elements, $args);
    }
    if ($command eq 'remove_isa'){
        return run_remove_isa($path_elements, $args);
    }
    return 0;
}




=head2 C<run_detect_translations>

 LetsMT::Repository::JobManager::run_detect_translations (
    $path_elements,
    $args,
    $skip_aligned
 )

Try to find parallel documents and store them as align-candidates
in the metadata of the source corpus files. If skip_aligned is on than
the system will skip those files that are already aligned.

=cut

sub run_detect_translations {
    my $path_elements = shift;
    my $args = shift || {};
    my $skip_aligned = shift || 0;

    my $slot      = shift(@{$path_elements});
    my $branch    = shift(@{$path_elements});

    my $corpus    = LetsMT::Resource::make( $slot, $branch );
    my $resource  = @{$path_elements}
        ? LetsMT::Resource::make(
            $slot, $branch, join( '/', @{$path_elements} )
        )
        : $corpus;


    my @ResList = ( );
    if ( resource_type($resource) eq 'corpusfile' ){
	@ResList = ( $resource );
    }
    ## find all resources in a subtree if resource is not an XML file
    elsif ( $#{$path_elements} ){
	@ResList = &find_corpusfiles( $resource );
    }

    # my %parallel = &find_parallel_resources($corpus,\@resources,%{$args});
    # my %parallel = &find_parallel_resources($corpus,\@resources);
    my %parallel = &find_translations( $corpus, \@ResList, %{$args} );

    # hash of candidates for each resource
    my %candidates = ();
    my %resources  = ();

    my $count = 0;
    foreach my $src (sort keys %parallel) {

	next unless (keys %{$parallel{$src}});
	my $SrcRes = LetsMT::Resource::make_from_storage_path($src);
	my $SrcPath = $SrcRes->path;

	## if skip_aligned: get all aligned files to skip those
	my @aligned = ();
	if ($skip_aligned){
	    my $response  = LetsMT::WebService::get_meta( $SrcRes );
	    $response     = decode( 'utf8', $response );
	    my $XmlParser = new XML::LibXML;
	    my $dom       = $XmlParser->parse_string( $response );
	    my @nodes     = $dom->findnodes('//list/entry');
	    @aligned      = split( /,/, $nodes[0]->findvalue('aligned_with') );
	}

        foreach my $trg (sort keys %{$parallel{$src}}) {
	    my $TrgRes = LetsMT::Resource::make_from_storage_path($trg);
	    my $TrgPath = $TrgRes->path;

	    ## skip if we the files is already in the list of aligned resources
            next if ( grep ( $TrgPath eq $_, @aligned ) );

	    ## skip the other translation direction
            if (exists $parallel{$trg}) {
		delete $parallel{$trg}{$src};
	    }
	    $candidates{$SrcPath}{$TrgPath}++;
	    $resources{$SrcPath} = $SrcRes;
	    $count++;
	}
    }
    foreach my $src ( keys %candidates ){
	my $trg = join( ',', sort keys %{$candidates{$src}} );
        &LetsMT::WebService::put_meta(
	    $resources{$src},
	    'align-candidates' => $trg );
    }
    return $count;
}






=head2 C<run_align>

 LetsMT::Repository::JobManager::run_align (
    $path_elements,
    $args
 )

Create sentence alignment jobs for parallel resources in the given path
and submit them to the SGE
 The path should refer to a corpus root or its xml directory.

=cut

sub run_align {
    my $path_elements = shift;
    my $args = shift || {};

    my @sentalign = ();

    my $slot      = shift(@{$path_elements});
    my $branch    = shift(@{$path_elements});

    my $corpus    = LetsMT::Resource::make( $slot, $branch );
    my $resource  = @{$path_elements}
        ? LetsMT::Resource::make(
            $slot, $branch, join( '/', @{$path_elements} )
        )
        : $corpus;

    ## if trg argument is given: assume that we have two 
    ## given resources to be aligned (in the same slot/branch)

    if ($resource && (exists $$args{trg}) ){
	my $SrcRes = $resource;
	my $TrgRes = LetsMT::Resource::make( $slot, $branch, $$args{trg} );
	my $AlgRes = LetsMT::Align::make_align_resource($SrcRes, $TrgRes);
	# delete($$args{trg});

	return &run_align_resource(
	    $slot, $branch,
	    $SrcRes->path(), $TrgRes->path(),
	    $AlgRes->path(),
	    $args
            );
    }

    ## find all resources in a subtree if resource is not an XML file
    my @resources = ( $resource );
    if ($resource->type ne 'xml'){
	@resources = &find_corpusfiles( $resource );
    }

    ## otherwise: look for parallel resources and align all of them
    ## NOTE: this may create lots of align jobs!
    # my %parallel = &find_parallel_resources($corpus,\@resources,%{$args});
    # my %parallel = &find_parallel_resources($corpus,\@resources);
    my %parallel = &find_translations($corpus,\@resources, %{$args});

    my $count = 0;
    my %done  = (); 
    foreach my $src (keys %parallel) {
        foreach my $trg (keys %{$parallel{$src}}) {
            if (exists $done{$src}) {
                next if (exists $done{$src}{$trg});
            }
            my $SrcRes = LetsMT::Resource::make_from_storage_path($src);
            my $TrgRes = LetsMT::Resource::make_from_storage_path($trg);
            # swap if needed (language IDs should be sorted)
            if ( $SrcRes->language() gt $TrgRes->language() ) {
                ( $SrcRes, $TrgRes ) = ( $TrgRes, $SrcRes );
            }
            my $AlgRes = LetsMT::Align::make_align_resource($SrcRes, $TrgRes);

            &run_align_resource(
                $slot, $branch,
                $SrcRes->path(), $TrgRes->path(),
                $AlgRes->path(),
                $args
            );
            $done{$trg}{$src}=1;  ## avoid running the same pair twice
            $count++;
        }
    }
    return $count;
}



=head2 C<run_align_candidates>

 LetsMT::Repository::JobManager::run_align_candidates (
    $path_elements,
    $args
 )

Align documents that have been identified as parallel documents by the name matching heuristics.
Those candidates are stored in the metadata.

=cut

sub run_align_candidates {
    my $path_elements = shift;
    my $args = shift || {};

    my @sentalign = ();

    my $slot      = shift(@{$path_elements});
    my $branch    = shift(@{$path_elements});

    my $corpus    = LetsMT::Resource::make( $slot, $branch );
    my $resource  = @{$path_elements}
        ? LetsMT::Resource::make(
            $slot, $branch, join( '/', @{$path_elements} )
        )
        : $corpus;

    ## check whether there is metadata for the resource
    my $response = LetsMT::WebService::get_meta( $resource );

    ## TODO: why do we need to decode once again?
    $response = decode( 'utf8', $response );

    my $XmlParser = new XML::LibXML;
    my $dom       = $XmlParser->parse_string( $response );
    my @nodes     = $dom->findnodes('//list/entry');

    ## no corpusfile found: search recursively!
    unless (@nodes && ($nodes[0]->findvalue('resource-type') eq 'corpusfile') ) {
	$response = LetsMT::WebService::get_meta(
	    $resource,
	    'ENDS_WITH_align-candidates' => 'xml',
	    type                         => 'recursive',
	    action                       => 'list_all'
	    );
	$dom   = $XmlParser->parse_string( $response );
	@nodes = $dom->findnodes('//list/entry');
    }

    my $count=0;
    foreach my $n (@nodes){
	my @candidates = split( /,/, $n->findvalue('align-candidates') );
	my @aligned    = split( /,/, $n->findvalue('aligned_with') );
        my $srcfile    = $n->findvalue('@path');
	my $SrcRes     = LetsMT::Resource::make_from_storage_path($srcfile);
	foreach my $t (@candidates){
	    my $TrgRes = LetsMT::Resource::make( $slot, $branch, $t );
            my $AlgRes = LetsMT::Align::make_align_resource($SrcRes, $TrgRes);

            &run_align_resource(
                $slot, $branch,
                $SrcRes->path(), $TrgRes->path(),
                $AlgRes->path(),
                $args
            );
            $count++;
	}
    }
    return $count;
}

=head2 C<run_realign>

 LetsMT::Repository::JobManager::run_realign (
    $path_elements,
    $args
 )

Create sentence re-alignment jobs for resources in the given path
and submit them to the SGE.
The path may refer to a directory
(re-run alignment of all existing sentence alignment files below this path)
or a sentence alignment resource
(re-run alignment for this resource).

=cut

sub run_realign {
    my ($path_elements,$args) = @_;

    my @sentalign = ();
    my $path      = join('/',@{$path_elements});

    my $resource = LetsMT::Resource::make_from_storage_path( $path );
    my $files = &find_sentence_aligned( $resource, $args );

    my $count = 0;
    my %done = ();
    foreach my $s (keys %{$files}){
        my $SrcRes = LetsMT::Resource::make_from_storage_path($s);

        foreach my $t (keys %{$$files{$s}}){

            next if ($done{$$files{$s}{$t}});
            my $TrgRes = LetsMT::Resource::make_from_storage_path($t);
            my $AlgRes = 
                LetsMT::Resource::make_from_storage_path($$files{$s}{$t});

            &run_align_resource( $SrcRes->slot, $SrcRes->user,
                                 $SrcRes->path, $TrgRes->path, 
                                 $AlgRes->path, $args );
            $done{ $$files{$s}{$t} } = 1;
            $count++;
        }
    }
    return $count;
}


=head2 C<run_align_resource>

 LetsMT::Repository::JobManager::run_align_resource (
    $slot,
    $branch,
    $srcfile,
    $trgfile,
    $sentalign,
    $args
 )

Create a sentence alignment job for aligning two resources
(slot/branch/srcfile and slot/branch/trgfile)
and submit it to the SGE
C<$sentalign> is used as a basename for the job file
(C<$srcfile> is used if C<$sentalign> is not given).

=cut

sub run_align_resource {
    my ($slot, $branch, $srcfile, $trgfile, $sentalign, $args) = @_;

    # in case sentalign is not defined --> make from (srcfile,$trgfile)
    $sentalign = $srcfile.'-'.basename($trgfile) unless ($sentalign);

    # create a new alignment job
    my $jobfile = join('/','storage',$slot,$branch,
                           'jobs','align',$sentalign);

    # create the JOB file and post it

    my $job_resource = &create_job(
        path     => $jobfile,
        uid      => $args->{uid},
        walltime => 5,
        queue    => 'letsmt',
        commands => [
            'letsmt_align' 
            . ' -u ' . &safe_path( $branch )
            . ' -s ' . &safe_path( $slot )
            . ' -e ' . &safe_path( $srcfile )
            . ' -f ' . &safe_path( $trgfile )
        ],
    );

    # submit the new job via the JOB API

    if (LetsMT::WebService::post_job( $job_resource, 'uid' => $args->{uid} )) {
        my $resource = LetsMT::Resource::make( $slot, $branch, $sentalign );
        LetsMT::WebService::post_meta(
            $resource,
            status => 'waiting in alignment queue',
            uid    => $args->{uid}
        );
        return 1;
    }
    return 0;
}




=head2 C<run_import>

 LetsMT::Repository::JobManager::run_import (
    $path_elements,
    $args
 )

Create import jobs for resources in the given path and submit them to the SGE.
The path may refer to a directory (re-run import for all existing resources below this directory)
or a single resource.

=cut

sub run_import{
    my ($path_elements,$args,$overwrite) = @_;

    my @documents = ();
    my $path      = join('/',@{$path_elements});


    my $resource = LetsMT::Resource::make_from_storage_path($path);
    if (is_file($resource)){
        push(@documents,$path);
    }
    else{
	# create a new importer object for type checking
	# --> check if a certain file type can be handled by the import module!
	# --> we only use suffix-based lookups to avoid importing logfiles etc
	# 
	# (set 'local_root' to avoid creating temp-files)
	my $importer = new LetsMT::Import(local_root => '/tmp');
        my @files    = &find_resources($resource,$args);

        foreach my $p (@files){
            if ($importer->suffix_lookup($p)){
                push(@documents,$p);
            }
        }
    }

    my $count=0;
    foreach my $s (@documents){
        run_import_resource($s,$args,$overwrite);
        $count++;
    }
    return $count;
}


=head2 C<run_import_resource>

 LetsMT::Repository::JobManager::run_import_resource (
    $path_elements,
    $args
 )

Create an import job for a resource given by its path and submit it to the SGE.

=cut

sub run_import_resource{
    my ($path,$args,$overwrite) = @_;

    my @path_elements = split(/\/+/,$path);
    my $slot = shift(@path_elements);
    my $branch = shift(@path_elements);

    # create a new alignment job
    my $jobfile = join('/','storage',$slot,$branch,
                           'jobs','import',@path_elements);

    my $relative_path = join('/',@path_elements);

    # create the job file and post it

    my $job_resource = &create_job(
        path     => $jobfile ,
        uid      => $args->{uid},
        walltime => 5,
        queue    => 'letsmt',
        commands => [
            'letsmt_import'
            . ' -u ' . &safe_path( $branch )
            . ' -s ' . &safe_path( $slot )
            . ' -p ' . &safe_path( $relative_path )
        ],
    );

    # submit the new job via the JOB API

    if ( LetsMT::WebService::post_job( $job_resource, 'uid' => $args->{uid} ) ) {
        my $corpus = LetsMT::Resource::make( $slot, $branch );
        my $res = LetsMT::Resource::make( $slot, $branch, $relative_path );
	if ($overwrite){
	    &LetsMT::WebService::post_meta(
		 $res,
		 status => 'waiting in import queue',
		 "import_success"       => '',
		 "import_failed"        => '',
		 "import_empty"         => '',
		 "import_success_count" => 0,
		 "import_failed_count"  => 0,
		 "import_empty_count"   => 0);
	}
        # LetsMT::WebService::post_meta(
        #     $res,
        #     status => 'waiting in import queue',
        #     uid    => $args->{uid},
        # );
        LetsMT::WebService::del_meta(
            $corpus,
            import_failed => $relative_path,
            uid           => $args->{uid},
        );
        LetsMT::WebService::put_meta(
            $corpus,
            import_queue => $relative_path,
            uid          => $args->{uid},
        );
        return 1;
    }
    return 0;
}


## make a safe name by removing all non-ASCII characters, spaces etc

sub _safe_corpus_name{
    my $name = shift;
    $name=~s/[^a-zA-Z0-9.\-_+]/_/g;
    return $name;
}


## set up IDA for a specific corpus file

sub run_setup_ida {
    my $path_elements = shift;
    my $args = shift || {};

    return 'no valid path given' unless (ref($path_elements) eq 'ARRAY');
    return 'no sentence alignment file given' if (@{$path_elements} < 2);

    my $path       = join('/',@{$path_elements});
    my $WebRoot    = $$args{WebRoot} || '/var/www/html';
    my $IdaFileDir = $$args{IdaFileDir} || $ENV{LETSMTROOT}.'/share/ida';

    my $slot = shift(@{$path_elements});
    my $user = shift(@{$path_elements});

    my $IdaHome = join('/',$WebRoot,'ida',$user,$slot);

    ## path should start with xml
    return 'not in xml-root of your repository' if (shift(@{$path_elements}) ne 'xml');
    my $corpus = join('_',@{$path_elements});
    $corpus-~s/\.xml$//;

    ## make a name without any special characters (basically ASCII only)
    ## TODO: save mapping to original name somewhere
    $corpus=_safe_corpus_name($corpus);

    my $CorpusHome = join('/',$IdaHome,$corpus);
    my $langpair   = shift(@{$path_elements});
    my ($src,$trg) = split(/\-/,$langpair);
    my $file       = join('/',@{$path_elements});

    return 'no valid sentence alignment file' unless ($src && $trg && $file);

    if (! -d $CorpusHome){
	File::Path::make_path($CorpusHome);

	my $resource = LetsMT::Resource::make_from_storage_path( $path, $CorpusHome );
	return "no resource" unless ($resource);

	## check whether a wordalign resource of sent align indeces exists
	my $algres = $resource->clone();
	$algres->base_path('wordalign');
	if (LetsMT::Corpus::resource_exists($algres)){
	    $resource = $algres;
	}

	# get all sentence alignments from the bitext
	&LetsMT::WebService::get_resource($resource, 'archive' => 'no') || return undef;
	open F,"<",$resource->local_path() || return "cannot read resource";
	open O,">$CorpusHome/corpus.$src-$trg" || return "cannot write link file";
	my $srcdoc = undef;
	my $trgdoc = undef;
	my @links = ();
	while (<F>){
	    chomp;
	    if (/fromDoc="(wordalign\/)?([^"]+)"/){ $srcdoc = 'ud/'.$2; }
	    if (/toDoc="(wordalign\/)?([^"]+)"/){ $trgdoc = 'ud/'.$2; }
	    if (/xtargets="([^"]*)"/){ push(@links,$1); }
	    if (/xtargets="([^ ][^ ]*;[^ ][^ ]*)"/){ print O $1,"\n"; }
	}
	close F;
	close O;
	unlink($resource->local_path());

	## TODO: should check that UD files actually exist!
	## or even better: if they don't exists: accept tokenized files!
	## --> good for annotation projection later on ...

	my $srcres = LetsMT::Resource::make( $slot, $user, $srcdoc, $CorpusHome );
	my $trgres = LetsMT::Resource::make( $slot, $user, $trgdoc, $CorpusHome );

	if (LetsMT::Corpus::resource_exists($srcres)){
	    &LetsMT::WebService::get_resource($srcres, 'archive' => 'no') || return "cannot get source UD";
	    &LetsMT::Tools::UD::deprel2db($srcres->local_path(), "$CorpusHome/corpus.$src.db");
	    unlink($srcres->local_path());
	}
	else{
	    ## TODO: get standard XML, tokenize and convert to DB_File
	}
	if (LetsMT::Corpus::resource_exists($trgres)){
	    &LetsMT::WebService::get_resource($trgres, 'archive' => 'no') || return "cannot find target UD";
	    &LetsMT::Tools::UD::deprel2db($trgres->local_path(), "$CorpusHome/corpus.$trg.db");
	    unlink($trgres->local_path());
	}
	else{
	    ## TODO: get standard XML, tokenize and convert to DB_File
	}

	## word alignment
	my $wordalgres = $algres->strip_suffix();
	$wordalgres->base_path('wordalign');
	if (LetsMT::Corpus::resource_exists($wordalgres)){
	    &LetsMT::WebService::get_resource($wordalgres, 'archive' => 'no');
	    &LetsMT::Align::Words::alg2db($wordalgres->local_path(), \@links, "$CorpusHome/corpus.$src-$trg.db");
	    unlink($wordalgres->local_path());
	}

	## finally: create the index.php file
	open IN, "<$IdaFileDir/index.in" || return "cannot read index.in";
	open OUT, ">$CorpusHome/index.php" || return "cannot write index.php";
	while (<IN>){
	    s/%%CORPUSFILE%%/corpus/;
	    s/%%SRC%%/$src/;
	    s/%%TRG%%/$trg/;
	    print OUT $_;
	}
	close IN;
	close OUT;

	return "IDA is now available at http://$ENV{LETSMTHOST}/ida/$user/$slot/$corpus";
    }

    return 'failed to prepare IDA';
}




## set up ISA for a specific corpus file

sub run_setup_isa {
    my $path_elements = shift;
    my $args = shift || {};

    return undef unless (ref($path_elements) eq 'ARRAY');
    return undef if (@{$path_elements} < 2);

    my $WebRoot    = $$args{WebRoot} || '/var/www/html';
    my $IsaFileDir = $$args{IsaFileDir} || $ENV{LETSMTROOT}.'/share/isa';

    my $slot = shift(@{$path_elements});
    my $user = shift(@{$path_elements});

    my $IsaHome = join('/',$WebRoot,'isa',$user,$slot);

    if (! -d $IsaHome){
	system("mkdir -p $IsaHome");
	system("cp -R $IsaFileDir/* $IsaHome/");
    }

    ## path should start with xml
    return undef if (shift(@{$path_elements}) ne 'xml');
    my $corpus = join('_',@{$path_elements});
    $corpus-~s/\.xml$//;

    ## make a name without any special characters (basically ASCII only)
    ## TODO: save mapping to original name somewhere
    $corpus=_safe_corpus_name($corpus);


    my $CorpusHome = join('/',$IsaHome,'corpora',$corpus);
    my $langpair   = shift(@{$path_elements});
    my ($src,$trg) = split(/\-/,$langpair);
    my $file       = join('/',@{$path_elements});
    $file          =~s/\.xml$//;

    return undef unless ($src && $trg && $file);

    ## TODO: this does not feel very safe!
    ## change this from calling a makefile to something else
    ## ---> this should check at least the file names to avoid any problems!


    ## TODO: this is probably not good enough.
    ## some sanity check for file names and strange symbols ...
    $file=~tr/'| $@/____/;

    if (! -d $CorpusHome){
	my $pwd = getcwd();
	chdir($IsaHome);
	system("make SLOT='$slot' USER='$user' SRCLANG='$src' TRGLANG='$trg' FILE='$file' all");
    }
    return "ISA available at http://$ENV{LETSMTHOST}/isa/$user/$slot" if (! -d $CorpusHome);
    return undef;
}


## completely remove ISA for a specific corpus file

sub run_remove_isa {
    my $path_elements = shift;
    my $args = shift || {};

    return undef unless (ref($path_elements) eq 'ARRAY');
    return undef if (@{$path_elements} < 2);

    my $WebRoot    = $$args{WebRoot} || '/var/www/html';
    my $IsaFileDir = $$args{IsaFileDir} || $ENV{LETSMTROOT}.'/share/isa';

    my $slot = shift(@{$path_elements});
    my $user = shift(@{$path_elements});
    my $path = join('/',@{$path_elements});
    $path    =~s/\.xml$/.isa.xml/;

    return undef if (shift(@{$path_elements}) ne 'xml');

    unshift( @{$path_elements},$slot );
    my $corpus = join('_',@{$path_elements});
    $corpus=~s/\.xml$//;

    ## make a name without any special characters (basically ASCII only)
    ## TODO: save mapping to original name somewhere
    $corpus=_safe_corpus_name($corpus);


    my $IsaHome    = join('/',$WebRoot,'isa',$user,$slot);
    my $CorpusHome = join('/',$IsaHome,'corpora',$corpus);
    my $CesFile    = $CorpusHome.'.ces';

    ## uload a copy to safe the alignments
    my $resource = new LetsMT::Resource(
	slot => $slot,
	user => $user,
	path => $path,
	);

    if (-f $CesFile){
	LetsMT::WebService::put_file($resource,$CesFile);
    }

    ## dangerous: remove the whole file system tree ...
    unlink($CesFile) if (-e $CesFile);
    if (-d $CorpusHome){
	rmtree($CorpusHome);
    }
    return "'$corpus' successfully removed from $ENV{LETSMTHOST}/isa/$user/$slot";
}



## upload the sentence alignment file to the repository

sub run_upload_isa {
    my $path_elements = shift;
    my $args = shift || {};

    return undef unless (ref($path_elements) eq 'ARRAY');
    return undef if (@{$path_elements} < 2);

    my $WebRoot    = $$args{WebRoot} || '/var/www/html';
    my $IsaFileDir = $$args{IsaFileDir} || $ENV{LETSMTROOT}.'/share/isa';

    my $slot = shift(@{$path_elements});
    my $user = shift(@{$path_elements});
    my $path = join('/',@{$path_elements});

    return undef if (shift(@{$path_elements}) ne 'xml');

    unshift( @{$path_elements},$slot );
    my $corpus = join('_',@{$path_elements});
    $corpus=~s/\.xml$//;

    ## make a name without any special characters (basically ASCII only)
    ## TODO: save mapping to original name somewhere
    $corpus=_safe_corpus_name($corpus);


    my $IsaHome    = join('/',$WebRoot,'isa',$user,$slot);
    my $CorpusHome = join('/',$IsaHome,'corpora',$corpus);
    my $cesfile    = $CorpusHome.'.ces';

    my $resource = new LetsMT::Resource(
	slot => $slot,
	user => $user,
	path => $path,
	);

    return undef unless (-f $cesfile);
    if (LetsMT::WebService::put_file($resource,$cesfile)){
	return "successfully uploaded ISA alignment file to ".$resource->storage_path;
    }
    return "failed to upload ISA alignment file to ".$resource->storage_path;
}




=head2 C<submit>

 LetsMT::Repository::JobManager::submit (
     path    => $path,
     uid     => $uid,
     message => $message,
 )

Submit a job to the SGE queue.

Returns: an XML-formatted status string.

=cut

sub submit {
    my %args    = @_;
    my $message = $args{message};
    my $path    = $args{path} || raise( 12, "parameter path", 'warn' );
    my $user    = $args{uid};

    my $logger = get_logger(__PACKAGE__);
    $logger->debug( "path: " . $path );

    my $logDir = $ENV{'LETSMTLOG_DIR'} . '/batch_jobs';
    my $workDir = $ENV{'UPLOADDIR'};

    my $jobID   = "job_" . time() . "_" . int( rand(1000000000) );
    my $jobOut  = "$logDir/$jobID.o";
    my $jobErr  = "$logDir/$jobID.e";

    mkdir $workDir if ( !-e $workDir );
    mkdir $logDir  if ( !-e $logDir );

    my $metaDB = new LetsMT::Repository::MetaManager();

    my $safe_path = LetsMT::Tools::safe_path($path);
    my $job = "source $ENV{LETSMTCONF};letsmt_run -d -u $user -p $safe_path -i $jobID;";

    #write location of stderr and stdout logfiles to metadata
    $metaDB->open();
    $metaDB->post(
        $path,
        {
            job_log_out => $jobOut,
            job_log_err => $jobErr
        }
    );
    $metaDB->close();

    my $status = undef;

    ## submit either to SGE ot SLURM
    if ($ENV{LETSMT_BATCHQUEUE_MANAGER} eq 'sge'){
	$status = submit_sge_job($job,$jobID,$workDir,$jobOut,$jobErr);
    }
    else{
	$status = submit_slurm_job($job,$jobID,$workDir,$jobOut,$jobErr);
    }

    $logger->debug( 'Job status:' . $status );

    if ($status) {
        #write meta data
        $metaDB->open();
        $metaDB->post(
            $path, {
                job_status => 'submitted to grid engine with status: ' . $status,
                job_id     => $jobID,
            }
        );
        $metaDB->close();
    }
    else {
        raise( 8, 'could not submit job to grid engine' );
    }

    #write status of submit and job ID back to result reference
    $$message = "submitted job with ID '$jobID'";

    return 1;
}







=head2 C<check_status>

 $status = LetsMT::Repository::JobManager::check_status ( job_id => $jobID, path => $path )

Returns the current status of a job

Returns: true or false

=cut

sub check_status {
    my %args = @_;

    my $message = $args{message};
    my $jobID   = $args{job_id};

    #get jobID from meta data via path/url if path is set
    if ( $args{path} ) {
        $jobID = get_ID_from_path( $args{path} );
    }

    #if jobID was set or could be found in mete data
    if ($jobID) {

	my $status = undef;
	if ($ENV{LETSMT_BATCHQUEUE_MANAGER} eq 'sge'){
	    $status = check_sge_job_status($jobID);
	}
	else{
	    $status = check_slurm_job_status($jobID);
	}
	if ($status){
	    $$message = $status;
	    return 1;
	}
        $$message = 'could not get status xml from qstat';
        return 0;
    }
    else {
        $$message = 'job ID not given or found in meta data';
        return 0;
    }
}


sub get_job_list {
    if ($ENV{LETSMT_BATCHQUEUE_MANAGER} eq 'sge'){
	return get_sge_job_list(@_);
    }
    else{
	return get_slurm_job_list(@_);
    }

}

=head2 C<delete>

 LetsMT::Repository::JobManager::delete (job_id => $jobID, path => $path)

Delete a job, identified by its job ID or the path to the job file, from the grid engine.

Returns: true or false

=cut

sub delete {
    my %args = @_;

    my $message = $args{message};
    my $jobID   = $args{job_id};

    #get jobID from meta data via path/url if set
    if ( $args{path} ) {
        $jobID = get_ID_from_path( $args{path} );
    }

    #if jobID was set or could be found in mete data
    if ($jobID) {
        my $status = undef;

	if ($ENV{LETSMT_BATCHQUEUE_MANAGER} eq 'sge'){
	    $status = delete_sge_job($jobID);
	}
	else{
	    $status = delete_slurm_job($jobID);
	}
	
        #TODO: delete also meta data and old log files!

        get_logger(__PACKAGE__)->debug( 'Status:' . $status );

        if ($status) {
            $$message = $status;
        }
    }
}


=head2 C<get_ID_from_path>

 $id = LetsMT::Repository::JobManager::get_ID_from_path ($path)

Returns the job ID if it is found at the given path

Returns: jobID string

=cut

sub get_ID_from_path {
    my $pathref = shift;
    my $path = join( '/', @{$pathref} );

    my $metaDB = new LetsMT::Repository::MetaManager();
    $metaDB->open();
    my $search_result = $metaDB->get( $path, 'job_id' );
    $metaDB->close();
    unless ($search_result) {
        raise( 11, 'no jobID found in meta data at this path' );
    }

    return $search_result;
}




## SLURM-specific functions


sub submit_slurm_job {
    my ($job,$jobID,$workDir,$jobOut,$jobErr) = @_;

    my ($fh, $filename) = tempfile();
    binmode( $fh, ':encoding(utf8)' );
    print $fh "#!/bin/bash\n";
    print $fh $job,"\n";
    close $fh;

    ## TODO: more options? -t for time limit? mail when finished?

    get_logger(__PACKAGE__)->debug("slurm: sbatch -n 1 -J $jobID -D $workDir -e $jobErr -o $jobOut $filename");
    LetsMT::Repository::Safesys::sys(
        "sbatch -n 1 -J $jobID -D $workDir -e $jobErr -o $jobOut $filename"
    );

    # check if job was submitted
    my $status = undef;
    check_status( message => \$status, job_id => $jobID );
    return $status;
}


sub check_slurm_job_status{
    my $jobID = shift;


    #query for status of the job
    open( STATUS, "squeue -o '%j %i %T' -n $jobID |" )
	or raise( 8, "Can't run program: $!\n" );

    <STATUS>;
    my $output = <STATUS>;
    close STATUS;

    if ($output){
	my ($name,$id,$status) = split(/\s/,$output);
	return wantarray ? ($id,lc($status)) : lc($status);
    }
    return wantarray ? (undef,"no job with ID '$jobID' found") : "no job with ID '$jobID' found";
}


sub get_slurm_job_list{

    #query for status of the job
    open( STATUS, "squeue -o '%j %i %T' |" )
	or raise( 8, "Can't run program: $!\n" );

    my $entries = [];
    <STATUS>;
    while (my $output = <STATUS>){
	my ($name,$id,$status) = split(/\s/,$output);
	push( @$entries, { name => $name, id => $id, status => $status } );
    }
    close STATUS;

    my $result = {
        'path' => 'jobs',
        'entry' => $entries,
    };

    return $result;
}


sub delete_slurm_job{
    my $jobID = shift;

    my ($id,$status) = check_slurm_job_status($jobID);

    if ($id){
	$status = undef;

	#try to delete job
	open( STATUS, "scancel $id |" ) or raise( 8, "Can't run program: $!\n" );
	while (<STATUS>) {
	    $status .= $_;
	}
	close(STATUS);
    }
    return $status;
}




## SGE-specific functions

sub submit_sge_job {
    my ($job,$jobID,$workDir,$jobOut,$jobErr) = @_;

    #submit job
    LetsMT::Repository::Safesys::sys(
        "qsub -N $jobID -S /bin/bash -q letsmt -wd $workDir -e $jobErr -o $jobOut -b y \"$job\""
    );

    # check if job was submitted
    my $status = undef;
    check_status( message => \$status, job_id => $jobID );
    return $status;
}

sub get_sge_job_list{
    ## not implemented ...
}


sub check_sge_job_status{
    my $jobID = shift;

    my $statusXML = undef;

    #query for status of the job
    open( STATUS_XML, "qstat -xml -u $ENV{LETSMTUSER} |" )
	or raise( 8, "Can't run program: $!\n" );
    while (<STATUS_XML>) {
	$statusXML .= $_;
    }
    close(STATUS_XML);

    #parse XML status
    if ($statusXML) {
	my $parser = new XML::LibXML;
	my $doc    = $parser->parse_string($statusXML);

	my $status = $doc->findvalue(
	    '//job_list[JB_name="' . $jobID . '"]/@state'
            );

	return $status;
    }
    return  "no job with ID '$jobID' found";
}


sub delete_sge_job{
    my $jobID = shift;

    my $status = undef;

    #try to delete job
    open( STATUS, "qdel $jobID |" ) or raise( 8, "Can't run program: $!\n" );
    while (<STATUS>) {
	$status .= $_;
    }
    close(STATUS);
    return $status;
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
