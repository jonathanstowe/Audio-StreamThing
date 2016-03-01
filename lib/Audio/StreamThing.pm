use v6;

use HTTP::Parser;
use HTTP::Header;

class Audio::StreamThing {

    has Int $.port is required;

    has %!mounts;
    has Supply $!connection-supply;

    sub index-buf(Blob $input, Blob $sub) returns Int {
        my $end-pos = 0;
        while $end-pos < $input.bytes {
            if $sub eq $input.subbuf($end-pos, $sub.bytes) {
                return $end-pos;
            }
            $end-pos++;
        }
        return -1;
    }


    method !handle-connection(IO::Socket::Async $conn) {
        say "got connection";
        my Buf $in-buf = Buf.new;
        my $header-promise = Promise.new;
        my $in-supply = $conn.Supply(:bin);
        my $tap = $in-supply.act( -> $buf { 
            $in-buf ~= $buf;
            if (my $header-end = index-buf($in-buf, Buf.new(13,10,13,10))) > 0 {
                my $header = $in-buf.subbuf(0, $header-end + 4);
                my $env = parse-http-request($header); #Hash;
                $env[1]<remaining-data> = $in-buf.subbuf($header-end + 4);
                $header-promise.keep: $env;
            }
        });
        my $header = $header-promise.result;
        $tap.close;
        say $header.perl;
        if $header[1]<REQUEST_METHOD> eq 'SOURCE' {
            say "this is a source client";
            my $supplier = Supplier.new;
            my $m = $header[1]<REQUEST_URI>;
            %!mounts{$m} = $supplier.Supply;
            my $stream-supply = $conn.Supply(:bin);
            $stream-supply.tap(-> $buf {
                $supplier.emit($buf);
            }, done => { say "source ending"; %!mounts{$m}:delete });
            await $conn.write: "HTTP/1.0 200 OK\r\n\r\n".encode;
        }
        elsif $header[1]<REQUEST_METHOD> eq 'GET' {
            my $m = $header[1]<REQUEST_URI>;
            if %!mounts{$m}:exists {
                my $h = HTTP::Header.new(Content-Type => 'audio/mpeg', Pragma => 'no-cache', icy-name => 'foo');
                my $conn-promise = Promise.new;
                $conn.Supply(:bin).tap({ say "unexpected content"}, done => { $conn-promise.keep: "done" }, quit => { say "quit" }, closing => { say "closing" });
                my $write-tap = %!mounts{$m}.tap(-> $buf {
                    if $conn-promise.status ~~ Planned {
                        $conn.write($buf);
                    }
                    else {
                        $write-tap.close;
                    }
                });
                await $conn.write( ("HTTP/1.0 200 OK\r\n" ~ $h.Str ~ "\r\n\r\n").encode);
            }
            else {
                await $conn.write( ("HTTP/1.0 404 Not Found\r\n\r\n").encode);
                $conn.close;
            }
        }
    }

    method run() {
        $!connection-supply = IO::Socket::Async.listen('localhost',$!port);
        $!connection-supply.tap(-> |c { self!handle-connection(|c) });
        $!connection-supply.wait;
    }

}
# vim: expandtab shiftwidth=4 ft=perl6
