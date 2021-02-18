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

use POSIX;
use HTTP::Date;
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Time::ParseDate;

Slim::Player::ProtocolHandlers->registerHandler('virgin', __PACKAGE__);


my $log = logger('plugin.virginradio');
my $cache = Slim::Utils::Cache->new();
sub flushCache { $cache->cleanup(); }


use constant URL_AOD => 'https://virginradio.co.uk/radio/listen-again/';
use constant URL_CDN => 'https://cdn2.talksport.com/tscdn/virginradio/audio/listenagain/';
use constant URL_IMAGES => 'https://cdn2.talksport.com/tscdn/virginradio/schedulepage-images/';
use constant URL_LIVESTREAM => 'https://radio.virginradio.co.uk/stream';
use constant URL_ONAIR => 'https://virginradio.co.uk/sites/default/files/on_air_now_json_virgin.js';
use constant URL_RECENTLYPLAYED => 'https://virginradio.co.uk/sites/virginradio.co.uk/files/nocache/now_lastsongs_json.json';
use constant CHUNK_SIZE => 1800;


sub new {
	my $class  = shift;
	my $args   = shift;

	$log->debug("New called ");


	my $client = $args->{client};

	my $song      = $args->{song};

	my $masterUrl = $song->track()->url;

	my $streamUrl = $song->streamUrl() || return;

	$log->info( 'Remote streaming Virgin Radio : ' . $streamUrl . ' actual url ' . $masterUrl);


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
	${*$self}{'vars'} = {'isLive' => _isLive($masterUrl),};

	if (_isAOD($masterUrl)) {
		my $streamDetails = $song->pluginData('streamDetails');

		$song->track->secs( $streamDetails->{durationSecs} );

		Slim::Music::Info::setDuration( $song->track(),  $streamDetails->{durationSecs} );
		my $meta = {
			title =>  $streamDetails->{title} . ' - ' .  $streamDetails->{subtitle},
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
			Slim::Utils::Timers::setTimer($self, (time() + 8), \&liveTrackData);
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


sub vars {
	return ${ *{ $_[0] } }{'vars'};
}


sub getMetadataFor {
	my ( $class, $client, $full_url ) = @_;
	my $icon = $class->getIcon();

	my ($url) = $full_url =~ /([^&]*)/;
	my $song = $client->playingSong();

	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");

	if ( $song && $song->currentTrack()->url eq $full_url ) {

		if (my $meta = $song->pluginData('meta')) {

			main::DEBUGLOG && $log->is_debug && $log->debug("meta from song");
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

	#Live is straightforward
	if (_isLive($masterUrl)) {

		main::INFOLOG && $log->is_info && $log->info("Setting Live Stream " . URL_LIVESTREAM);

		$song->streamUrl(Plugins::VirginRadio::ProtocolHandler::URL_LIVESTREAM);

		$successCb->();
	}
	if (_isAOD($masterUrl)) {

		#AOD
		my $nextIndex = $song->pluginData('nextPlaylistIndex');


		if (defined $nextIndex) {
			my $details = $song->pluginData('streamDetails');

			#we may be at the end
			if ($nextIndex >= $details->{playlistSize}) {
				main::INFOLOG && $log->is_info && $log->info("the end");
				return;
			}

			my $playlist = $details->{playlist};

			my $sources = @$playlist[$nextIndex]->{sources};
			my $stream = @$sources[0]->{src};
			$song->streamUrl($stream);
			$song->pluginData( nextTrackOffset   => ($nextIndex * CHUNK_SIZE) );

			$nextIndex++;
			$song->pluginData( nextPlaylistIndex   => $nextIndex );


			$successCb->();
		}else {
			my $epoch = _AODUrlEpoch($masterUrl);
			_getStreamDetails($epoch, $song, $successCb);
		}
	}
}


sub _getStreamDetails {
	my ( $epoch, $song, $successCb ) = @_;

	my $callUrl = Plugins::VirginRadio::ProtocolHandler::URL_AOD . $epoch;


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = ${$http->contentRef};

			#playlist
			my $playlist ='';
			my $start ='';
			my $end = '';
			($start, $playlist, $end) = $content =~ /(vid\.playlist\(\[)(.*)(\,]\);)/gs;
			$playlist = '[' . $playlist . ']';

			#fix up to make json comapatible
			$playlist =~ s/sources:/"sources":/ig;
			$playlist =~ s/src:/"src":/ig;
			$playlist =~ s/type:/"type":/ig;


			$log->debug('Playlist  : ' .  $playlist);


			my $jsonPlaylist = decode_json $playlist;

			#titles
			my $title = '';
			($start, $title, $end) = $content =~ /(<h2 class="h2radioshowheader listen-again__title">)(.*)(<\/h2>)/;
			$log->debug('Title  : ' .  $title);

			my $subTitle = '';
			($start, $subTitle, $end) = $content =~ /(<h3 class="h3radioshowheader listen-again__subtitle">)(.*)(<\/h3>)/;
			$log->debug('Subtitle  : ' .  $subTitle);

			my $image = $title;
			$image =~ s/ /-/ig;
			$image = lc $image;
			$image = Plugins::VirginRadio::ProtocolHandler::URL_IMAGES . $image . '.jpg';

			my $playlistsize = scalar @$jsonPlaylist;
			my $duration = $playlistsize * 30 * 60;

			$log->debug($playlistsize . ' : ' .  $duration);

			my $AOD_Details = {
				title => $title,
				subtitle => $subTitle,
				playlistSize => $playlistsize,
				durationSecs => $duration,
				playlist => $jsonPlaylist,
				image => $image,

			};

			$log->debug('dump  : ' .  Dumper($AOD_Details));

			$song->pluginData( streamDetails   => $AOD_Details );
			$song->pluginData( nextPlaylistIndex   => 1 );
			$song->pluginData( nextTrackOffset   => 0 );

			my $sources = @$jsonPlaylist[0]->{sources};
			my $stream = @$sources[0]->{src};
			$song->duration($duration);
			$song->streamUrl($stream);

			$successCb->();

		},

		# Called when no response was received or an error occurred.
		sub {
			$log->error("error: $_[1]");

		}
	)->get($callUrl);

}


sub isRepeatingStream {
	my ( undef, $song ) = @_;

	my $masterUrl = $song->track()->url;

	$log->debug('In repeating ' . $masterUrl);

	if (_isAOD($masterUrl)) {
		return 1;
	}else {
		return 0;
	}
}


sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;

	my $song = ${*$class}{'song'} if blessed $class;

	if (!$song && $client->controller()->songStreamController()) {
		$song = $client->controller()->songStreamController()->song();
	}

	my $details = $song->pluginData('streamDetails');


	if (defined $details) {

		my $bitrate     = $client->streamingSong->bitrate || 128_000;
		my $contentType = 'mp3';

		# Clear previous duration, since we're using the same URL for all tracks
		Slim::Music::Info::setDuration( $url, 0 );

		# Grab content-length for progress bar
		my $length;
		my $rangelength;

		foreach my $header (@headers) {
			if ( $header =~ /^Content-Length:\s*(.*)/i ) {
				$length = $1;
			}elsif ( $header =~ m{^Content-Range: .+/(.*)}i ) {
				$rangelength = $1;
				last;
			}
		}

		if ($rangelength) {
			$length = $rangelength;
		}


		$length = $length * $details->{playlistSize};


		main::INFOLOG && $log->info( 'Direct Headers read '  . $details->{durationSecs} );

		$client->streamingSong->bitrate($bitrate);
		$client->streamingSong->duration( $details->{durationSecs});

		my $startOffset = $song->pluginData('nextTrackOffset');
		if ($startOffset) {
			$song->startOffset($startOffset);
			main::INFOLOG && $log->info("Offsetting $startOffset");
		}

		# title, bitrate, metaint, redir, type, length, body
		return (undef, $bitrate, 0, undef, $contentType, $length, undef);
	}else {

		#Must be live stream
		main::INFOLOG && $log->info("Live Parse Headers");
		return $class->SUPER::parseDirectHeaders($client, $url, @headers);
	}
}


sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;

	main::INFOLOG && $log->info( 'Trying to seek ' . $newtime );

	#may need to switch chunked stream
	my $details = $song->pluginData('streamDetails');

	my $newIndex = floor($newtime / CHUNK_SIZE);

	my $playlist = $details->{playlist};

	my $sources = @$playlist[$newIndex]->{sources};
	my $stream = @$sources[0]->{src};

	$song->streamUrl($stream);

	my $offset = ( ($song->bitrate || 128_000) / 8 ) * (CHUNK_SIZE * $newIndex);

	main::INFOLOG && $log->info( 'Stream is ' . $stream . ' index ' . $newIndex . ' offset ' . $offset);

	$newIndex++;
	$song->pluginData( nextPlaylistIndex   => $newIndex );
	$song->pluginData( nextTrackOffset   => 0 );


	return {
		sourceStreamOffset => (( ($song->bitrate || 128_000) / 8 ) * $newtime) - $offset,
		timeOffset         => $newtime,
	};
}


sub canSeek {
	my ( $class, $client, $song ) = @_;


	my $masterUrl = $song->track()->url;

	$log->debug('Can Seek ' . $masterUrl);

	if (_isAOD($masterUrl)) {
		return 1;
	}else {
		return 0;
	}
}


sub liveTrackData{
	my $self = shift;

	my $client = ${*$self}{'client'};
	my $song = $client->playingSong();


	$log->debug('In readtrack ');
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = ${$http->contentRef};

			$log->info('Getting track Data');

			$log->debug('Response ' . $content);

			#decode the json
			$content =~ s/^jsonCallback_virgin\(//;
			$content =~ s/\);$//;
			my $jsonTrack = decode_json $content;

			$log->debug('json ' . Dumper($jsonTrack));

			my $validFrom = $jsonTrack->{nowplaying}[0]->{time};
			my $duration  = $jsonTrack->{nowplaying}[0]->{duration};

			my $durSeconds = parsedate($duration, NOW => 0); 

			$log->debug('actual ' . $durSeconds  .  ' could be ' . parsedate($duration) );

			$durSeconds = 180 if $durSeconds >180; # Never go more than 3 minutes

			my $validTime =  str2time($validFrom);
			my $validEndTime = $validTime + $durSeconds;
			$log->debug('now ' . time()  .  ' when ' . $validTime . ' to ' . $validEndTime);
			

			if (($validEndTime >time()) && ($validEndTime-time() > 30) ) {
				my $artist = $jsonTrack->{nowplaying}[0]->{artist};
				my $title = $jsonTrack->{nowplaying}[0]->{title};
				my $image = $jsonTrack->{nowplaying}[0]->{imageUrl};
				my $album = $jsonTrack->{nowplaying}[0]->{album};

				if (my $meta = $song->pluginData('meta')) {
					$meta->{title} = "$title  by $artist ($album)";
					$meta->{icon} =  $image;
					$meta->{cover} =  $image;


					my $cb = sub {
						$song->pluginData( meta  => $meta );
						main::INFOLOG && $log->is_info && $log->info("Setting title after callback");
						Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
					};

					#the title will be set when the current buffer is done
					Slim::Music::Info::setDelayedCallback( $client, $cb, 'output-only' );
					Slim::Utils::Timers::setTimer($self, $validEndTime, \&liveTrackData);
				} else {

					#not there come back in 2 minutes
					$log->warn('No Live meta data');
					Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveTrackData);
				}

			}else {
				#set it all back
				if (my $meta = $song->pluginData('meta')) {					
					$meta->{title} = $meta->{realTitle};
					$meta->{icon} =  $meta->{realIcon};
					$meta->{cover} =  $meta->{realCover};

					my $cb = sub {
						$song->pluginData( meta  => $meta );
						main::INFOLOG && $log->is_info && $log->info("Setting title back after callback");
						Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
					};

					#the title will be set when the current buffer is done
					Slim::Music::Info::setDelayedCallback( $client, $cb, 'output-only' );
					Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveTrackData);
				}else {

					#not there come back in 2 minutes
					$log->warn('No Live meta data');
					Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveTrackData);
				}
			}
		},
		,
		sub {
			#Couldn't get meta data
			$log->error('Failed to retrieve on recently played');

			#try again in 2 minutes
			Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveTrackData);
		}
	)->get(Plugins::VirginRadio::ProtocolHandler::URL_RECENTLYPLAYED);
}


sub liveMetaData {
	my $self = shift;

	my $v = $self->vars;


	$log->debug('In readMetaData ');
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = ${$http->contentRef};

			$log->info('Getting MetaData');

			$log->debug('Response ' . $content);

			#decode the json
			$content =~ s/^jsonCallback\(//;
			$content =~ s/\);$//;
			my $jsonOnAir = decode_json $content;

			my $title =  $jsonOnAir->{vir}->{show};

			my $image = $title;
			$image =~ s/ /-/ig;
			$image = lc $image;
			$image = Plugins::VirginRadio::ProtocolHandler::URL_IMAGES . $image . '.jpg';


			my $meta = {
				title =>  $title,
				realTitle => $title,
				artist => 'Virgin Radio',
				cover => $image,
				realCover => $image,
				icon => $image,
				realIcon =>$image,
				type        => 'MP3 (Virgin Radio)',
			};

			$log->debug('Meta Data ' . Dumper($meta));

			my $checkagain =  $jsonOnAir->{'vir'}->{'start-time'} + $jsonOnAir->{'vir'}->{'duration'} + 10;

			if ($checkagain < (time()+30)){
				$checkagain = time() + 120;
			}

			my $client = ${*$self}{'client'};
			my $song = $client->playingSong();
			$song->pluginData( meta  => $meta );
			Slim::Control::Request::notifyFromArray( $song->master,['newmetadata'] );

			$log->debug('Callback now  ' . time() . ' when ' . $checkagain);

			Slim::Utils::Timers::setTimer($self, $checkagain, \&liveMetaData);

		},
		sub {
			#Couldn't get meta data
			$log->error('Failed to retrieve on air text');

			#try again in 2 minutes
			Slim::Utils::Timers::setTimer($self, (time() + 120), \&liveMetaData);
		}
	)->get(Plugins::VirginRadio::ProtocolHandler::URL_ONAIR);

}


sub scanUrl {
	my ($class, $url, $args) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("scanurl $url");

	$args->{'cb'}->($args->{'song'}->currentTrack());
}


sub getAODUrl {
	my ($url) = @_;

	#translate url into virgin url
	my $newUrl = URL_CDN . strftime( '%Y%m%d_%H%M_30mins.mp3', localtime(_AODUrlEpoch($url)) );


	return $newUrl;
}


sub _AODUrlEpoch {
	my ($url) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("epoch  of $url");

	my @urlsplit = split /_/x, $url;

	my $epoch = int($urlsplit[2]);

	return $epoch;
}


sub _isLive {
	my ($url) = @_;

	my @urlsplit = split /_/x, $url;
	if ($urlsplit[1] eq 'LIVE') {
		return 1;
	}
	return;
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