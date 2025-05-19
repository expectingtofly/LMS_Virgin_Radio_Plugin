# Copyright (C) 2025 stu@expectingtofly.co.uk


package Plugins::VirginRadio::CompatabilityHandler;

use strict;

use Slim::Utils::Log;

Slim::Player::ProtocolHandlers->registerHandler('virgin', __PACKAGE__);

my $log = logger('plugin.virginradio');

sub canDirectStream { 0 }
sub contentType { 'Virgin' }
sub isRemote { 1 }


sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

    main::DEBUGLOG && $log->is_debug && $log->debug("URL to explode : $url");

    if ($url eq "virgin://_LIVE_vir") {
        $cb->(['newsuk://_LIVE_virginradiouk']);
        return;
    }    
    elsif ($url eq "virgin://_LIVE_chilled") {
        $cb->(['newsuk://_LIVE_virginradiochilled']);
        return;
    }
    elsif ($url eq "virgin://_LIVE_80splus") {
        $cb->(['newsuk://_LIVE_virginradio4']);
        return;
    }
    elsif ($url eq "virgin://_LIVE_britpop") {
        $cb->(['newsuk://_LIVE_virginradiobritpop']);
        return;
    }
    elsif ($url eq "virgin://_LIVE_legends") {
        $cb->(['newsuk://_LIVE_virginradiolegends']);
        return;
    }

    $log->error("Unknown URL ($url) select a station from the plugin");
    $cb->([]);
    return;

}

1;

