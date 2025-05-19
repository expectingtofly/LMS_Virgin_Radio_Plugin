package Plugins::VirginRadio::ProtocolHandler;

# Copyright (C) 2021 Stuart McLean

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

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Cache;

use HTTP::Date;
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Time::ParseDate;
use URI::Escape;
use Plugins::VirginRadio::VirginRadioFeeder;


Slim::Player::ProtocolHandlers->registerHandler('newsuk', __PACKAGE__);


my $log = logger('plugin.virginradio');
my $cache = Slim::Utils::Cache->new();
sub flushCache { $cache->cleanup(); }


use constant URL_ONAIR => 'https://virginradio.co.uk/api/get-station-data';


use constant CHUNK_SIZE => 1800;
use constant TRACK_OFFSET => 20;


sub new {
	my $class  = shift;
	my $args   = shift;

	$log->debug("New called ");


	my $client = $args->{client};

	my $song      = $args->{song};

	my $masterUrl = $song->track()->url;

	my $streamUrl = $song->streamUrl() || return;

	main::INFOLOG && $log->is_info && $log->info('Remote streaming Virgin Radio : ' . $streamUrl . ' actual url ' . $masterUrl);


	my $self = $class->SUPER::new(
		{
			url     => $streamUrl,
			song    => $song,
			client  => $client,
			bitrate => $song->bitrate() || 128_000,
		}
	) || return;


	${*$self}{contentType} = 'audio/mpeg';
	${*$self}{'song'}   = $args->{'song'};
	${*$self}{'client'} = $args->{'client'};
	my $isLive = _isLive($masterUrl);
	my $liveStation = '';
	my $liveStationName = '';
	if ($isLive) {
		$liveStation = _liveStation($masterUrl);
		$liveStationName = $song->pluginData('liveStationName');
	}
	${*$self}{'vars'} = {
		'isLive' => $isLive,
		'liveStation' => $liveStation,
		'liveStationName' => $liveStationName,
		'trackCycle' => 1,
	};

	if (_isAOD($masterUrl)) {
		my $streamDetails = $song->pluginData('streamDetails');

		$song->track->secs( $streamDetails->{durationSecs} );

		Slim::Music::Info::setDuration( $song->track(),  $streamDetails->{durationSecs} );
		my $meta = {
			title =>  $streamDetails->{title},
			artist => $streamDetails->{subtitle},
			duration => 	 $streamDetails->{durationSecs},
			cover => $streamDetails->{image},
			icon => $streamDetails->{image},
			type        => 'MP3 (Virgin Radio)',
		};

		$log->debug('meta : ' . Dumper($meta));

		$song->pluginData( meta  => $meta );

		$song->master->currentPlaylistUpdateTime(Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $song->master,['newmetadata'] );
	} else {
		if (_isLive($masterUrl)) {
			$self->liveMetaData();
			Slim::Utils::Timers::setTimer($self, (time() + 8), \&liveTrackData) if ($liveStation =~ /virgin/); 
		}
	}


	return $self;
}


sub close {
	my $self = shift;
	my $v = $self->vars;
	if ($v->{isLive}) {
		main::INFOLOG && $log->is_info && $log->info("killing meta data timer");
		Slim::Utils::Timers::killTimers($self, \&liveMetaData);
		Slim::Utils::Timers::killTimers($self, \&liveTrackData);
	}

	main::INFOLOG && $log->is_info && $log->info("end of streaming for ", ${*$self}{'song'}->track->url);

	$self->SUPER::close(@_);


}


sub canDirectStream {
	my ($classOrSelf, $client, $url, $inType) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug('Never direct stream');

	return 0;
}


sub vars {
	return ${ *{ $_[0] } }{'vars'};
}


sub getMetadataFor {
	my ( $class, $client, $full_url ) = @_;
	my $icon = $class->getIcon();

	my ($url) = $full_url =~ /([^&]*)/;
	my $song = $client->playingSong();

	#main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");

	if ( $song && $song->currentTrack()->url eq $full_url ) {

		if (my $meta = $song->pluginData('meta')) {

			#main::DEBUGLOG && $log->is_debug && $log->debug("meta from song");
			$song->track->secs( $meta->{duration} );
			return $meta;
		}
	}

	return {
		type  => 'VirginRadio',
		title => $url,
	};
}


sub getFormatForURL { 'mp3' }

sub isRemote { 1 }


sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;
	my $masterUrl = $song->track()->url;
	main::INFOLOG && $log->is_info && $log->info("Request for next track " . $masterUrl);
	
	if (_isLive($masterUrl)) {
		Plugins::VirginRadio::VirginRadioFeeder::getLiveStream(_liveStation($masterUrl), sub {
		my $streamUrl = shift->{streams}->{standard};
		if ($streamUrl) {

			main::DEBUGLOG && $log->is_debug && $log->debug("Setting Live Stream $streamUrl " . 128_000);

			$song->streamUrl($streamUrl);
			$song->track->bitrate(128_000);

			$successCb->();
		} else {
			$log->error("No such live stream");
			$errorCb->();
		}
		},
		sub {
			$log->error("No such live stream");
			$errorCb->();
		});

	}
	if (_isAOD($masterUrl)) {

		my $id = _AODUrlID($masterUrl);
		my $stationId = _AODUrlStationsID($masterUrl);
		main::DEBUGLOG && $log->is_debug && $log->debug("ID from URL is $id");
		_getStreamDetails($stationId, $id, $song, $successCb, $errorCb);

	}
}


sub _getStreamDetails {
	my ( $stationId, $id, $song, $successCb, $errorCb ) = @_;

	Plugins::VirginRadio::VirginRadioFeeder::getAODFromID(
		$stationId,
		$id,
		sub {
			my $JSON = shift;

			#The duration in the JSON is unreliable, so we have to work it out.

			my $dur = str2time( $JSON->{'endTime'} ) - str2time( $JSON->{'startTime'} );

			my $image;
			if (scalar @{$JSON->{'images'}}) {
				my @thumbnails = grep { $_->{'width'} == 720 && $_->{'metadata'}[0] eq 'thumbnail' } @{$JSON->{'images'}};
				$image = $thumbnails[0]->{'url'};
			}

			my $AOD_Details = {
				title => $JSON->{title},
				subtitle => $JSON->{description},
				durationSecs => $dur,
				track => $JSON->{recording}->{url},
				image => $JSON->{images}[0]->{url},
			};
			main::DEBUGLOG && $log->is_debug && $log->debug('Dump of AOD details  : ' .  Dumper($AOD_Details));

			$song->pluginData( streamDetails   => $AOD_Details );
			$song->duration($AOD_Details->{durationSecs} );

			#always a redirect for aod
			my $http = Slim::Networking::Async::HTTP->new;
			my $request = HTTP::Request->new( GET => $AOD_Details->{track} );
			$http->send_request(
				{
					request     => $request,
					onHeaders => sub {
						my $http = shift;
						my $trackurl = $http->request->uri->as_string;
						main::DEBUGLOG && $log->is_debug && $log->debug("Redirected AOD URL is : $trackurl");
						$song->streamUrl($trackurl);
						$song->track->bitrate(128_000);
						$http->disconnect;
						$successCb->();
					},
					onError => sub {
						my ( $http, $self ) = @_;
						my $res = $http->response;
						$log->error('Error status - ' . $res->status_line );
						$errorCb->();
					}
				}
			);

		},
		sub {
			$log->error("Failed to get AOD stream details for $id");
			$errorCb->();
		}
	);

}


sub isRepeatingStream {
	my ( undef, $song ) = @_;

	return 0;

}


sub canSeek {
	my ( $class, $client, $song ) = @_;

	my $masterUrl = $song->track()->url;

	if (_isAOD($masterUrl)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Can Seek');
		return 1;
	}else {
		return 0;
	}
}


sub liveTrackData{
	my $self = shift;

	my $v = $self->vars;

	my $client = ${*$self}{'client'};
	my $song = $client->playingSong();

	my $url = Plugins::VirginRadio::ProtocolHandler::URL_ONAIR . '?station=' . $v->{'liveStation'} . '&withSongs=1&hasPrograms='. $v->{'trackCycle'} . '&numberOfSongs=1';
	main::INFOLOG && $log->is_info && $log->info("Meta URL is : $url");

	$v->{'trackCycle'}++;  #special number to defeat virgin caching track info
	if ($v->{'trackCycle'} > 9) { $v->{'trackCycle'} = 1; }


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = ${$http->contentRef};

			main::DEBUGLOG && $log->is_debug && $log->debug('Reading Track data');

			#decode the json

			my $jsonTrack = decode_json $content;

			main::DEBUGLOG && $log->is_debug && $log->debug('Raw track meta Data : ' . $content);

			my $validFrom = str2time($jsonTrack->{recentlyPlayed}[0]->{startTime});
			my $validTo  = str2time($jsonTrack->{recentlyPlayed}[0]->{endTime});

			my $durSeconds = $validTo - $validFrom;

			main::DEBUGLOG && $log->is_debug && $log->debug("Time Data : $validFrom $validTo - $durSeconds -  time now : " . time() . ' tracks : ' . scalar @{$jsonTrack->{recentlyPlayed}} );
			if ($jsonTrack->{recentlyPlayed}[0]->{title}) {

				my $timenow = time();

				if ( ($timenow > $validFrom ) && ($validTo >= $timenow )) {
					
					if (my $meta = $song->pluginData('meta')) {
						$meta->{title} = $jsonTrack->{recentlyPlayed}[0]->{artist};
						$meta->{artist} = $jsonTrack->{recentlyPlayed}[0]->{title};

						main::DEBUGLOG && $log->is_debug && $log->debug('Dump of track meta data  : ' .  Dumper($meta));
						
						my $cb = sub {
							$song->pluginData( meta  => $meta );	
							main::DEBUGLOG && $log->is_debug && $log->debug('Setting Track Title callback');					
							Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
						};

						#the title will be set when the current buffer is done
						Slim::Music::Info::setDelayedCallback( $client, $cb );
						my $nextTimer = ($validTo + 10);

						if ($nextTimer < (time()+30)) {
							$nextTimer = (time()+30);
						}
						Slim::Utils::Timers::setTimer($self, $nextTimer, \&liveTrackData);
					} else {

						#not there come back in 2 minutes
						$log->warn('No Live meta data');
						Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveTrackData);
					}

				} else {

					#set it all back
					if (my $meta = $song->pluginData('meta')) {
						$meta->{title} = $meta->{realTitle};
						$meta->{artist} = $meta->{realArtist};

						main::DEBUGLOG && $log->is_debug && $log->debug('Setting title back');
						my $cb = sub {
							$song->pluginData( meta  => $meta );
							main::DEBUGLOG && $log->is_debug && $log->debug('Setting title back after callback');
							Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
						};

						#the title will be set when the current buffer is done
						Slim::Music::Info::setDelayedCallback( $client, $cb );
						Slim::Utils::Timers::setTimer($self, (time() + 60), \&liveTrackData);
					}else {

						#not there come back in 2 minutes
						$log->warn('No Live meta data');
						Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveTrackData);
					}
				}
			} else {				
				#not there come back in 5 minutes
				$log->info('No Live track data information');
				Slim::Utils::Timers::setTimer($self, (time() + 300), \&liveTrackData)
			}
		},
		,
		sub {
			#Couldn't get meta data
			$log->error('Failed to retrieve on recently played');

			#try again in 2 minutes
			Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveTrackData);
		}
	)->get($url);

	return;
}


sub liveMetaData {
	my $self = shift;

	my $v = $self->vars;

	Plugins::VirginRadio::VirginRadioFeeder::getOnAir($v->{'liveStation'},
	sub {
		my $jsonOnAir = shift;
		main::DEBUGLOG && $log->is_debug && $log->debug('Getting Meta Data');

		my $title =  $jsonOnAir->{'data'}->{onAirNow}->{title};
		my $description = $jsonOnAir->{'data'}->{onAirNow}->{description};
		my $duration = str2time( $jsonOnAir->{'data'}->{'onAirNow'}->{'endTime'} ) - str2time( $jsonOnAir->{'data'}->{'onAirNow'}->{'startTime'} );
		my $image;
		if (scalar @{$jsonOnAir->{'data'}->{'onAirNow'}->{'images'}}) {
			my @thumbnails = grep { $_->{'width'} == 720 && $_->{'metadata'}[0] eq 'thumbnail' } @{$jsonOnAir->{'data'}->{'onAirNow'}->{'images'}};
			$image = $thumbnails[0]->{'url'};
		}



			my $meta = {
				title =>  $title,
				realTitle => $title,
				artist => $description,
				realArtist => $description,
				album => $v->{'liveStationName'},
				cover => $image,
				icon => $image,
				duration => $duration,
				secs => $duration, 
				type        => 'MP3 (Virgin Radio)',
			};

			main::DEBUGLOG && $log->is_debug && $log->debug('Dump of Meta Data ' . Dumper($meta));

			my $progEndTime = str2time($jsonOnAir->{'data'}->{onAirNow}->{endTime});

			my $checkagain =  $progEndTime + 10;

			if ($checkagain < (time()+30)){
				$checkagain = time() + 120;
			}

			my $client = ${*$self}{'client'};
			my $song = $client->playingSong();
			
			my $offset =  time() - str2time( $jsonOnAir->{'data'}->{'onAirNow'}->{'startTime'} );

			main::INFOLOG && $log->is_info && $log->info("Offset is $offset from " . time());
					
			my $position_in_seconds = $client->songElapsedSeconds();
					

			#fix progress bar 
			$client->playingSong()->can('startOffset')
			? $client->playingSong()->startOffset( $offset - $position_in_seconds )
			: ( $client->playingSong()->{startOffset} = ($offset - $position_in_seconds) );
			
			$client->master()->remoteStreamStartTime( Time::HiRes::time() - $offset );
					
			$client->playingSong()->duration( $duration ); 
			$song->track->secs( $duration ); 
			
			Slim::Music::Info::setCurrentTitle( Slim::Player::Playlist::url($client), $title, $client ); 

			Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
			
			$song->pluginData( meta  => $meta );
			Slim::Control::Request::notifyFromArray( $client,['newmetadata'] );
			Slim::Utils::Timers::setTimer($self, $checkagain, \&liveMetaData);

		},
		sub {
			#Couldn't get meta data
			$log->error('Failed to retrieve on air text');

			#try again in 2 minutes
			Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveMetaData);
		}
	);
	return;
}


sub scanUrl {
	my ($class, $url, $args) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("scanurl $url");

	my $urlToScan = '';

	my $realcb = $args->{cb};


	if (_isLive($url)) {
		Plugins::VirginRadio::VirginRadioFeeder::getLiveStream(_liveStation($url), sub{
			my $node = shift;
			
			$urlToScan = $node->{streams}->{standard};
			my $stationName = $node->{name};

			$args->{cb} = sub {
				my $track = shift;

				my $client = $args->{client};
				my $song = $client->playingSong();

				if ( $song && $song->currentTrack()->url eq $url ) {					
					$song->pluginData( liveStationName => $stationName );					
				}

				$realcb->($args->{song}->currentTrack());
			};

			#let LMS sort out the real stream
			Slim::Utils::Scanner::Remote->scanURL($urlToScan, $args);

		},
		sub {
			$log->error("Failed to scan URL");
		});

	} else {
		$urlToScan = _AODUrl($url);

		$args->{cb} = sub {
			my $track = shift;

			my $client = $args->{client};
			my $song = $client->playingSong();
			main::DEBUGLOG && $log->is_debug && $log->debug("Setting bitrate");

			if ( $song && $song->currentTrack()->url eq $url ) {
				my $bitrate = $track->bitrate();
				main::DEBUGLOG && $log->is_debug && $log->debug("bitrate is : $bitrate");
				$song->bitrate($bitrate);
			}

			$realcb->($args->{song}->currentTrack());
		};

		#let LMS sort out the real stream
		Slim::Utils::Scanner::Remote->scanURL($urlToScan, $args);

	}

	main::DEBUGLOG && $log->is_debug && $log->debug("scanurl $url actual stream $urlToScan");

}


sub _AODUrlID {
	my ($url) = @_;

	my @urlsplit = split /_/x, $url;

	my $id = $urlsplit[3];

	return $id;
}

sub _AODUrlStationsID {
	my ($url) = @_;

	my @urlsplit = split /_/x, $url;

	my $id = $urlsplit[2];

	return $id;
}



sub _AODUrl {
	my ($url) = @_;

	my @urlsplit = split /_/x, $url;

	my $urlOut = $urlsplit[4];

	return uri_unescape($urlOut);
}


sub _isLive {
	my ($url) = @_;

	my @urlsplit = split /_/x, $url;
	if ($urlsplit[1] eq 'LIVE') {
		return 1;
	}
	return;
}


sub _liveStation {
	my ($url) = @_;

	my @urlsplit = split /_/x, $url;
	return $urlsplit[2];

}


sub _isAOD {
	my ($url) = @_;

	my @urlsplit = split /_/x, $url;
	if ($urlsplit[1] eq 'AOD') {
		return 1;
	}
	return;
}

1;