#!perl6

use v6.c;

use Test;

use Audio::StreamThing;

my $obj;

lives-ok { $obj = Audio::StreamThing.new(port => 8898) }, "create object";
isa-ok $obj, Audio::StreamThing, "and it's the right type of thing";
is $obj.port, 8898, "got the port";
is $obj.host, '0.0.0.0', "and the default host";

isa-ok $obj.http-server, 'HTTP::Server::Tiny', "got the http-server";


done-testing;
# vim: expandtab shiftwidth=4 ft=perl6
