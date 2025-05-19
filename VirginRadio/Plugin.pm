package Plugins::VirginRadio::Plugin;

# Copyright (C) 2021 Stuart McLean stu@expectingtofly.co.uk

#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.


use warnings;
use strict;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::VirginRadio::VirginRadioFeeder;
use Plugins::VirginRadio::ProtocolHandler;
use Plugins::VirginRadio::CompatabilityHandler;
use Plugins::VirginRadio::RadioFavourites;

my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.virginradio',
		'defaultLevel' => 'WARN',
		'description'  => getDisplayName(),
	}
);

my $prefs = preferences('plugin.virginradio');


sub initPlugin {
	my $class = shift;

	$prefs->init(
		{
			is_radio => 0
		}
	);


	$class->SUPER::initPlugin(
		feed   => \&Plugins::VirginRadio::VirginRadioFeeder::toplevel,
		tag    => 'virginradio',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') && (!($prefs->get('is_radio'))) ? 1 : undef,
		weight => 1,
	);

	if ( !$::noweb ) {
		require Plugins::VirginRadio::Settings;
		Plugins::VirginRadio::Settings->new;
	}


	return;
}


sub postinitPlugin {
	my $class = shift;

	if (Slim::Utils::PluginManager->isEnabled('Plugins::RadioFavourites::Plugin')) {
		Plugins::RadioFavourites::Plugin::addHandler(
			{
				handlerFunctionKey => 'virginradio',      #The key to the handler				
				handlerSub 		=>  \&Plugins::VirginRadio::RadioFavourites::getStationData,          #The operation to handle getting the
				handlerSchedule =>	\&Plugins::VirginRadio::RadioFavourites::getStationSchedule,
			}
		);
	}

	Plugins::VirginRadio::VirginRadioFeeder::init();
	
	return;
}


sub getDisplayName { return 'PLUGIN_VIRGINRADIO'; }


sub playerMenu {
	my $class =shift;

	$log->info('Preference : ' . $prefs->get('is_radio'));

	if ($prefs->get('is_radio')  || (!($class->can('nonSNApps')))) {
		$log->info('Placing in Radio Menu');
		return 'RADIO';
	}else{
		$log->info('Placing in App Menu');
		return;
	}
}

1;
