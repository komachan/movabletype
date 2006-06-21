#!/usr/bin/perl
#
# Export/build/deployment/notification automation.
#
# $Id$
#
# XXX WARNING: Overly rambling, deeply nested logic ahead.
# XXX Modularization is next.
#
use strict;
use warnings;
use Archive::Tar;
use Getopt::Long;
use File::Basename;
use File::Copy;
use File::Path;
use File::Spec;
use IO::File;
use LWP::UserAgent;
use Net::SMTP;
use Sys::Hostname;
use Data::Dumper;
$Data::Dumper::Indent = $Data::Dumper::Terse = $Data::Dumper::Sortkeys = 1;

# Flush the output buffer.
$|++;

# Show the usage if there are no command-line arguments provided.
usage() unless @ARGV;

# Set-up the command-line options with their default values.
my %o = get_options(
  'alpha=i'         => 0,  # Integer
  'append:s'        => undef,  # String to append to the build.
  'app=s'           => 'MT',  # String to append to the build.
  'arch=s'          => '.tar.gz',  # CSV: .tar.gz,.zip
  'beta=i'          => 0,  # Integer
  'branch=s'        => '',  # TINSEL, TRIBBLE, etc.
  'build=s'         => '/tmp/MT-Dist',  # Export directory base.
  'cleanup!'        => 1,  # Remove the exported directory after deployment.
  'date!'           => 1,  # Date-stamp the build by default.
  'debug'           => 0,  # Turn on/off the actual system calls.
  'deploy:s'        => '', #($ENV{USER}||$ENV{USERNAME}) .'@rongo:/usr/local/cifs/intranet/mt-interest/',
  'deploy-uri=s'    => 'https://intranet.sixapart.com/mt-interest/%s',
  'email-bcc:s'     => undef,
  'email-body=s'    => '',  # Constructed at run-time.
  'email-cc:s'      => undef,
  'email-from=s'    => ($ENV{USER}||$ENV{USERNAME}) .'@sixapart.com',
  'email-host=s'    => 'mail.sixapart.com',
  'email-subject=s' => '',  # Constructed at run-time.
  'export=s'        => '',  # Export directory base - Constructed at run-time.
  'footer=s'        => "<br><b>SOFTWARE IS PROVIDED FOR TESTING ONLY - NOT FOR PRODUCTION USE.</b>\n",
  'footer-tmpl=s'   => 'tmpl/cms/footer.tmpl',
  'help|h'          => 0,  # Show the program usage.
  'http-user=s'       => undef,
  'http-pass=s'       => undef,
  'ldap'            => 0,  # Use LDAP (and don't initialize the database).
  'lang=s'          => $ENV{BUILD_LANGUAGE} || 'en_US',  # en_GB is generated automatically (de,es,fr,ja,nl)
  'local'           => 0,  # Command-line --option alias
  'make=s'          => 'build/mt-dists/make-dists',  # Constructed at run-time.
  'mt-dir=s'        => ($ENV{MT_DIR}||'.'),  # Location defaults to the user env or the cwd.
  'mt-pm=s'         => 'lib/MT.pm.pre', # Where the version strings are located.
  'name:s'          => undef,  # Override string to name the archive.
  'notify:s'        => undef,  # Send email notification on completion.
  'prod'            => 0,  # Command-line --option alias
  'qa'              => 0,  # Command-line --option alias
  'repo=s'          => 'trunk',  # Reset at runtime depending on branch,tag.
  'repo-uri=s'      => 'https://intranet.sixapart.com/repos/eng/%s/mt',
  'shown:s'         => undef,  # String to replace the VERSION_ID.
  'stage'           => 0,  # Command-line --option alias
  'stage-dir=s'     => '/var/www/html/mt-stage',
  'stage-uri=s'     => 'http://mt.sixapart.com/%s',
  'stamp=s'         => '%04d%02d%02d',  # YYYY=%04d, MM=%02d, etc.
  'symlink!'        => 1,  # Make build symlinks when staging.
  'tag=s'           => '',  # mt3.2, mt3.2-intl, etc.
  'verbose!'        => 1,  # Express (the default) or suppress run output.
);

# Show the usage if requested.
usage() if $o{'help|h'};

# Set the BUILD_LANGUAGE and BUILD_PACKAGE environment variables
# unless they are not already defined.
$ENV{BUILD_LANGUAGE} ||= $o{'lang=s'};
$ENV{BUILD_PACKAGE} ||= $o{'app=s'};

# Figure out the the repository and URL to use.
$o{'repo=s'} = $o{'branch=s'} ? "branches/$o{'branch=s'}"
             : $o{'tag=s'}    ? "tags/$o{'tag=s'}"
             : $o{'repo=s'};
$o{'repo-uri=s'} = sprintf $o{'repo-uri=s'}, $o{'repo=s'};

# Make sure that the repository actually exists.
my $ua = LWP::UserAgent->new;
my $request = HTTP::Request->new(HEAD => $o{'repo-uri=s'});
if ($o{'http-user=s'} && $o{'http-pass=s'}) {
    $request->authorization_basic($o{'http-user=s'}, $o{'http-pass=s'});
}
my HTTP::Response $response = $ua->request($request);
if (!$response->is_success) {
    die "ERROR: The repoository '$o{'repo-uri=s'}' can't be resolved.";
}

# Append the repository unless an append string is already defined.
$o{'append:s'} = lc( fileparse $o{'repo=s'} )
    unless defined $o{'append:s'};
$o{'append:s'} .= '-ja' if $o{'lang=s'} eq 'ja';

######################################################################
## COMMAND ALIAS OVERRIDE LOGIC:
# Production builds are not dated or stamped.
if( $o{'prod'} ) {
    $o{'date!'} = 0;
    $o{'append:s'} = '';
}
# Local builds don't deploy or cleanup after themselves.
if( $o{'local'} ) {
    $o{'cleanup!'} = 0;
}
# Staging deploys into the stage-dir.
if( $o{'stage'} ) {
    $o{'deploy:s'} = $o{'stage-dir=s'};
}
# Alpha/Beta releases are not repo-tagged.
if( $o{'alpha=i'} || $o{'beta=i'} ) {
    $o{'append:s'} = '';
}
# LDAP-ness
if( $o{'ldap'} ) {
    $o{'append:s'} .= '-ldap';
}
######################################################################

# Create the build-stamp to use.
$o{'stamp=s'} = $o{'date!'}
    ? sprintf $o{'stamp=s'},
        (localtime)[5] + 1900, (localtime)[4] + 1, (localtime)[3,2,1,0]
    : '';
# Override the stamp if a --name is given.
if( $o{'name:s'} ) {
    $o{'stamp=s'} = "-$o{'stamp=s'}" if $o{'date!'};
    $o{'stamp=s'} = $o{'name:s'} . $o{'stamp=s'};
}
# Override the stamp if a --name is not given but --append is.
elsif( $o{'append:s'} ) {
    $o{'stamp=s'} .= '-' if $o{'date!'};
    $o{'stamp=s'} .= $o{'append:s'}
}

$ENV{BUILD_VERSION_ID} ||= $o{'stamp=s'};

# Make the export directory to use with the stamp.
$o{'export=s'} = File::Spec->catdir( $o{'build=s'}, $o{'stamp=s'} );
die 'No export directory given.' unless $o{'export=s'};
$o{'export=s'} =~ s/~/$ENV{HOME}/;

# Construct the "make-dists" tool path.
$o{'make=s'} = File::Spec->catdir( $o{'mt-dir=s'}, $o{'make=s'} );
# Once stringified by GO::L, the tilde no longer means $HOME.
$o{'make=s'} =~ s/~/$ENV{HOME}/;

# Make sure the make script exists.
die "ERROR: Can't locate $o{'make=s'}: $!" unless -e $o{'make=s'};

# Summarize what we are about to do.
verbose( sprintf 'Debugging is %s and system calls %s be made.',
    $o{'debug'} ? 'ON' : 'OFF', $o{'debug'} ? "WON'T" : 'WILL',
);
verbose( sprintf( 'Running with options: %s', Dumper \%o ),
    "Svn uri: $o{'repo-uri=s'}", "Make dir: $o{'make=s'}",
) if $o{'debug'};

# Get any existing distro, with the same path name, out of the way.
if( -d $o{'export=s'} ) {
    verbose( "Remove: $o{'export=s'}" );
    rmtree( $o{'export=s'} ) or die "Can't rmtree $o{'export=s'}: $!"
        unless $o{'debug'};
}

# Export the build (SVN auto-creates the directory).
verbose_command( sprintf( '%s export %s%s %s',
    'svn',
    ($o{'verbose!'} ? '' : '--quiet '),
    $o{'repo-uri=s'},
    $o{'export=s'}
));

# Change to the export directory.  XXX Required by the make=s command.
chdir( $o{'export=s'} ) or die "Can't cd to $o{'export=s'}: $!"
    unless $o{'debug'};

# Read-in the configuration variables for substitution.
my $config = read_conf( "build/mt-dists/$ENV{BUILD_PACKAGE}.mk" );
my $version    = $config->{PRODUCT_VERSION};
my $version_id = $o{'shown:s'} || $config->{PRODUCT_VERSION_ID} || $ENV{BUILD_VERSION_ID};

# Update the version number.
$version_id = update_version(
    File::Spec->catdir( $o{'export=s'}, $o{'mt-pm=s'} ),
    "$o{'lang=s'}-$o{'stamp=s'}"
);

# Set non-production footer.
inject_footer() unless $o{'prod'};

my $app = $o{'name:s'}
    ? $o{'stamp=s'}
    : sprintf '%s-%s%s-%s-%s',
        $o{'app=s'},
        $version,
        ($o{'alpha=i'} ? "a$o{'alpha=i'}" : ($o{'beta=i'} ? "b$o{'beta=i'}" : '')),
        $o{'lang=s'},
        $o{'stamp=s'};

# Build the distribution (with external make call).
#verbose_command(
#    sprintf( '%s %s --language=%s --stamp=%s', 
#        $^X,
#        $o{'make=s'},
#        ($o{'lang=s'} eq 'en_GB' ? 'en_US' : $o{'lang=s'}),
#        $app,
#    )
#);
verbose_command(
    sprintf( '%s %s --stamp=%s', $^X, $o{'make=s'}, $app )
);

# Create lists of the actual files that are part of the distribution.
my $distros = { path => [], url => [] };
for my $lang ( split( /\s*,\s*/, $o{'lang=s'} ) ) {
    for my $arch ( split( /\s*,\s*/, $o{'arch=s'} ) ) {
        # Set the new distribution name.
        my $app = $o{'name:s'}
            ? $o{'stamp=s'}
            : sprintf '%s-%s%s-%s-%s',
                $o{'app=s'},
                $version,
                ($o{'alpha=i'} ? "a$o{'alpha=i'}" : ($o{'beta=i'} ? "b$o{'beta=i'}" : '')),
                $o{'lang=s'},
                $o{'stamp=s'};
        # The filename is the distribution name plus the archive extension.
        my $filename = $app . $arch;
        # The distribution is the full export path and filename.
        my $dist = File::Spec->catdir( $o{'export=s'}, $filename );
        # The stamp starts life as the distribution name.
        my $stamped = $dist;

        # Move the build file to the drop-zone.
        if( $o{qa} ) {
            my $drop = File::Spec->catdir( $o{'build=s'}, $filename );
            verbose( "Moving $stamped to $drop" );
            move( $stamped, $drop ) or
                die "Can't move $stamped to $drop: $!"
                unless $o{'debug'};
            $stamped = $drop;
        }

        # Create lists of things to notify about.
        push @{ $distros->{path} }, $stamped;
        push @{ $distros->{url} },
              $o{'stage'}           ? sprintf "$o{'stage-uri=s'}/mt.cgi", $app
            : $o{'deploy:s'} =~ /:/ ? sprintf $o{'deploy-uri=s'}, $filename
            : ();
    }
}

# XXX Below is some frightening #$@&ing logic. See the TO DO section.
# Deploy the distro.
if( $o{'deploy:s'} ) {
    # If a colon : is in the deployment string, use scp.
    if( $o{'deploy:s'} =~ /:/ ) {
        verbose_command( sprintf( '%s %s %s',
            'scp', join( ' ', @{ $distros->{path} } ), $o{'deploy:s'}
        ));
    }
    else {
        # Copy the distribution file(s) to the destination.
        for my $dist ( @{ $distros->{path} } ) {
            my $dest = File::Spec->catdir(
                $o{'deploy:s'}, scalar fileparse( $dist )
            );
            copy( $dist, $dest ) or die "Can't copy $dist to $dest: $!"
                unless $o{'debug'};
            verbose( "Copied $dist to $dest" );

# XXX We assume there is only one archive file.
            # Install if we are locally staging.
            if( $o{'stage'} ) {
                chdir $o{'stage-dir=s'} or
                    die "Can't chdir to $o{'stage-dir=s'}: $!";
                verbose( "Changed to staging root $o{'stage-dir=s'}" );

                # Remove any existing distro, with the same path name.
                if( -d $dest ) {
                    rmtree( $dest ) or die "Can't rmtree $dest: $!"
                        unless $o{'debug'};
                    verbose( "Removed: $dest" );
                }

                my $tar;
                unless( $o{'debug'} ) {
                    verbose( "Extracting $dest..." );
                    $tar = Archive::Tar->new( $dest );
                    $tar->extract();
                }
                verbose( "Extracted $dest" );

                # Do we have a current symlink?
                my $current = '';
                $current = readlink( $o{'append:s'} )
                    if -e $o{'append:s'};
                $current =~ s/\/$//;
                # Database named the same as the distribution (but with _'s).
                (my $current_db = $current) =~ s/[.-]/_/g;

                # Change to the distribution directory.
                my $stage_dir = fileparse(
                    $dest, split /\s*,\s*/, $o{'arch=s'}
                );
                chdir( $stage_dir ) or die "Can't chdir $stage_dir: $!"
                    unless $o{'debug'};
                verbose( "Changed to $stage_dir" );

                # Our database is named the same as the distribution
                # (but with _'s) except for LDAP.
                (my $db = $stage_dir) =~ s/[.-]/_/g;
                # Reset the db to have the same name, if we are LDAP.
                $db = 'ldap' if $o{'ldap'};
                # Append the handy staging build flag.
                $db = 'stage_' . $db;

                # Set the staging URL to a real location now.
                my $url = sprintf $o{'stage-uri=s'}, "$o{'append:s'}/";

                # Give unto us a shiny, new config file.
                my $config = 'mt-config.cgi';
                unless( $o{'debug'} ) {
                    my $fh = IO::File->new( ">$config" );
                    print $fh <<CONFIG;
CGIPath $url
DefaultSiteURL http://mt.sixapart.com/blogs/
DefaultSiteRoot /var/www/html/mt-stage/blogs/
Database $db
ObjectDriver DBI::mysql
DBUser root
DebugMode 1
CONFIG
                    if( $o{'ldap'} ) {
                        print $fh <<CONFIG;
AuthenticationModule LDAP
AuthLDAPURL ldap://ldap.sixapart.com/dc=sixapart,dc=com
CONFIG
                    }

                    $fh->close();
                }
                verbose( "Wrote configuration to $config" );

                # Create and initialize a new database.
                unless( $o{'ldap'} ) {
                    # Set up the database for this distribution.
                    verbose( 'Initializing database.' );
                    # XXX Use DBI ASAP.
                    # Drop the previous database.
                    verbose_command( "mysqladmin drop $current_db -u root -f" )
                        if $db eq $current_db;
                    # Drop a database of same name.
                    verbose_command( "mysqladmin drop $db -u root -f" );
                    verbose_command( "mysqladmin create $db -u root" );
                    # Run the upgrade tool.
                    verbose_command( "$^X ./tools/upgrade --name Melody" );
                }

                # Change to the parent of the new stage directory.
                chdir( '..' ) or die "Can't chdir to .."
                    unless $o{'debug'};
                verbose( 'Changed back to staging root' );

                # Now we re-link the stamped directory to the append string.
                if( $o{'symlink!'} && ( !$current || $current ne $stage_dir ) ) {
                    # Drop current symlink.
                    if( !$o{'debug'} && $o{'symlink!'} && -e $o{'append:s'} ) {
                        unlink( $o{'append:s'} ) or
                            die "Can't unlink $o{'append:s'}: $!"
                    }
                    # Drop previous directory.
                    if( !$o{'debug'} && $current && -d $current ) {
                        rmtree( $current ) or
                            die "Can't rmtree $current: $!"
                    }
                    # Relink the staged directory.
                    symlink( "$stage_dir/", $o{'append:s'} ) or
                        die "Can't symlink $stage_dir/ to $o{'append:s'}: $!"
                        unless $o{'debug'};
                    verbose( "Symlink'd $stage_dir/ to $o{'append:s'}" );
                }

                # Do we have a current archive file symlink?
                my $build = $o{'append:s'} . $o{'arch=s'};
                $current = '';
                $current = readlink( $build ) if -e $build;

                if( $o{'symlink!'} && ( !$current || $current ne "$stage_dir$o{'arch=s'}" ) ) {
                    # Drop current symlink.
                    if( !$o{'debug'} && $build && -e $build ) {
                        unlink( $build ) or die "Can't remove $build: $!"
                    }
                    # Drop previous build file.
                    if( !$o{'debug'} && $current && -e $current ) {
                        unlink( $current ) or
                            die "Can't unlink $current $!"
                    }
                    # Relink the staged build file.
                    symlink( "$stage_dir$o{'arch=s'}", $build ) or
                        die "Can't symlink $stage_dir$o{'arch=s'} to $build $!"
                        unless $o{'debug'};
                    verbose(
                        "Symlink'd $stage_dir$o{'arch=s'} to $o{'append:s'}$o{'arch=s'}"
                    );
                }

                if( !$o{'debug'} || !$o{'symlink!'} ) {
                    # Make sure we can get to our symlink.
                    $url = sprintf "$o{'stage-uri=s'}/mt.cgi",
                        $o{'append:s'};
                    die "ERROR: Staging $url can't be resolved."
                        unless $ua->head( $url );
                    # Make sure we can get to our archive file symlink.
                    $url = sprintf $o{'stage-uri=s'},
                        "$o{'append:s'}$o{'arch=s'}";
                    die "ERROR: Staging $url can't be resolved."
                        unless $ua->head( $url );
                }
            }

            # Update the staging html.
            if( $o{'stage'} || $o{'deploy:s'} eq $o{'stage-dir=s'} ) {
                my $stage_dir = fileparse( $dest, split /\s*,\s*/, $o{'arch=s'} );
                my $old_html = File::Spec->catdir( $o{'stage-dir=s'}, 'index.html' );
                unless( $o{'debug'} ) {
                    warn "ERROR: $old_html does not exist" unless -e $old_html;
                    warn "Updating $old_html...\n";
                    my $new_html = File::Spec->catdir( $o{'stage-dir=s'}, 'index.html.new' );
                    my $old_fh = IO::File->new( '< ' . $old_html );
                    my $new_fh = IO::File->new( '> ' . $new_html );
                    while( <$old_fh> ) {
                        my $line = $_;
                        if( /id="($o{'append:s'}(?:$o{'arch=s'}))"/ ) {
                            my $id = $1;
                            verbose( "Matched id=$id" );
                            $line = sprintf qq/<a id="%s" href="$o{'stage-uri=s'}%s">%s%s<\/a>\n/,
                                $id,
                                $stage_dir, $o{'arch=s'},
                                $stage_dir, $o{'arch=s'};
                        }
                        print $new_fh $line;
                    }
                    $old_fh->close;
                    $new_fh->close;
                    move( $new_html, $old_html ) ||
                        die "ERROR: Can't move $new_html, $old_html: $!";
                    verbose( "Moved $new_html to $old_html" );
                }
            }
        }
    }

    # Make sure the deployed distros actually made it.
    unless( $o{'debug'} ) {
        for( @{ $distros->{url} } ) {
            die "ERROR: $_ can't be resolved." unless $ua->head( $_ );
        }
    }
}

# Cleanup the exported files.
if( !$o{'debug'} && $o{'cleanup!'} ) {
    rmtree( $o{'export=s'} ) or die "Can't rmtree $o{'export=s'}: $!";
    verbose( "Cleanup: Removed $o{'export=s'}" );
}

# Send email notification.
if( $o{'notify:s'} ) {
    $o{'email-subject=s'} = sprintf '%s build: %s',
        $o{'app=s'}, $o{'stamp=s'};
    $o{'email-subject=s'} .=
        $o{'alpha=i'} ? ' - Alpha ' . $o{'alpha=i'} :
        $o{'beta=i'}  ? ' - Beta '  . $o{'beta=i'}  :
        $o{'prod'}  ? ' - Production'               :
        $o{'stage'} ? ' - Staging'                  :
        $o{'qa'}    ? ' - QA'                       : '';

    # If an email-cc exists, add a comma in front of the QA address.
    $o{'email-cc:s'} .= ($o{'email-cc:s'} ? ',' : '') .
        'sixapart@qasource.com';

    # Show the deployed URL's.
    $o{'email-body=s'} = sprintf "File URL(s):\n%s\n\n",
        join( "\n", @{ $distros->{url} } )
        if $o{'deploy:s'};

    $o{'email-body=s'} .= sprintf "Build file(s) located on %s\n%s",
        hostname(), join( "\n", @{ $distros->{path} } )
        if $o{'qa'} || !$o{'cleanup!'};

    notify();
}

# ------------------------------------------------------------------ #
# Whew! We made it.
exit;
# ------------------------------------------------------------------ #

sub get_options {
    my %o = @_;
    # Map all literal string values to scalar references. 
    while( my( $key, $val ) = each %o ) {
       $o{$key} = \$val unless ref $val;
    }

    # Get the command-line options.
    GetOptions( %o );

    # "Un-map" the scalar references so we don't have to say,
    # ${$o{'foo'}}.
    while( my( $key, $val ) = each %o ) {
        $o{$key} = $$val if ref $val eq 'SCALAR';
    }

    return %o;
}

sub verbose_command {
    my $command = shift;
    verbose( 'Execute:', "  $command" );
    system $command unless $o{'debug'};

    if( $? == -1 ) {
        die "Failed to execute: $!";
    }
    elsif( $? & 127 ) {
        die sprintf( "Child died with signal %d, with%s coredump\n",
            ( $? & 127 ), ( $? & 128 ? '' : 'out' )
        );
    }
    else {
#        printf "Child exited with value %d\n", $? >> 8 if $o{'verbose!'};
    }

    return $command;
}

sub notify {
    verbose( 'Entered notify()' );
    return if $o{'debug'};

    my $smtp = Net::SMTP->new(
        $o{'email-host=s'},
        Debug => $o{'debug'},
    );

    $smtp->mail( $o{'email-from=s'} );
    $smtp->to( $o{'notify:s'} );
    $smtp->cc( $o{'email-cc:s'} ) if $o{'email-cc:s'};
    $smtp->bcc( $o{'email-bcc:s'} ) if $o{'email-bcc:s'};

    $smtp->data();
    $smtp->datasend( "To: $o{'notify:s'}\n" );
    $smtp->datasend( "Cc: $o{'email-cc:s'}\n" ) if $o{'email-cc:s'};
    $smtp->datasend( "Subject: $o{'email-subject=s'}\n" );
    $smtp->datasend( "\n" );
    $smtp->datasend( "$o{'email-body=s'}\n" );
    $smtp->dataend();

    $smtp->quit;

    verbose( "Email sent to $o{'notify:s'}" );
}

sub update_version {
    my $file = shift;
    die 'ERROR: No file to update given.' unless $file;

    verbose( "Entered update_version with $file" );
    return 'DEBUG' if $o{'debug'};

    die "ERROR: File $file does not exist: $!" unless -e $file;

    my $stamp = shift || '';
    verbose( 'WARNING: No stamp provided for version update.' )
        unless $stamp;

    # Slurp-in the contents of the file.
    local $/;
    my $fh = IO::File->new( $file );
    my $contents = <$fh>;
    $fh->close();

    # Try to replace the VERSION_ID string.
    my $new_id = $o{'shown:s'} || "$version-$stamp";
    $new_id .= sprintf( '-%04d%02d%02d',
        (localtime)[5] + 1900, (localtime)[4] + 1, (localtime)[3,2,1,0] )
        if $o{'date!'};
    my $version_id = '';
    if( ( $o{'date!'} || $o{'append:s'} ) ) {
        $contents =~ s/
            \$VERSION_ID  # We care about the VERSION_ID
            \s* = \s*     # Assignment with whitespace
            '?            # Version is likely quoted
            ( \w+ )       # Capture ONLY the digit-part
            .*?           # There may be stuff to ignore after the version_id
            '?            # ..and is likely quoted
            \s* ;         # Ending with a whitespace semi-colon
        /\$VERSION_ID = '$new_id';/x;
        $version_id = $new_id;
    }
    die "ERROR: Could not find a VERSION_ID in $file"
        unless $version_id;
    verbose( "VERSION_ID: '$version_id'" );

    # Rewrite the file with the stamped version_id.
    $fh = IO::File->new( "> $file" );
    print $fh $contents;
    $fh->close();

    # Hand back the version_id string.
    return $version_id;
}

sub read_conf {
    my @files = @_;
    my $config = {};

#    warn "Files: @files\n";
    for my $file ( @files ) {
        next unless -e $file;
        warn "Parsing config $file file...\n";
        my $fh = IO::File->new( '< ' . $file );

        while( <$fh> ) {
            # Skip comment lines.
            next if /^\s*#/;
            # Skip blank lines.
            next if /^\s*$/;
            # Capture a configuration pair.
            /^\s*(.*?)\s*=\s*(.*)\s*$/ or next;
            my( $k, $v ) = ( $1, $2 );
            $config->{$k} = $v;
        }

        $fh->close;
    }

    return $config;
}

sub inject_footer {
    my $file = File::Spec->catdir( $o{'export=s'},  $o{'footer-tmpl=s'} );
    verbose( "Entered inject_footer with $file" );
    return 'DEBUG' if $o{'debug'};
    die "ERROR: File $file does not exist: $!" unless -e $file;

    # Slurp-in the contents of the file.
    local $/;
    my $fh = IO::File->new( $file );
    my $contents = <$fh>;
    $fh->close();

    $contents =~ s/Reserved.\n/Reserved.\n$o{'footer=s'}/;

    # Rewrite the file with the injected footer.
    $fh = IO::File->new( "> $file" );
    print $fh $contents;
    $fh->close();
}

sub verbose {
    return unless $o{'verbose!'};
    print join( "\n", @_ ), "\n";
}

sub usage {
    print <<USAGE;

 perldoc $0    # Detailed documentation with option defaults

 perl $0 --help

 Simple examples:

 cd \$MT_DIR
 perl $0 --tag=FOO --build=mt/builds --local
 perl $0 --branch=BAR --notify=mt-dev\@sixapart.com --qa
 perl $0 --beta=1

 Supressing and overriding:

  --append=    # Supress automatic repository stamping.
  --alpha=42   # Stamps archive with an 'a42' instead of the repo export.
  --beta=42    # Same as --alpha.
  --build=/build/under/path  # Export and build under this path.
  --deploy=    # Supress automatic deployment.
  --local      # Does not cleanup or deploy anywhere.
  --mt-dir=~/svn/tinsel  # Used to locate the depency script, make-dists.
  --name=Foo   # Override the archive name with a string.
  --nocleanup  # Leaves the build files in the export directory.
  --nodate     # Supress automatic archive date stamping.
  --notify=mt-dev\@sixapart.com  # Notify mt-dev.
  --noverbose  # Supress run-time verbosity.
  --prod       # Does no archive stamping and notifies mt-dev.
  --qa         # Reposoitory and date stamps. Cc:'s QA.
  --stage      # Stamp the archive and deploy to staging.

USAGE
    # And then bail out.
    exit;
}

__END__

=head1 NAME

MovableType Export/Make/Deploy/Notify Automation

=head1 DESCRIPTION

Please see:
https://intranet.sixapart.com/wiki/index.php/Movable_Type:MT_Export-Deploy
for full documentation.

=cut
