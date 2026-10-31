#!/usr/bin/perl
# Loads MediaBridge.dylib inside Apple's perl and hands control to it.
use strict;
use warnings;
use DynaLoader;

$| = 1;
my $dylib = shift @ARGV or die "usage: media.pl <MediaBridge.dylib>\n";
my $lib = DynaLoader::dl_load_file($dylib) or die "load failed: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "notchlite_run")
    || DynaLoader::dl_find_symbol($lib, "_notchlite_run")
    or die "symbol notchlite_run not found\n";
DynaLoader::dl_install_xsub("main::notchlite_run", $sym);
notchlite_run();
