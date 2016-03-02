#!perl6

use v6;

use Test;

use Audio::StreamThing;
use Test::Util::ServerPort;
use Audio::Libshout;

my $port = get-unused-port();


my $obj;
lives-ok  { $obj = Audio::StreamThing.new(:$port); }, "create one on port $port";

my $password = 'hackme';
my $mount = '/mount';
my Int $byte-count = 0;

my $tap-create = $obj.mount-create-supply.tap( -> $m { 
    isa-ok $m, Audio::StreamThing::Mount, "got a Mount object (for create)";
    is $m.name, $mount, "and it is the mount we expected ( for create )";
    $tap-create.close;
});
my $delete-promise = Promise.new;

my $tap-delete = $obj.mount-delete-supply.tap( -> $m { 
    isa-ok $m, Audio::StreamThing::Mount, "got a Mount object (for delete)";
    is $m.name, $mount, "and it is the mount we expected ( for delete )";
    is $byte-count, $m.bytes-sent, "and we sent what we expected";
    $delete-promise.keep;
    $tap-delete.close;
});


my $p;

lives-ok { $p = $obj.run(:promise) }, "run with promise";
isa-ok $p, Promise, "and it is a promise";


my $file = $*PROGRAM.parent.child('data/cw_glitch_noise15.mp3').Str;
my $tp = $*PROGRAM.parent.child('bin/str-client').Str;

my $proc = Proc::Async.new($*EXECUTABLE, $tp, $port, $file, $password, $mount);


$proc.stdout.tap(-> $v { $byte-count += Int($v) });

diag "starting helper to send some data";
await $proc.start;
await $delete-promise;



done-testing;
# vim: expandtab shiftwidth=4 ft=perl6
