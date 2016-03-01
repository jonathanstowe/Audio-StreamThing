# Audio::StreamThing

A very rudimentary audio streaming server

## Synopsis

```
use Audio::StreamThing;

my $server = Audio::StreamThing.new(port => 8898);

$server.run;
```

## Description

I started making this as I wanted a simple [Icecast](http://icecast.org/)
compatible server to test [Audio::Libshout](https://github.com/jonathanstowe/Audio-Libshout)
but when I realised that it could actually handle more than one
client at once I thought I'd make it into a proper server :)


