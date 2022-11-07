package Plugins::VirginRadio::RadioFavourites;

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

use Slim::Utils::Log;
use JSON::XS::VersionOneAndTwo;
use HTTP::Date;
use Data::Dumper;
use POSIX qw(strftime);
use URI::Escape;

use Plugins::VirginRadio::ProtocolHandler;
use Plugins::VirginRadio::Utilities;

my $log = logger('plugin.virginradio');


sub getStationData {
	my ( $stationUrl, $stationKey, $stationName, $nowOrNext, $cbSuccess, $cbError) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getStationData");

	if ($nowOrNext eq 'next') {
		$log->error('Next not supported');
		$cbError->(
			{
				url       => $stationUrl,
				stationName => $stationName
			}
		);
		return;
	}

	my $metaUrl = Plugins::VirginRadio::ProtocolHandler::URL_ONAIR . '?station=' . Plugins::VirginRadio::ProtocolHandler::STATION_IDENT->{$stationKey} . '&hasPrograms=1';

	main::INFOLOG && $log->is_info && $log->info("Meta URL is : $metaUrl");
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = ${$http->contentRef};

			#decode the json
			my $jsonOnAir = decode_json $content;
			my $stationImage = _getStationImage($stationKey);

			my $result = {
				title =>  $jsonOnAir->{onAirNow}->{title},
				description => '',
				image => $jsonOnAir->{onAirNow}->{images}[0]->{url},
				startTime => str2time($jsonOnAir->{onAirNow}->{startTime}),
				endTime   => str2time($jsonOnAir->{onAirNow}->{endTime}),
				url       => $stationUrl,
				stationName => $stationName,
				stationImage => $stationImage,
			};

			main::INFOLOG && $log->is_info && $log->info(Dumper($result));

			$cbSuccess->($result);

		},
		sub {
			#Couldn't get meta data
			$log->error('Failed to retrieve on air text');
			$cbError->(
				{
					url       => $stationUrl,
					stationName => $stationName
				}
			);
		}
	)->get($metaUrl);

	return;
}


sub _getStationImage {
	my ($stationKey) = @_;

	if ($stationKey eq 'vir') {
		return '/' . Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO;
	} elsif ($stationKey eq 'anthems') {
		return '/' . Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOANTHEMS;
	} elsif ($stationKey eq 'chilled') {
		return '/' . Plugins::VirginRadio::Utilities::IMG_VIRGINRADIOCHILLED;
	} elsif ($stationKey eq '80splus') {
		return '/' . Plugins::VirginRadio::Utilities::IMG_VIRGINRADIO80SPLUS;
	}
	return;

}


sub getStationSchedule {
	my ( $stationUrl, $stationKey, $stationName, $scheduleDate, $cbSuccess, $cbError) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getStationSchedule");


	Plugins::VirginRadio::VirginRadioFeeder::getScheduleAsJSON(
		sub {
			my $scheduleJSON = shift;


			my $scheduleJSONNode = $scheduleJSON->{props}->{pageProps}->{schedules};

			main::DEBUGLOG && $log->is_debug && $log->debug(Dumper($scheduleJSONNode));
			my $out= [];
			for my $schedN (@$scheduleJSONNode) {
				main::DEBUGLOG && $log->is_debug && $log->debug('d comp ' . $schedN->{date} . ' in ' . $scheduleDate);
				if ($schedN->{date} eq $scheduleDate) {
					my $items = $schedN->{shows};
					for my $item (@$items) {

						if (defined $item->{recording}) {
							push @$out,
							  {
								start => $item->{startTime},
								end => $item->{endTime},
								title1 => $item->{title},
								title2 => $item->{description},
								image => $item->{images}[0]->{url},
								url  => 'virgin://_AOD_' . $item->{id} . '_' . uri_escape($item->{recording}->{url}),
							  };

						} else {
							push @$out,
							  {
								start => $item->{startTime},
								end => $item->{endTime},
								title1 => $item->{title},
								title2 => $item->{description},
								image => $item->{images}[0]->{url},								
							  };
						}
					}
				}
			}
			$cbSuccess->($out);
		},

		#could not get a session
		sub {
			$menu = [ { name => 'Failed! - Could not get schedule' } ];
			$cbError->("Could not get schedule");
		}

	);


}


1;

