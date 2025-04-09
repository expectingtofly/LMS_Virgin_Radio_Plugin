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
use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);

use Plugins::VirginRadio::Utilities;


my $log = logger('plugin.virginradio');
my $prefs = preferences('plugin.virginradio');

my $cache = Slim::Utils::Cache->new();

my $isRadioFavourites;

sub flushCache { $cache->cleanup(); }


sub init {
	$isRadioFavourites = Slim::Utils::PluginManager->isEnabled('Plugins::RadioFavourites::Plugin');
}


sub toplevel {
	my ( $client, $callback, $args ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++toplevel");

	my $liveMenu = [
		{
			name        => 'Virgin Radio UK',
			type        => 'audio',
			cover       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO,
			image       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO,
			icon        => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO,
			url         => 'virgin://_LIVE_vir',

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
		},
		{
			name        => 'Virgin Radio 80s Plus',
			type        => 'audio',
			cover       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO80SPLUS,
			image       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO80SPLUS,
			icon        => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO80SPLUS,
			url         => 'virgin://_LIVE_80splus',
			on_select   => 'play'
		},
		{
			name        => 'Virgin Radio Legends',
			type        => 'audio',
			cover       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOLEGENDS,
			image       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOLEGENDS,
			icon        => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOLEGENDS,
			url         => 'virgin://_LIVE_legends',
			on_select   => 'play'
		},
		{
			name        => 'Virgin Radio Britpop',
			type        => 'audio',
			cover       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOBRITPOP,
			image       => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOBRITPOP,
			icon        => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOBRITPOP,
			url         => 'virgin://_LIVE_britpop',
			on_select   => 'play'
		}
	];
	if ($isRadioFavourites) {
		@$liveMenu[0]->{itemActions} = getItemActions('Virgin Radio UK','virgin://_LIVE_vir', 'vir');		
		@$liveMenu[2]->{itemActions} = getItemActions('Virgin Radio Chilled','virgin://_LIVE_chilled', 'chilled');
		@$liveMenu[3]->{itemActions} = getItemActions('Virgin Radio 80s PLUS','virgin://_LIVE_80splus', '80splus');
		@$liveMenu[3]->{itemActions} = getItemActions('Virgin Radio Legends','virgin://_LIVE_legends', 'legends');
		@$liveMenu[3]->{itemActions} = getItemActions('Virgin Radio Britpop','virgin://_LIVE_britpop', 'britpop');
	}

	my $menu = [
		{
			name => 'Live Virgin Radio Stations',
			image    => Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO_LIVE,
			items => $liveMenu
		},
		{
			name => 'Schedule & Catchup',
			image => Plugins::VirginRadio::Utilities::IMG_SCHEDULE,
			type => 'link',
			url  => \&getDayMenu
		}
	];

	$callback->( { items => $menu } );

	main::DEBUGLOG && $log->is_debug && $log->debug("--toplevel");
	return;
}


sub getItemActions {
	my $name = shift;
	my $url = shift;
	my $key = shift;

	return  {
		info => {
			command     => ['radiofavourites', 'addStation'],
			fixedParams => {
				name => $name,
				stationKey => $key,
				url => $url,
				handlerFunctionKey => 'virginradio'
			}
		},
	};
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


	if ( my $cachemenu = _getCachedMenu('VIRGINRADIO_SCHEDULE_MENU' . $passDict->{'scheduledate'}) ) {

		$callback->( { items => $cachemenu } );
		main::DEBUGLOG && $log->is_debug && $log->debug("--getSchedulePage cached menu");
		return;
	}

	my $menu = [];

	getScheduleAsJSON(
		sub {
			my $schedJSON = shift;
			_parseSchedule($schedJSON, $menu, $passDict->{'scheduledate'} );
			_cacheMenu('VIRGINRADIO_SCHEDULE_MENU' . $passDict->{'scheduledate'}, $menu, 600);
			$callback->( { items => $menu } );
		},
		sub {
			$log->error("Could not retreive schedule menu");
			$callback->( [ { name => 'Error retrieving schedule', type => 'text' } ] );
		}
	);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getSchedulePage");
	return;
}


sub getScheduleAsJSON {
	my ( $cbY, $cbN ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getScheduleAsJSON");
	if (my $cachedSched = _getCachedMenu('VIRGIN_RADIO_SCHEDULE')) {
		main::DEBUGLOG && $log->is_debug && $log->debug("++cachedSchedule");
		$cbY->($cachedSched);
	} else {	

		getAccessToken(sub {
			my $token = shift;			

			my $session = Slim::Networking::Async::HTTP->new;

			my $tod = time();
			my $week =  $tod - ( 86400 * 7 );

			my $request =HTTP::Request->new( POST => 'https://api.news.co.uk/audio/v1/graph' );
			$request->header( 'Content-Type' => 'application/json' );
			$request->header( 'Authorization'    => "Bearer $token" );

			my $body = '{'. '"operationName":"GetRadioSchedule",'. '"variables":{"from":"'. strftime( '%Y-%m-%d', localtime($week) ) . '","to":"'. strftime( '%Y-%m-%d', localtime($tod) ) . '"},"query":"query GetRadioSchedule($from: Date, $to: Date) {\n  schedule(stationId: virginradiouk, from: $from, to: $to) {\n    id\n    date\n    shows {\n      id\n      title\n      description\n      startTime\n      endTime\n      recording {\n        url\n        __typename\n      }\n      images {\n        url\n        width\n        metadata\n        __typename\n      }\n      __typename\n    }\n    __typename\n  }\n}\n"}';

			$request->content($body);

			$session->send_request(
				{
					request => $request,
					onBody  => sub {
						my ( $http, $self ) = @_;
						my $res = $http->response;
						main::DEBUGLOG && $log->is_debug && $log->debug("Have Schedule ");
						my $sched = _parseScheduleJSON($res->content);

						_cacheMenu('VIRGIN_RADIO_SCHEDULE', $sched, 600);
						$cbY->($sched);
					},
					onError => sub {
						my ( $http, $self ) = @_;
						my $res = $http->response;
						$log->error( 'Error status - ' . $res->status_line );
						$cbN->();
					}
				}
			);

		},
		sub {
			$log->error( "Could not get API token" );
			$cbN->();
		});
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--getSchedule");
	return;
}


sub getAODFromID {
	my ($id, $cbY, $cbN) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getAODFromID");

	getScheduleAsJSON(
		sub {
			my $JSON = shift;
			if (my $itemJSON = _findRecordingFromID($id, $JSON)) {
				$cbY->($itemJSON);
			} else {
				$cbN->();
			}
		},
		$cbN
	);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getAODFromID");
	return;
}


sub _findRecordingFromID {
	my ($id, $scheduleJSON) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_findRecordingFromID");

	my $scheduleJSONNode = $scheduleJSON->{data}->{schedule};

	for my $schedN (@$scheduleJSONNode) {
		my $items = $schedN->{shows};
		for my $item (@$items) {
			if ($item->{id} eq $id) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Recording found for $id ");
				return $item;
			}
		}
	}

	$log->warn("Recording not found for id $id");
	main::DEBUGLOG && $log->is_debug && $log->debug("--_findRecordingFromID");
	return;
}


sub _parseScheduleJSON {
	my $sched        = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseScheduleJSON : " .  $sched );



	my $schedule = decode_json $sched;

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseScheduleJSON");

	return $schedule;
}


sub _parseSchedule {
	my $scheduleJSON = shift;
	my $menu        = shift;
	my $scheduleDate = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseSchedule");


	my $scheduleJSONNode = $scheduleJSON->{data}->{schedule};

	for my $schedN (@$scheduleJSONNode) {
		if ($schedN->{date} eq $scheduleDate) {
			my $items = $schedN->{shows};
			for my $item (@$items) {

				my $sttim = str2time( $item->{'startTime'} );
				my $sttime = strftime( '%H:%M ', localtime($sttim) );

				if (defined $item->{recording}) {
					push @$menu,
					  {
						name => $sttime . ' ' . $item->{title} . ' - ' . $item->{description},
						image => $item->{images}[0]->{url},
						url => 'virgin://_AOD_' . $item->{id} . '_' . uri_escape($item->{recording}->{url}),
						type => 'audio',
						on_select   => 'play'
					  };
				} else {
					push @$menu,{
						name => $sttime . ' ' . $item->{title} . ' - ' . $item->{description},
						image => $item->{images}[0]->{url}

					};
				}
			}
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseSchedule");
	return;
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

sub getAccessToken {
	my $cbY = shift;
	my $cbN = shift;

	if (my $token = _getCachedMenu('https://www.thetimes.com/radio/token')) {
		$cbY->($token);
	} else {	
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $JSON = decode_json ${ $http->contentRef };
				my $token = $JSON->{'access_token'};
				_cacheMenu('https://www.thetimes.com/radio/token', $token, 86400);
				$cbY->($token);
			},
			sub {
				# Called when no response was received or an error occurred.
				$log->warn("error: $_[1]");
				$cbN->();
			}
		)->get("https://www.thetimes.com/radio/token");
	}
}



1;
