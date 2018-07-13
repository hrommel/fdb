#!/usr/bin/perl -w

#
# Heiko Rommel <rommel@suse.de>
# lazy Hackweek project 2011-2018
#
# TODO:
#
# a) define cdvformat and write cdv routines
#

use strict;
use File::stat;
use Time::localtime;
use Digest::SHA1;
use MIME::Base64;
use DBI;
use DBD::Pg qw(:pg_types); 
use utf8; 
use Encode; 
use Getopt::Long;


my $usagemsg = "
manage-fdb.pl [--debug] [--verbose] 
              (--help | --import <STDIN> | --prune_db <STDIN> | --duplicates)
              [--user=<userid>] [--password=<password>] 
              [--host=<host>] [--port=<port>] [--dbname=<dbname>]

	--import:

	read file names with relative path elements from STDIN (one per line)
        and upload the path and name together with some created metadata (see README)

	--prune_db:

	read directory names from STDIN (one per line) and remove entries from
	the database which can not be found in any of the give directories 
        (i.e. after concatenating the directory with the relative path of the 
	element in the database)

	--duplicates:

	find duplicate entries in the database by validating size and checksum but ignoring file name

";


my ($debug, $verbose, $help, $import, $prune_db, $duplicates, $user, $password, $host, $port, $dbname);
my $configfile = $ENV{"HOME"} . "/.fdb.conf"; 
my %config;

GetOptions(
       "debug" => \$debug,
       "verbose" => \$verbose,
       "help" => \$help,
       "import" => \$import,
       "prune_db" => \$prune_db,
       "duplicates" => \$duplicates,
       "user=s" => \$user,
       "password=s" => \$password,
       "host=s" => \$host,
       "port=s" => \$port,
       "dbname=s" => \$dbname,
      ) or die "$usagemsg";

if (defined $help) {
   print $usagemsg;
   exit 0;
}

if (not defined $import and not defined $prune_db and not defined $duplicates) {
   print $usagemsg;
   exit 1;
}

if (defined $debug) {
   $verbose = 1;
}

sub read_config {
   open (FH, '<', $configfile) or return;

   while (<FH>) {
       if (/^\s*(\S+)\s*=\s*"(.*)"/) {
           $config{$1} = $2;
           if (defined $debug) { print "DEBUG: read \"$2\" as value for key \"$1\"\n"; }
       }
       elsif (/^\s*($|#)/) {
       }
       else {
           if (defined $verbose) { print "warning: ignoring configuration line $_"; }
       }
   }

   close (FH);
}

sub sha1sum_file_b64 {
    my $file = shift or return;
    open (FH, '<', $file) or return;

    my $sha1 = Digest::SHA1->new;

    eval { $sha1->addfile(*FH); }; # addfile calls Carp::croak() on read errors - catch that
    if ($@) {
        print "warning: there was an error in sha1sum_file_b64() reading the file \"$file\"\n";
        return;
    }
    my $digest = $sha1->b64digest();

    close (FH);

    if (defined $debug) { print "DEBUG: path=\"$file\" digest=\"$digest\"\n"; }
    return $digest;
}

sub cdv_file_b64 {
    my $file = shift or return;
    my $cdvformat = shift or return;

    open (FH, '<', $file) or return;
    #TODO: compute a content describing vector - for now I just use some bytes to fill 1K in the DB
    my $blob;
    eval { sysread (FH,$blob,512); } ; 
    if ($@) {
        print "warning: there was an error in cdv_file_b64() reading the file \"$file\"\n";
        close (FH);
        return;
    }
    close (FH);

    my $cdv = substr(encode_base64($blob),0,1024);

    if (defined $debug) { print "DEBUG: path=\"$file\" cdv=\"" . substr($cdv,0,33) . "...\"\n"; }
    return $cdv;
}

sub get_type_descriptor {
    my $file = shift or return;
    my $desc;
    my $type;
    my $cdvformat;

    #open (FH, '-|', '/usr/bin/file', '-0', $file) or return;  
    open (FH, '-|', '/usr/bin/file', '-b', $file) or return;  
    while (<FH>) {
        # if (/(.*)\000\s+(.*)/) {
            # $desc = $2;
            $desc = $_;
            $type = undef;

            if ($desc =~ /(image|PC bitmap, Windows|Adobe Photoshop Image|MS Windows icon)/i) { 
                $type = 'picture'; $cdvformat='TODO: property1(4), property2(4), property3(1024)'; 
            }
            elsif ($desc =~ /(video|movie|Microsoft ASF|MPEG sequence|MPEG v4 system|Macromedia Flash|RealMedia file|RIFF.*AVI|Matroska data)/i) { 
                $type = 'movie'; $cdvformat='TODO: property1(4), property2(4), property3(1024)'; 
            }
            elsif ($desc =~ /(audio|MPEG ADTS|RIFF.*WAVE audio)/i) { 
                $type = 'sound'; $cdvformat='TODO: property1(4), property2(4), property3(1024)'; 
            }
            elsif ($desc =~ /(text|document|FORTRAN|PASCAL)/i) { 
                $type = 'document'; $cdvformat='TODO: property1(4), property2(4), property3(1024)'; 
            }
            elsif ($desc =~ /executable|ELF.*LSB/i) { 
                $type = 'executable'; $cdvformat='TODO: property1(4), property2(4), property3(1024)'; 
            }
            elsif ($desc =~ /(archive|gzip compressed data|bzip2 compressed data)/i) { 
                $type = 'archive'; $cdvformat='TODO: property1(4), property2(4), property3(1024)'; 
            }
            elsif ($desc =~ /encrypted/i) { 
                $type = 'crypted'; $cdvformat='TODO: property1(4), property2(4), property3(1024)';
            }
            else { 
                $type = 'binary'; $cdvformat='TODO: property1(4), property2(4), property3(1024)'; 
            }

            if (defined $debug and defined $type) { chomp $desc; print "DEBUG: file=\"$file\" type=\"$type\" desc=\"$desc\"\n"; }
            elsif (not defined $type) {
               print "WARNING: can't decompose \"$_\"\n";
            }
      #}
    }

    close (FH);

    return ($type, $cdvformat);
}

sub insert_type_into_db {
    my $dbh = shift or return;
    my $type = shift or return;
    my $cdvformat = shift or return;
    my $typeid;

    my $job;
   
    $job = $dbh->prepare(q{INSERT INTO types ("type", "cdvformat") VALUES (?, ?)});
    if (defined $verbose) { print "adding type \"$type\"\n"; }
    $job->execute($type, $cdvformat);
    $job->finish();

    $job = $dbh->prepare('SELECT typeid from types WHERE type=?');
    $job->execute($type);
    $typeid = ($job->fetchrow_array())[0]; 
    $job->finish();

    return $typeid;
}


#
# connect to the database
#

read_config();

if (not defined $user) { $user = $config{user}; } 
if (not defined $password) { $password = $config{password}; } 
if (not defined $host) { $host = $config{host}; } 
if (not defined $port) { $port = $config{port}; } 
if (not defined $dbname) { $dbname = $config{dbname}; } 

if (not defined $user or not defined $password or not defined $host or not defined $port or not defined $dbname) {
   print "ERROR: missing values for user, password, host, port or dbname on command line and in configuration file \"$configfile\"\n";
   exit 1;
}

my $dbh = DBI->connect("DBI:Pg:dbname=$dbname;host=$host;port=$port", $user, $password, {'RaiseError' => 1});
my $job;

# ------------------------------- import ------------------------------

if (defined($import)) {

#
# phase 1: read a file list from stdin and gather some stats on each file that are required for database lookup;
#          more expense operations (like determing content type, SHA1SUM und CDPV) will be performed later
#

my %files;

while (<STDIN>) {
   my $path = $_;
   chomp $path;

   my ($dir, $name);
   if ($path =~ /(.*)\/(.*)/) {
       $dir = $1;
       $name = $2;
   }
   else {
      $dir = ".";
      $name = $path;
   }

   if (not -r "$dir/$name") {
       print "warning: can't read file \"$dir/$name\" - skipping\n";
       next;
   }

   $files{$dir}{$name} = {
      'size' => stat($path)->size,
      'mtime' => ctime(stat($path)->mtime)
    }
}

#
# phase 2: prepare the lookup tables for content types and paths
#

#
# step 1: obtain a map of registered content types 
#

my %types_db;
my %cdvformats_db;

$job = $dbh->prepare('SELECT typeid,type,cdvformat from types');
$job->execute();

while (my ($typeid,$type,$cdvformat) = $job->fetchrow_array() ) {
    $types_db{$type} = $typeid;
    $cdvformats_db{$type} = $cdvformat;
    # print "DEBUGX: fetched type \"$type\" with id \"$typeid\"\n";
}

$job->finish();

#
# step 2: obtain a map of knowns path(id)s -
#         in case a path encountered in phase 1 can not be found add it to the database
#

my %paths_db;
my %path_is_new;

$job = $dbh->prepare('SELECT pathid,path from paths');
$job->execute();

while (my ($pathid, $path) = $job->fetchrow_array() ) {
    $paths_db{$path} = $pathid;
    # print "DEBUGX: fetched path \"$path\" with id \"$pathid\"\n";
}

$job->finish();

$job = $dbh->prepare(q{INSERT INTO paths ("path", "path_orig") VALUES (?, ?)});
$job->bind_param(2, undef, { pg_type => DBD::Pg::PG_BYTEA }); 

foreach my $path (keys %files) {
    my $path_utf8 = encode("UTF-8", $path);
    if (not defined $paths_db{$path_utf8}) {
        if (defined $verbose) { print "adding path \"$path_utf8\"\n"; }
        $job->execute($path_utf8, $path);
        $path_is_new{$path} = 1;
    }
    else {
        if (defined $debug) { print "DEBUG: path \"$path_utf8\" already present with id $paths_db{$path_utf8}\n"; }
    }
}

$job->finish();

# read back the pathids that have been created via Postgres counters

$job = $dbh->prepare('SELECT pathid,path from paths');
$job->execute();

while (my ($pathid, $path) = $job->fetchrow_array() ) {
    $paths_db{$path} = $pathid;
}

$job->finish();

#
# phase3: take care of the entries in the table 'files'
#          a) add a record if a matching 2-tuple ($dir,$name) is not present, otherwise:
#          b) update a record if a matching 4-tuple ($dir,$name,$mtime,$size) is not present
#

my $job_a = $dbh->prepare(q{SELECT id FROM files WHERE name=? AND pathid=?});
my $job_a_insert = $dbh->prepare(q{INSERT INTO files (sha1sum,"name","name_orig",pathid,size,mtime,typeid,cdv) VALUES (?,?,?,?,?,?,?,?)});
$job_a_insert->bind_param(3, undef, { pg_type => DBD::Pg::PG_BYTEA }); 

my $job_b = $dbh->prepare(q{SELECT id FROM files WHERE name=? AND pathid=? AND mtime=? AND size=?});
my $job_b_update = $dbh->prepare(q{UPDATE files SET sha1sum=?,size=?,mtime=?,typeid=?,cdv=? WHERE name=? AND pathid=?});

if (defined $verbose) { print "directories in hash: " . scalar(keys %files) . "\n"; }

foreach my $dir (keys %files) {

    if (defined $verbose) { print "files in hash for directory $dir: " . scalar(keys %{$files{$dir}}) . "\n"; }

    my $dir_utf8 = encode("UTF-8", $dir);

    foreach my $name (keys %{$files{$dir}}) {
        my $name_utf8 = encode("UTF-8", $name);
        my $path_utf8 = "$dir_utf8/$name_utf8";
        my $path = "$dir/$name";

        if (not -r "$dir/$name") {
            print "warning: can't read file \"$dir/$name\" - skipping\n";
            next;
        }

        my $condition_for_add = undef;

        if (defined $path_is_new{$dir}) {
            $condition_for_add = 1;
        }
        else {
            $job_a->execute($name_utf8, $paths_db{$dir_utf8});
            my $result_a = $job_a->fetchall_arrayref(); 
            if (@{$result_a} < 1) {
                $condition_for_add = 1;
            }
        }

        if (defined $condition_for_add) {
            # step3 a)
            if (defined $verbose) { print "adding file \"$path_utf8\"\n"; }
            my ($type, $cdvformat) = get_type_descriptor($path);
            if (not defined $types_db{$type}) {
                $types_db{$type} = insert_type_into_db($dbh, $type, $cdvformat);
                $cdvformats_db{$type} = $cdvformat;
            }
            $files{$dir}{$name}{'type'} = $type;
            $files{$dir}{$name}{'sha1sum'} = sha1sum_file_b64($path);
            $files{$dir}{$name}{'cdv'} = cdv_file_b64($path,$cdvformats_db{$files{$dir}{$name}{'type'}});
            $job_a_insert->execute(
                            $files{$dir}{$name}{'sha1sum'}, 
                            $name_utf8,
                            $name,
                            $paths_db{$dir_utf8},
                            $files{$dir}{$name}{'size'},
                            $files{$dir}{$name}{'mtime'},
                            $types_db{$files{$dir}{$name}{'type'}},
                            $files{$dir}{$name}{'cdv'});
        }
        else {
            $job_b->execute($name_utf8, $paths_db{$dir_utf8}, $files{$dir}{$name}{'mtime'}, $files{$dir}{$name}{'size'});
            my $result_b = $job_b->fetchall_arrayref();
            if (@{$result_b} < 1) {
                # step 3 b)
                if (defined $verbose) { print "updating file \"$path_utf8\"\n"; }
                my ($type, $cdvformat) = get_type_descriptor($path);
                if (not defined $types_db{$type}) {
                    $types_db{$type} = insert_type_into_db($dbh, $type, $cdvformat);
                    $cdvformats_db{$type} = $cdvformat;
                }
                $files{$dir}{$name}{'type'} = $type;
                $files{$dir}{$name}{'sha1sum'} = sha1sum_file_b64($path);
                $files{$dir}{$name}{'cdv'} = cdv_file_b64($path,$cdvformats_db{$files{$dir}{$name}{'type'}});
                $job_b_update->execute(
                                $files{$dir}{$name}{'sha1sum'}, 
                                $files{$dir}{$name}{'size'},
                                $files{$dir}{$name}{'mtime'},
                                $types_db{$files{$dir}{$name}{'type'}},
                                $files{$dir}{$name}{'cdv'},
                                $name_utf8,
                                $paths_db{$dir_utf8});
            }
            else {
                if (defined $debug) { print "DEBUG: nothing needs to be done for \"$path_utf8\"\n"; }
            }
        }
    }
}

$job_a->finish();
$job_a_insert->finish();
$job_b->finish();
$job_b_update->finish();

# at this point the in-memory structures of %files, %paths_db and %types_db
# should be fully populated and consistent

}

# ------------------------------- prune_db ------------------------------

elsif (defined($prune_db)) {

#
# phase 1: read the list of directories to check against and make sure they exist
#

my %dirs;

while (<STDIN>) {
   my $dir = $_;
   chomp $dir;

   if (not -d "$dir") {
       print "warning: directory \"$dir\" doesn't exist - skipping\n";
       next;
   }

   $dirs{$dir} = 1;
}

#
# phase 2: remove non-existing paths and files from the database 
#

# 
# step 1: obtain a map of knowns path(id)s, check for their existence in the file system and
#         if negative remove the path from the database (cascading into the tables of files!);
#         for populated, removed directories this is much more efficient than doing it for
#         every single file (in step 2) of that directory 
# 

my %paths_db;
my %paths_todelete;

$job = $dbh->prepare('SELECT pathid,path,path_orig from paths');
$job->execute();

while (my ($pathid, $path, $path_orig) = $job->fetchrow_array() ) {
    #print "DEBUGX: fetched path \"$path\" with id \"$pathid\" and path_orig \"$path_orig\"\n";

    my $hitcount = 0;
    foreach my $dir (keys %dirs) {
       if (-d "$dir/$path_orig") { $hitcount += 1; }
    }

    if ($hitcount > 1) {
       print "warning: the path \"$path_orig\" exists in more than one of the specificed directories - this might indicate an unclean (aliased) import\n";
    }

    if ($hitcount eq 0) {
       $paths_todelete{$pathid} = $path_orig;
    }
    else {
       $paths_db{$pathid} = $path_orig;
    }
}

$job->finish();

$job = $dbh->prepare('DELETE FROM paths WHERE pathid=?');

foreach my $pathid (keys %paths_todelete) {
   if (defined $verbose) { print "deleting path from database: \"" . $paths_todelete{$pathid} . \"\n"; }
   $job->execute($pathid);
}

$job->finish();

# 
# step 2: obtain a map of all files with the path name expanded, check for their existence
#         in the file system and if negative remove the file from the database
# 

my %files_todelete;

$job = $dbh->prepare('SELECT id,name,name_orig,pathid from files');
$job->execute();

while (my ($id, $name, $name_orig, $pathid) = $job->fetchrow_array() ) {
    my $fullpath = $paths_db{$pathid} . "/" . $name_orig;
   
    # print "DEBUGX: got \"$fullpath\" from database\n";

    my $hitcount = 0;
    foreach my $dir (keys %dirs) {
       if (-e "$dir/$fullpath") { $hitcount += 1; }
	# print "DEBUGY: checking for existence of \"$dir/$fullpath\" ($hitcount)\n";
    }

    if ($hitcount > 1) {
       print "warning: the file \"$fullpath\" exists in more than one of the specificed directories - this might indicate an unclean (aliased) import\n";
    }

    if ($hitcount eq 0) {
       $files_todelete{$id} = $fullpath;
    }
}

$job->finish();

$job = $dbh->prepare('DELETE FROM files WHERE id=?');

foreach my $id (keys %files_todelete) {
   if (defined $verbose) { print "deleting file from database: \"" . $files_todelete{$id} . "\"\n"; }
   $job->execute($id);
}

$job->finish();
}

# ------------------------------- duplicates ------------------------------

elsif (defined($duplicates)) {

#
# phase 1: retrieve full path, checksum and size of all files and group them by a key consisting of the checksum and size
#          (just for the very unlikely case of checksum collision)
#

my %collisions;

$job = $dbh->prepare('SELECT name,sha1sum,size,path_orig from files,paths where files.pathid=paths.pathid');
$job->execute();

while (my ($name, $sha1sum, $size, $path_orig) = $job->fetchrow_array() ) {
    my $key = "sha1sum=$sha1sum size=$size";
    push (@{$collisions{$key}}, $path_orig . "/" . $name); 
}

$job->finish();

#
# phase 2: output any collisions (=more than 1 element in the array) in reverse count order
#

foreach my $key (sort { @{$collisions{$b}} <=> @{$collisions{$a}} } keys %collisions) {
   my @list = @{$collisions{$key}};
   my $length = scalar(@list);

   if ($length > 1) {
      my $elem = shift @list;
      print $length - 1 . " duplicates of \"$elem\" on $key:\n";
      foreach my $elem (@list) {
          print "\t$elem\n";
      }
   }
}
}

$dbh->disconnect();

exit 0;

# EOF
