# Audio::StreamThing

A very rudimentary and experimental audio streaming server.

## Synopsis

```
use Audio::StreamThing;

my $server = Audio::StreamThing.new(port => 8898);

$server.run;
```

## Description

I started making this as I wanted a simple
[Icecast](http://icecast.org/) compatible server to test
[Audio::Libshout](https://github.com/jonathanstowe/Audio-Libshout) but
when I realised that it could actually handle more than one client at
once I thought I'd make it into a proper server :)

## Installation



## Support

This should be considered highly experimental and is subject to sudden
incompatible changes without warning.

Please send any bug reports, patches and suggestions via
https://github.com/jonathanstowe/Audio-StreamThing/issues

## Licence and Copyright

© Jonathan Stowe, 2016

This is free software, see the [LICENCE](LICENCE) file for details.


