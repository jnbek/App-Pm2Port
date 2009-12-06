package App::Pm2Port;

#===============================================================================
#
#         FILE:  portupload.pl
#
#        USAGE:  ./portupload.pl
#
#  DESCRIPTION:  upload
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Andrey Kostenko (), <andrey@kostenko.name>
#      COMPANY:  Rambler Internet Holding
#      VERSION:  1.0
#      CREATED:  26.06.2009 02:13:30 MSD
#     REVISION:  ---
#===============================================================================

$ENV{LC_ALL} = 'C';
use 5.010;
use feature qw(switch state);
use strict;
use warnings;
use ExtUtils::MakeMaker();
use Net::FTP;
use Getopt::Long;
use File::Temp qw(tempdir);
use YAML qw(LoadFile DumpFile);
use JSON::XS;
use version;
use CPAN;
use CPANPLUS::Backend;
use FreeBSD::Ports::INDEXhash qw/INDEXhash/;

=head2 new

=cut

sub new {
    my $class  = shift;
    my %params = @_;
    $params{INDEX} = { INDEXhash() };
    bless {%params}, $class;
}

=head2 prompt

Asks something

=cut

sub prompt {
    my ( $text, $default ) = @_;
    require Term::ReadLine;
    state $term = Term::ReadLine->new('perl2port');
    $term->readline( $text, $default );
}

=head2 perl_version_parse

Args: $version

Converts perl version number to something understandable by FreeBSD

=cut

sub perl_version_parse {
    my ( $self, $version ) = @_;
    my $b = 0;
    return join '.', map { int $_ }
      grep { defined }
      ( $version =~ /^(\d+)\.(\d{1,3})(?:\.(\d{1,3})|(\d{3}))?$/ );
}

=head2 get_dependencies

Returns FreeBSD-style list of dependencies.

=cut

sub get_dependencies {
    my $self = shift;
    my $requires = shift;
    my $ports    = shift;
    return '' unless $requires;
    my @deps;
    my %deps;
    foreach ( keys %$requires ) {
        my $module = $_;
        next if $module eq 'perl';
        my $distribution;
        unless ($ports) {
            my $cpan_module = CPAN::Shell->expand( "Module", $module );
            if ($cpan_module) {
                $distribution = $cpan_module->distribution()->base_id;
            }
            else {
                ( $distribution = $module ) =~ s/::/-/g;
            }
            next if $distribution =~ /^perl-/;
            $distribution = "p5-$distribution";
            $distribution =~ s/-v?[\d\.]+$//;
            $distribution =~ s/libwww-perl/libwww/;
        }
        else {
            $distribution = $module;
        }
        next if $deps{$distribution};
        $deps{$distribution} = 1;
        my ($package_name) = grep /^\Q$distribution-\E[\d.]+/, keys %{ $self->{INDEX} };
        my $location = $self->{INDEX}{$package_name}{path};
        unless ($location) {
            print "Creating dependency for $distribution";

            #die "Missing dependency for $distribution";
            unless (fork) {
                my $a = App::Pm2Port->new( module => $module );
                $a->run;
                exit;
            }
            wait;
            $location =
                '/usr/ports/'
              . LoadFile( glob "~/.portupload/$module.yml" )->{category}
              . "/$distribution";
        }
        $location =~ s!/usr/ports!\${PORTSDIR}!;
        push @deps, "$distribution>=$requires->{$module}:$location";
    }
    unshift @deps, '' if $ports;
    @deps = sort @deps;
    join " \\\n\t\t\t\t", @deps;
}

=head2 create_makefile

Args: $metafile, $portupload_file, $man1, $man3

=cut

sub create_makefile {
    my $self            = shift;
    my $file            = shift;
    my $portupload_file = shift;
    my $man1            = shift;
    my $man3            = shift;
    open +( my $makefile ), '>', 'Makefile';
    print $makefile "# New ports collection makefile for:  $file->{name}\n";
    print $makefile "# Whom: $ENV{USER}\n";
    print $makefile "# Date created: " . `date "+\%d \%B \%Y"`;
    print $makefile "# \$FreeBSD\$\n";
    print $makefile
      "# Generated with portupload. Do not edit directly, please\n\n";
    print $makefile "PORTNAME=	$file->{name}\n";
    print $makefile "PORTVERSION=	$file->{version}\n";
    print $makefile "CATEGORIES=	$portupload_file->{category} perl5\n";
    print $makefile "MASTER_SITES=	"
      . ( $portupload_file->{master_sites} || 'CPAN' ) . "\n";
    print $makefile "PKGNAMEPREFIX=	p5-\n";
    print $makefile "\n";
    print $makefile "MAINTAINER=	$portupload_file->{maintainer}\n";
    print $makefile "COMMENT=	$file->{abstract}\n";
    print $makefile "\n";
    print $makefile "BUILD_DEPENDS=	"
      . $self->get_dependencies( $file->{requires} )
      . $self->get_dependencies( $portupload_file->{requires}, 1 ) . "\n";
    print $makefile "RUN_DEPENDS=\${BUILD_DEPENDS}\n";
    print $makefile "\n";
    print $makefile "USE_APACHE=" . $portupload_file->{apache} . "\n"
      if $portupload_file->{apache};
    print $makefile "PERL_CONFIGURE=	"
      . (
          $file->{requires}{perl}
        ? $self->perl_version_parse( $file->{requires}{perl} ) . "+"
        : 'YES'
      ) . "\n";
    print $makefile "MAN1=	" . $man1 . "\n" if $man1;
    print $makefile "MAN3=	" . $man3 . "\n" if $man3;
    print $makefile "\n";

    if ( $portupload_file->{additional} ) {
        print $makefile ".include <bsd.port.pre.mk>\n";
        $portupload_file->{additional} =~ s/ {4}/\t/g;
        print $makefile $portupload_file->{additional};
        print $makefile ".include <bsd.port.post.mk>\n";
    }
    else {
        print $makefile ".include <bsd.port.mk>\n";
    }
    close $makefile;
}

=head2 create_config

Creates config file for module

=cut

sub create_config {
    my ( $self, $name ) = @_;
    mkdir glob "~/.portupload";
    my ($package_name) = grep /^\Qp5-$name-\E[\d.]+/, keys %{ $self->{INDEX} };
    my $pkg_info       = $self->{INDEX}{$package_name};
    my $config         = {};
    my $suggested_category;
    ( $config->{category}, $suggested_category ) =
      $self->suggest_category( $name, $pkg_info->{categories} );
    $config->{category} ||= prompt( "Port category:", $suggested_category );
    my $maintainer_email = $pkg_info->{maintainer};

    if ( -e glob '~/.porttools' ) {
        $maintainer_email ||= `. ~/.porttools;echo \$EMAIL`;
        chomp $maintainer_email;
    }
    $config->{maintainer} = $maintainer_email
      || prompt( "Maintainer email:", "$ENV{USER}\@rambler-co.ru" );
    DumpFile( glob("~/.portupload/$self->{module}.yml"), $config );
}

=head2 run

Makes actually all work

=cut

sub run {
    my ($self) = @_;
    my ( $post_on_cpan, $submit_to_freebsd );

    GetOptions(
        'h|help' => sub {
            print
qq{Usage: $0 [ --info ] [ --no-tests ] [ --no-upload ] [ --no-commit ] [ --cpan ]\n};
            exit 0;
        },
        'info' => sub {
            $ENV{INFO_ONLY} = 1;
        },
        'no-tests' => sub {
            $ENV{NOTEST} = 1;
        },
        'no-upload' => sub {
            $ENV{NO_UPLOAD} = 1;
        },
        'no-commit' => sub {
            $ENV{NO_COMMIT} = 1;
        },
        'freebsd' => sub {
            $submit_to_freebsd = 1;
        }
    );

    my $cpan = CPANPLUS::Backend->new;
    my $module = $cpan->parse_module( module => $self->{module} );
    $module->fetch;
    chdir $module->extract;

    print ">>> Creating Makefile\n";
    $module->prepare;
    $module->test or die unless $ENV{NOTEST};
    my $file    = $self->load_meta;
    my $version = $file->{version};
    $self->create_config( $file->{name} )
      unless -f glob "~/.portupload/$self->{module}.yml";
    my $portupload_file = LoadFile( glob "~/.portupload/$self->{module}.yml" );
    my $ftp;
    printf qq{
    Tests:  %s
    Upload: %s
},
      $ENV{NOTEST}    ? 'no' : 'yes',
      $ENV{NO_UPLOAD} ? 'no' : $portupload_file->{master_sites},
      ;
    exit if $ENV{INFO_ONLY};

    my $man1 = join " \\\n\t\t", map { s{blib/man1/}{}; $_ } glob 'blib/man1/*';
    my $man3 = join " \\\n\t\t", map { s{blib/man3/}{}; $_ } glob 'blib/man3/*';
    my @pkg_plist = grep !/.exists$/, `find blib/lib -type f`;
    ( my $dist_path = $file->{name} ) =~ s{-}{/}g;
    push @pkg_plist,
      '%%SITE_PERL%%/%%PERL_ARCH%%/auto/' . $dist_path . '/.packlist' . "\n";
    push @pkg_plist, ( grep !/.exists$/, `find blib/script -type f` );
    push @pkg_plist,
      map { "\@dirrmtry $_" } grep { $_ } reverse `find blib/lib -type d`;
    push @pkg_plist,
      map { "\@dirrmtry $_" } grep { $_ } reverse `find blib/arch -type d`;
    push @pkg_plist, map { "\@dirrmtry $_" } reverse `find blib/script -type d`;
    @pkg_plist = map { $_ =~ s{blib/lib}{\%\%SITE_PERL\%\%}; $_ } @pkg_plist;
    @pkg_plist =
      map { $_ =~ s{blib/arch}{\%\%SITE_PERL\%\%/\%\%PERL_ARCH\%\%}; $_ }
      @pkg_plist;
    @pkg_plist = map { $_ =~ s{blib/script/}{bin/}; $_ } @pkg_plist;
    system("make -s clean");
    chdir tempdir();

    if (
        system(
"cvs -d :pserver:anoncvs\@anoncvs.tw.FreeBSD.org/home/ncvs co ports/$portupload_file->{category}/p5-$file->{name}"
        ) == 0
      )
    {
        chdir "ports/$portupload_file->{category}/p5-$file->{name}" or do {
            mkdir "ports";
            mkdir "ports/p5-$file->{name}" or die;
            chdir "ports/p5-$file->{name}" or die;
          }
    }

    $self->create_makefile( $file, $portupload_file, $man1, $man3 );
    open PLIST, '>', 'pkg-plist';
    if ( !$portupload_file->{distfiles} ) {
        print PLIST @pkg_plist;
    }
    else {
        print PLIST "\n";
    }
    close PLIST;
    open PDESCR, '>', 'pkg-descr';
    print PDESCR $file->{abstract};
    print PDESCR "\n\nWWW: http://search.cpan.org/~"
      . $module->author->cpanid . "/"
      . $file->{name} . "\n";
    if ( !system("$ENV{EDITOR} Makefile") ) {
        print ">>> Enter your root password:\n";
        system("sudo port fetch");
        if ( system("port test") ) {
            warn "test failed\n";
            unless ( $ENV{NOTEST} ) {
                exit;
            }
        }
        if ( -d 'CVS' ) {
            system("port submit -m update");
        }
        else {
            system("port submit -m new");
        }
    }

}

=head2 suggest_category

Tries to find category for module name.

=cut

sub suggest_category {
    my $self   = shift;
    my $module = shift;
    my ($root) = split /-/, $module;
    my $categories = shift;
    if ($categories) {
        return grep !/^perl$/, @$categories;
    }
    given ($root) {
        when (/^DBI(x)?|DBD$/) {
            return 'databases';
        }
        when (/^Catalyst|HTML|WWW$/) {
            return 'www';
        }
    }
    return undef, 'devel';
}

sub load_meta {
    my $self = shift;
    if ( -e 'META.json' ) {
        open +( my $f ), '<', 'META.json' or die $!;
        local $/ = undef;
        local $\ = undef;
        return JSON::XS::decode_json(<$f>);
    }
    else {
        return LoadFile('META.yml');
    }
}
1;

__END__

=head1 NAME

App::Pm2Port - Creates FreeBSD port from Perl module

=head1 SYNOPSYS

    cd port-directory
    pm2port Variable::Eject

=head1 LICENSE

This module is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=head1 AUTHOR

Andrey Kostenko E<lt>andrey@kostenko.nameE<gt>

=cut
