use v6;

=begin pod

=end pod

use HTTP::Parser;
use HTTP::Header;
use HTTP::Status;

class Audio::StreamThing {

    has Bool $.debug;
    has Int $.port is required;
    has Str $.host = '0.0.0.0';

    has %!mounts;
    has Supply $!connection-supply;

    has Supplier $!mount-create = Supplier.new;
    has Supply   $.mount-create-supply = $!mount-create.Supply;

    has Supplier $!mount-delete = Supplier.new;
    has Supply   $.mount-delete-supply = $!mount-delete.Supply;

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

    
    class Authentication {
        has Str $.tokens;
    }

    # TODO: make pluggable
    role Authentication::Basic {
        need MIME::Base64;
        has Str $.username;
        has Str $.password;

        method !decode-tokens() {
            ($!username, $!password ) = MIME::Base64.decode-str(self.tokens).split(':');
        }

        method username() returns Str {
            if !$!username.defined {
                self!decode-tokens();
            }
            $!username;
        }
        method password() returns Str {
            if !$!password.defined {
                self!decode-tokens();
            }
            $!password;
        }
    }

    class ClientConnection {
        has %.environment is required;
        has Blob $.remaining-data;
        has IO::Socket::Async $.connection is required handles <Supply>;

        method is-source() returns Bool {
            self.request-method eq 'SOURCE';
        }

        method is-client() returns Bool {
            self.request-method eq 'GET'; 
        }

        method request-method() returns Str {
            %!environment<REQUEST_METHOD>
        }

        method authentication() returns Authentication {
            if %!environment<HTTP_AUTHORIZATION> -> $auth {
                if $auth ~~ /\s*$<scheme>=[\w+]\s+$<tokens>=[.+]$$/ {
                    my $scheme = $/<scheme>.Str;
                    my $tokens = $/<tokens>.Str;
                    if ::("Authentication::$scheme") -> $role {
                        my $t = Authentication but $role;
                        $t.new(:$tokens);
                    }
                    else {
                        self!debug("Unknown authentication scheme $scheme");
                        Authentication;
                    }
                }
            }
            else {
                Authentication;
            }
        }

        method uri() returns Str {
            %!environment<REQUEST_URI>;
        }

        method content-type() returns Str {
            %!environment<CONTENT_TYPE>;
        }

        multi method send-response(Int $code, Str $body = '', *%headers) {
            my $h = HTTP::Header.new(|%headers);
            my $msg = get_http_status_msg($code);
            my $out = "HTTP/1.0 $code $msg\r\n$h\r\n\r\n$body".encode;
            self.write($out);
        }

        proto method write(|c) { * }

        multi method write(Blob $buf) returns Promise {
            $!connection.write($buf);
        }

        method close() {
            $!connection.close;
        }

        has Bool $.debug;
        method !debug(*@message) {
            $*ERR.say('[',DateTime.now,'][DEBUG] ', @message) if $!debug;
        }
    }

    class X::BadHeader is Exception {
        has $.message = "incomplete or malformed header in client request";
    }

    role Portal {
        has Bool     $.started;
        has Bool     $.debug;
        has Supplier $.supplier         = Supplier.new;
        has Supply   $.supply           = $!supplier.Supply;
        has Promise  $.finished-promise = Promise.new;
        has Str      $.content-type;
        has Int      $.bytes-sent       = 0;

        method start() {
            ...
        }

    }

    role Source does Portal {
    }


    role ClientPortal {
        has ClientConnection $.connection is required handles <uri content-type>;
    }

    class ClientSource does Source does ClientPortal {
        method start() {
            self!debug("source starting");
            my $stream-supply = $!connection.Supply(:bin);
            my &done = sub {
                self!debug("source ending");
                $!finished-promise.keep: "source ending";
            }
            $stream-supply.tap(-> $buf {
                $!bytes-sent += $buf.elems;
                $!supplier.emit($buf);
            }, :&done );
            await $!connection.send-response(200);
            $!started = True;
        }
        method !debug(*@message) {
            $*ERR.say('[',DateTime.now,'][DEBUG] ', @message) if $!debug;
        }
    }

    role Output does Portal {
    }

    class ClientOutput does Output does ClientPortal {
        method !debug(*@message) {
            $*ERR.say('[',DateTime.now,'][DEBUG] ', @message) if $!debug;
        }
        method start() {
        # TODO use the content type and icy-name from the source
            my &done = sub {
                $!finished-promise.keep: "done";
            }
            my &emit = sub {
                self!debug("unexpected content from client on mount '{ $!connection.url }'");
            }
            $!finished-promise.then({
                $!connection.close;
            });

            $!connection.Supply(:bin).tap(&emit, :&done , quit => { say "quit" }, closing => { say "closing" });
            my $write-tap = self.supply.tap(-> $buf {
                if $!finished-promise.status ~~ Planned {
                    $!connection.write($buf);
                }
                else {
                    $write-tap.close;
                }
            });
            my %h = Content-Type => $!content-type, Pragma => 'no-cache', icy-name => 'foo';
            await self.connection.send-response(200, |%h);
            $!started = True
        }

    }

    

    class Mount {
        has Str     $.name;
        has Source  $.source handles <supply content-type bytes-sent>;
        has Output  %!outputs;
        has Promise $.finished-promise;
        has Bool    $.transient = True;

        method finished-promise() returns Promise {
            if !$!finished-promise.defined {
                my $p = Promise.new;
                my $v = $p.vow;
                $.source.finished-promise.then({ $v.keep: "source closed" });
                $!finished-promise = $p;
            }
            $!finished-promise;
        }

        method outputs() {
            %!outputs.values;
        }

        method add-output(Output $output ) {
            my $which = $output.WHICH;
            %!outputs{$which} =  $output;
            self.supply.tap( -> $buf {
                $output.supplier.emit($buf);
            });
            $output.finished-promise.then({
                %!outputs{$which}:delete;
            });
            self.finished-promise.then({
                $output.finished-promise.keep: "mount closed";
            });
            $output.start;
        }

        method start() {
            $!source.start;
        }


    }

    method !debug(*@message) {
        $*ERR.say('[',DateTime.now,'][DEBUG] ', @message) if $!debug;
    }


    method !new-connection(IO::Socket::Async $conn) returns Promise {
        self!debug( "new connection");
        my Buf $in-buf = Buf.new;
        my $header-promise = Promise.new;
        self!debug("got promise");
        my $in-supply = $conn.Supply(:bin);
        self!debug("got supply");
        my $tap = $in-supply.act( -> $buf { 
            self!debug("got stuff");
            $in-buf ~= $buf;
            if (my $header-end = index-buf($in-buf, Buf.new(13,10,13,10))) > 0 {
                self!debug("got header");
                my $header = $in-buf.subbuf(0, $header-end + 4);
                my $env = parse-http-request($header);
                $tap.close;
                if $env[0] >= 0 {
                    my $remaining-data = $in-buf.subbuf($header-end + 4);
                    $header-promise.keep: ClientConnection.new(environment => $env[1], :$remaining-data, connection => $conn);
                }
                else {
                    X::BadHeader.new.throw;
                }
            }
        });
        self!debug("returning promise");
        $header-promise;
    }

    method !handle-connection(IO::Socket::Async $conn) {
        self!debug("got connection");
        my $client = self!new-connection($conn).result;
        self!debug($client.perl);
        if $client.is-source {
            # TODO check authentication, refuse connect if the mount is in use
            self!debug("this is a source client");
            my $source = ClientSource.new(connection => $client);

            my $mount = Mount.new(name => $source.uri, :$source);
            $!mount-create.emit($mount);
        }
        elsif $client.is-client {
            my $m = $client.uri;
            if %!mounts{$m}:exists {
                my $mount = %!mounts{$m};
                self!debug("starting client output on $m");

                my $output = ClientOutput.new(connection => $client, content-type => $mount.content-type);
                $mount.add-output($output);

            }
            else {
                await $client.send-response(404, Content-Type => 'text/plain');
                $client.close;
            }
        }
        else {
            my %h = Content-Type => 'text/plain', Allow => 'SOURCE, GET';
            await $client.send-response(405, |%h);
            $client.close;
        }
    }

    method !create-mount(Mount $mount) {
        self!debug("adding mount { $mount.name }");
        %!mounts{$mount.name} = $mount;
        $mount.finished-promise.then({
            self!debug("deleting mount { $mount.name }");
            %!mounts{$mount.name}:delete;
            $!mount-delete.emit($mount);
        });
        $mount.start;
        self!debug("started mount { $mount.name }");
    }

    method run(Bool :$promise) {
        $!connection-supply = IO::Socket::Async.listen($!host,$!port);
        my $tap = $!connection-supply.tap(-> |c { self!handle-connection(|c) });
        $!mount-create-supply.tap( -> |c { self!create-mount(|c) });
        if $promise {
            my $p = Promise.new;
            $p.then({$tap.close });
            $p;
        }
        else {
            $!connection-supply.wait;
        }
    }
}
# vim: expandtab shiftwidth=4 ft=perl6
