#!perl -w
use strict;
use Test::More;
use WWW::Mechanize::FireFox;
use URI::file;
use Cwd;
use File::Basename;

my $mech = eval {WWW::Mechanize::FireFox->new( 
    autodie => 0,
    #log => [qw[debug]]
)};

if (! $mech) {
    my $err = $@;
    plan skip_all => "Couldn't connect to MozRepl: $@";
    exit
} else {
    plan tests => 2;
};

isa_ok $mech, 'WWW::Mechanize::FireFox', "The first instance";

my $second;
my $res = eval {
    $second = WWW::Mechanize::FireFox->new( 
            autodie => 0,
            #log => [qw[debug]]
    );
    1
};
my $err = $@;
ok $res, "We can get a second Mechanize instance";
is $err, '', "No error was raised";

isa_ok $second, 'WWW::Mechanize::FireFox', "The second instance";