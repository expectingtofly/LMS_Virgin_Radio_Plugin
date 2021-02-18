package Plugins::VirginRadio::VirginRadioFeeder;

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

use URI::Escape;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Cache;

use Data::Dumper;
use POSIX qw(strftime);
use HTTP::Date;
use HTML::TreeBuilder::XPath;
use Digest::MD5 qw(md5_hex);

use Plugins::VirginRadio::Utilities;


my $log = logger('plugin.virginradio');
my $prefs = preferences('plugin.virginradio');

my $cache = Slim::Utils::Cache->new();
sub flushCache { $cache->cleanup(); }


sub toplevel {
	my ( $client, $callback, $args ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++toplevel");


	my $menu = [
		{
			name => 'Live Virgin Radio Stations',
			image    => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO,
			items => [
					{
						name        => 'Virgin Radio',
						type        => 'audio',
						cover       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO,
						image       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO,
						icon        => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO,
						url         => 'virgin://_LIVE_vir',
						on_select   => 'play'
					},
					{
						name        => 'Virgin Radio Anthems',
						type        => 'audio',
						cover       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOANTHEMS,
						image       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOANTHEMS,
						icon        => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOANTHEMS,
						url         => 'virgin://_LIVE_anthems',
						on_select   => 'play'
					},
					{
						name        => 'Virgin Radio Chilled',
						type        => 'audio',
						cover       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOCHILLED,
						image       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOCHILLED,
						icon        => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOCHILLED,
						url         => 'virgin://_LIVE_chilled',
						on_select   => 'play'
					},					,
					{
						name        => 'Virgin Radio Groove',
						type        => 'audio',
						cover       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOGROOVE,
						image       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOGROOVE,
						icon        => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOGROOVE,
						url         => 'virgin://_LIVE_groove',
						on_select   => 'play'
					}
					]
		},
		{
			name => 'Schedule',
			image => Plugins::VirginRadio::Utilities::IMG_SCHEDULE,
			type => 'link',
			url  => \&getDayMenu
		}
	];

	$callback->( { items => $menu } );

	main::DEBUGLOG && $log->is_debug && $log->debug("--toplevel");
	return;
}


sub getDayMenu {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getDayMenu");

	my $now       = time();
	my $stationid = $passDict->{'stationid'};
	my $NetworkDetails = $passDict->{'networkDetails'};

	my $menu      = [];


	for ( my $i = 0 ; $i < 8 ; $i++ ) {
		my $d = '';
		my $epoch = $now - ( 86400 * $i );
		if ( $i == 0 ) {
			$d = 'Today';
		}elsif ( $i == 1 ) {
			$d = 'Yesterday (' . strftime( '%A', localtime($epoch) ) . ')';
		}else {
			$d = strftime( '%A %d/%m', localtime($epoch) );
		}

		my $scheduledate = strftime( '%Y-%m-%d', localtime($epoch) );

		push @$menu,
		  {
			name        => $d,
			type        => 'link',
			url         => \&getSchedulePage,
			passthrough => [
				{
					scheduledate => $scheduledate
				}
			],
		  };

	}
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--getDayMenu");
	return;
}


sub getSchedulePage {
	my ( $client, $callback, $args, $passDict ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("++getSchedulePage");	


	my $menu = [];

	$log->info('Getting day menu');

	my $callUrl =  Plugins::VirginRadio::Utilities::URL_VIRGINSCHEDULE . $passDict->{'scheduledate'};

	if ( my $cachemenu = _getCachedMenu($callUrl) ) {

		$callback->( { items => $cachemenu } );
		main::DEBUGLOG && $log->is_debug && $log->debug("--getSchedulePage cached menu");	
		return;
	}


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;

			$log->debug('Schedule retreived');
			_parseSchedule( $http,  $menu);
			_cacheMenu($callUrl, $menu, 600);			

			$callback->( { items => $menu } );
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$callback->( [ { name => $_[1], type => 'text' } ] );
		}
	)->get($callUrl);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getSchedulePage");	
	return;

}


sub _parseSchedule {
	my $http        = shift;
	my $menu        = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseSchedule");	

	my $tree= HTML::TreeBuilder::XPath->new;
	$tree->parse_content( $http->contentRef);	
	my $scheduleNode = $tree->findnodes('/html/body/div[@id="page-wrapper"]/div/div[@id="main-wrapper"]//div[@id="radio-schedule"]');
	my $topNode = $scheduleNode->pop();	

	my $imageNodes = $topNode->findnodes('.//div[@class="schedule__pic"]/img');		
	my $scheduleNodes = $topNode->findnodes('.//div[@class="schedule__showtime"]');		
	my $showNameNodes = $topNode->findnodes('.//a[@class="schedule__showname"]');
	

	my $bound = (scalar @$scheduleNodes)-1;
	my $image = '';
	for my $i (0..$bound) {

		$image = @$imageNodes[$i]->attr('src');

		#workaround for broken virgin image
		if ($image =~ /virgin-radio-through-the-night/) {
			$image = Plugins::VirginRadio::Utilities::IMG_DEFAULT_IMAGE;
		}


		push @$menu,
		{
			name => @$scheduleNodes[$i]->string_value . ' ' . @$showNameNodes[$i]->string_value,
			image => $image,
			url => '',
			type => 'a',
			on_select   => ''		  
		}
	}

	my $AOD = $topNode->findnodes('.//a[@class = "btn btn--play btn--red listen-again"]');

	$bound = (scalar @$AOD)-1;

	for my $i2 (0..$bound) {
		my @epoch = split /\//, @$AOD[$i2]->attr('href');
		@$menu[$i2]->{url} = 'virgin://_AOD_' . pop @epoch;
		@$menu[$i2]->{type} = 'audio';
		@$menu[$i2]->{on_select}  = 'play';
	}

	$tree->delete;
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseSchedule");
}

sub _getCachedMenu {
	my $url = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_getCachedMenu");

	my $cacheKey = 'VR:' . md5_hex($url);

	if ( my $cachedMenu = $cache->get($cacheKey) ) {
		my $menu = ${$cachedMenu};
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu got cached menu");
		return $menu;
	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu no cache");
		return;
	}
}


sub _cacheMenu {
	my ( $url, $menu, $seconds ) = @_;	
	main::DEBUGLOG && $log->is_debug && $log->debug("++_cacheMenu");
	my $cacheKey = 'VR:' . md5_hex($url);
	$cache->set( $cacheKey, \$menu, $seconds );

	main::DEBUGLOG && $log->is_debug && $log->debug("--_cacheMenu");
	return;
}



1;