use inc::Module::Install;

name     'App-Pm2Port';
abstract 'Creating port from perl module';
version '0.24';
author   q{Andrey Kostenko <andrey@kostenko.name>};
license  'perl';

build_requires 'Test::More';
requires 'YAML';
requires 'Term::ReadLine';
requires 'ExtUtils::MakeMaker';
requires 'File::Temp';
requires 'Getopt::Long';
requires 'CPAN';
requires 'FreeBSD::Ports::INDEXhash';
requires 'CPANPLUS';

install_script glob 'script/*';
auto_install;
repository 'http://developers.rambler.ru/svn/perlmodules/App-Pm2Port';

WriteAll;

