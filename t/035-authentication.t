#!perl6

use v6.c;

use Test;

use Audio::StreamThing;
use MIME::Base64;

my $user = 'source';
my $pwd  = 'hackme';

my $token = MIME::Base64.encode-str("$user:$pwd");

my $t;

lives-ok { $t = Audio::StreamThing::Authentication but Audio::StreamThing::Authentication::Basic }, "just check the type creation";
my $obj;
lives-ok { $obj = $t.new(tokens => $token); }, "create a new object based on the type";
is $obj.tokens, $token, "and we stored the token correctly";
is $obj.username, $user, "and got the right username";
is $obj.password, $pwd, "and password";


done-testing;
# vim: expandtab shiftwidth=4 ft=perl6
