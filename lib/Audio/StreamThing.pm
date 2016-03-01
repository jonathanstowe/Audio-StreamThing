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

    class Connection {
        has %.environment is required;
        has Blob $.remaining-data;

        method is-source() returns Bool {
            self.request-method eq 'SOURCE';
        }

        method is-client() returns Bool {
            self.request-method eq 'GET'; 
        }

        method request-method() returns Str {
            %!environment<REQUEST_METHOD>
        }

        method uri() returns Str {
            %!environment<REQUEST_URI>;
        }
    }

    class X::BadHeader is Exception {
        has $.message = "incomplete or malformed header in client request";
    }

    method !new-connection(IO::Socket::Async $conn) returns Promise {
        my Buf $in-buf = Buf.new;
        my $header-promise = Promise.new;
        my $in-supply = $conn.Supply(:bin);
        my $tap = $in-supply.act( -> $buf { 
            $in-buf ~= $buf;
            if (my $header-end = index-buf($in-buf, Buf.new(13,10,13,10))) > 0 {
                my $header = $in-buf.subbuf(0, $header-end + 4);
                my $env = parse-http-request($header);
                $tap.close;
                if $env[0] >= 0 {
                    my $remaining-data = $in-buf.subbuf($header-end + 4);
                    $header-promise.keep: Connection.new(environment => $env[1], :$remaining-data);
                }
                else {
                    X::BadHeader.new.throw;
                }
            }
        });
        $header-promise;
    }

    method !handle-connection(IO::Socket::Async $conn) {
        say "got connection";
        my $header = self!new-connection($conn).result;
        say $header.perl;
        if $header.is-source {
            say "this is a source client";
            my $supplier = Supplier.new;
            my $m = $header.uri;
            %!mounts{$m} = $supplier.Supply;
            my $stream-supply = $conn.Supply(:bin);
            $stream-supply.tap(-> $buf {
                $supplier.emit($buf);
            }, done => { say "source ending"; %!mounts{$m}:delete });
            await $conn.write: "HTTP/1.0 200 OK\r\n\r\n".encode;
        }
        elsif $header.is-client {
            my $m = $header.uri;
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
