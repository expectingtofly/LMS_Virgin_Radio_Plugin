package Plugins::VirginRadio::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.virginradio');

sub name {
    return 'PLUGIN_VIRGINRADIO';
}

sub page {
    return 'plugins/VirginRadio/settings/basic.html';
}

sub prefs {  
    return ( $prefs, qw(is_radio) );
}

1;