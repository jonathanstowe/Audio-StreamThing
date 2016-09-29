use v6;

=begin pod

=head1 NAME

Audio::StreamThing - An Experimental Audio Streaming Server

=head1 SYNOPSIS

=begin code

use Audio::StreamThing;

my $server = Audio::StreamThing.new(port => 8898);

$server.run;

=end code

=head1 DESCRIPTION

=head1 METHODS


=end pod

use HTTP::Parser;
use HTTP::Header;
use HTTP::Status;
use HTTP::Server::Tiny;

class Audio::StreamThing {

    has Bool $.debug;
    has Int $.port is required;
    has Str $.host = '0.0.0.0';
    has HTTP::Server::Tiny $!http-server; # Maybe something else;

    method http-server() is rw returns HTTP::Server::Tiny {
        if not $!http-server.defined {
            $!http-server = HTTP::Server::Tiny.new(:$!host, :$!port);
        }
        $!http-server;
    }


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
            $!started = True;
        }
        method !debug(*@message) {
            $*ERR.say('[',DateTime.now,'][DEBUG] ', @message) if $!debug;
        }
    }

    role Output does Portal {
        has Channel $.channel = Channel.new;
    }

    class ClientOutput does Output does ClientPortal {
        method !debug(*@message) {
            $*ERR.say('[',DateTime.now,'][DEBUG] ', @message) if $!debug;
        }
        method start() {
            self!debug("starting output");
        # TODO use the content type and icy-name from the source
            my &done = sub {
                self!debug("output disconnected");
                $!finished-promise.keep: "done";
            }
            my &emit = sub {
                self!debug("unexpected content from client on mount '{ $!connection.url }'");
            }
            $!finished-promise.then({
                self.channel.close;
            });

            $!connection.Supply(:bin).tap(&emit, :&done , quit => { say "quit" }, closing => { say "closing" });
            $!started = True;
            return 200, [ Content-Type => $!content-type, Pragma => 'no-cache', icy-name => 'foo'], self.channel;
        }

    }

    

    class Mount {
        has Str     $.name;
        has Source  $.source handles <supply content-type bytes-sent>;
        has Output  %!outputs;
        has Promise $.finished-promise;
        has Bool    $.transient = True;
        has Bool    $.debug;

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
                if !$output.finished-promise {
                    $output.channel.send($buf);
                }
            });
            $output.finished-promise.then({
                self!debug("removing output");
                %!outputs{$which}:delete;
            });
            self.finished-promise.then({
                $output.finished-promise.keep: "mount closed";
            });
            return $output.start;
        }

        method start() {
            $!source.start;
        }

        method !debug(*@message) {
            $*ERR.say('[',DateTime.now,'][DEBUG] ', @message) if $!debug;
        }


    }



    class Server does Callable {
        has Bool $.debug;

        has %!mounts;
        has Supply $!connection-supply;

        has Supplier $!mount-create;
        has Supply   $.mount-create-supply;

        has Supplier $!mount-delete;
        has Supply   $.mount-delete-supply;

        method CALL-ME(Server:D: $environment) {
            my $connection = $environment<p6sgix.io>;
            my $client = ClientConnection.new(:$environment, :$connection);
            self!handle-connection($client);
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

        method !debug(*@message) {
            $*ERR.say('[',DateTime.now,'][DEBUG] ', @message) if $!debug;
        }



        method !handle-connection(ClientConnection $client) {
            self!debug("got connection");
            self!debug($client.perl);
            if $client.is-source {
                # TODO check authentication, refuse connect if the mount is in use
                self!debug("this is a source client");
                my $source = ClientSource.new(connection => $client, :$!debug);

                my $mount = Mount.new(name => $source.uri, :$source, :$!debug);
                $!mount-create.emit($mount);
                return 200, [ Content-Type => $mount.content-type ], supply { whenever $source.finished-promise { done; } };
            }
            elsif $client.is-client {
                self!debug("This is a client");
                my $m = $client.uri;
                if %!mounts{$m}:exists {
                    my $mount = %!mounts{$m};
                    self!debug("starting client output on $m");

                    my $output = ClientOutput.new(connection => $client, content-type => $mount.content-type, :$!debug);
                    return $mount.add-output($output);

                }
                else {
                    self!debug("Not a valid mount");
                    return 404, [Content-Type => 'text/plain'], ["Mount does not exist"];
                }
            }
            else {
                self!debug("Unhandled request");
                return 405, [Content-Type => 'text/plain', Allow => 'SOURCE, GET'], ["Bad request"];
            }
        }

        submethod BUILD(:$!debug) {
            $!mount-create = Supplier.new;
            $!mount-create-supply = $!mount-create.Supply;

            $!mount-delete = Supplier.new;
            $!mount-delete-supply = $!mount-delete.Supply;

            $!mount-create-supply.tap( -> |c { self!create-mount(|c) });
        }
    }

    has Server $!server;

    method server() is rw returns Server {
        if ! $!server.defined {
            $!server = Server.new(:$!debug);
        }
        $!server;
    }

    method run(Bool :$promise) {
        if $promise {
            my $control-promise = Promise.new;
            start { self.http-server.run(self.server, :$control-promise) };
            $control-promise;
        }
        else {
            self.http-server.run(self.server);
        }
    }
}
# vim: expandtab shiftwidth=4 ft=perl6
