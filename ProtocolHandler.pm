package Plugins::SqueezeCloud::ProtocolHandler;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
#
# Written by David Blackman (first release),
#   Robert Gibbon (improvements),
#   Daniel Vijge (improvements),
#   KwarkLabs (major SoundCloud API changes)
#
# See file LICENSE for full license details

use strict;

use base qw(Slim::Player::Protocols::HTTPS);

use List::Util qw(min max);
use LWP::Simple;
use LWP::UserAgent;
use HTML::Parser;
use URI::Escape;
use JSON::XS qw(decode_json);
use XML::Simple;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string);
use Scalar::Util qw(blessed);
use Plugins::SqueezeCloud::Oauth2;

my $log   = logger('plugin.squeezecloud');
my $cache = Slim::Utils::Cache->new('squeezecloud');

my %fetching; # hash of ids we are fetching metadata for to avoid multiple fetches

Slim::Player::ProtocolHandlers->registerHandler('soundcloud', __PACKAGE__);

use strict;
use base 'Slim::Player::Protocols::HTTP';

# Defines the timeout in seconds for a http request
use constant HTTP_TIMEOUT => 15;
use constant STREAM_CACHE_TTL => 30; # stream URLs are valid only for a short period

# Base URL of the unofficial browser API used for high quality stream resolution
use constant API_V2_BASE => 'https://api-v2.soundcloud.com';

# How long to remember the resolved codec/bitrate of a track for display in the
# track info. Matches the metadata cache lifetime in Plugin.pm.
use constant QUALITY_CACHE_TTL => 86400 * 30;

use IO::Socket::SSL;
IO::Socket::SSL::set_defaults(
	SSL_verify_mode => Net::SSLeay::VERIFY_NONE()
) if preferences('server')->get('insecureHTTPS');

my $prefs = preferences('plugin.squeezecloud');

my $prefix = 'sc:';

sub canSeek { 1 }

sub canTranscodeSeek { 1 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

# Perform an api-v2 GET request.
#
# api-v2 resolves public tracks with just the client_id in the query string. An
# account token is only needed to unlock a user's own high quality (Go+)
# transcodings, and a token api-v2 does not recognise (e.g. the registered-app
# token from the normal login flow) is rejected outright with 401/403. So we send
# the token when we have one, but if that is rejected we retry the request
# anonymously before giving up, so public tracks still resolve.
sub _apiV2Get {
	my ($ua, $url, $client) = @_;

	my @authHeaders = Plugins::SqueezeCloud::Oauth2::getApiV2AuthenticationHeaders();
	my $res = @authHeaders ? $ua->get($url, @authHeaders) : $ua->get($url);

	# When we sent the configured Go+ token, track its health so both the settings
	# page and the on-player notification stay accurate.
	if (@authHeaders) {
		if ($res->is_success) {
			# The token was accepted; remember it's healthy and re-arm the toast.
			Plugins::SqueezeCloud::Oauth2::setApiV2TokenStatus('valid');
			$cache->remove('tokenExpiredNotified');
		}
		elsif ($res->code == 401 || $res->code == 403) {
			$log->warn('api-v2 rejected the request with the configured token (' . $res->status_line . '), retrying anonymously');
			my $anon = $ua->get($url);
			# If the anonymous retry succeeds, the token (not the client_id) was the
			# problem, so it has expired/been revoked — tell the user.
			_notifyTokenExpired($client) if $anon->is_success;
			$res = $anon;
		}
	}

	return $res;
}

# Warn the user that their configured Go+ token was rejected by api-v2 and has
# likely expired, so high quality has silently dropped back to AAC 160. Shows a
# brief on-player toast (rate-limited to once an hour so it does not fire on every
# track or seek) and records the expired status for the settings page.
sub _notifyTokenExpired {
	my $client = shift;

	Plugins::SqueezeCloud::Oauth2::setApiV2TokenStatus('expired');

	return if $cache->get('tokenExpiredNotified');
	$cache->set('tokenExpiredNotified', 1, 3600);

	my $msg = string('PLUGIN_SQUEEZECLOUD_TOKEN_EXPIRED_TOAST');
	$log->warn($msg);

	return unless blessed($client) && $client->can('showBriefly');

	my $title = string('PLUGIN_SQUEEZECLOUD');
	$client->showBriefly({
		line => [ $title, $msg ],
		jive => { type => 'popupplay', text => [ $title, $msg ] },
	}, {
		duration => 8,
		scroll   => 1,
	});
}

# Resolve a playable stream URL for a track.
#
# This replicates the SoundCloud web player ("browser") flow via the api-v2
# endpoints, which is the only way to obtain the high quality (AAC / Go+)
# transcodings. It fetches the track object to get its media.transcodings and a
# per-track track_authorization, selects the best transcoding according to the
# configured quality preference, then resolves the signed CDN URL from it.
#
# If anything in the api-v2 flow fails (no web client_id, unexpected response,
# etc.) it falls back to the legacy v1 /streams behaviour so playback keeps
# working.
sub getStreamURL {
	my ($json, $client) = @_;
	$log->debug('getStreamURL started.');

	# Determine the numeric track id from the v1 metadata object. api-v2 uses the
	# numeric id, not the "soundcloud:tracks:<id>" urn.
	my $trackId = $json->{'id'};
	if ((!defined $trackId || $trackId eq '') && defined $json->{'urn'} && $json->{'urn'} =~ /(\d+)\s*$/) {
		$trackId = $1;
	}

	if (!$trackId) {
		$log->warn('Could not determine numeric track id, falling back to v1 stream resolution');
		return getStreamURLv1($json);
	}

	my $quality = $prefs->get('streamQuality') || 'max';
	my $cacheKey = 'streamurl:' . $trackId . ':' . $quality;
	my $cachedStreamUrl = $cache->get($cacheKey);
	if ($cachedStreamUrl) {
		$log->debug('Return stream URL from cache');
		return $cachedStreamUrl;
	}

	my $clientId = Plugins::SqueezeCloud::Oauth2::getWebClientId();
	if (!$clientId) {
		$log->warn('No web client_id available, falling back to v1 stream resolution');
		return getStreamURLv1($json);
	}

	my $ua = LWP::UserAgent->new( timeout => HTTP_TIMEOUT );

	# 1. Fetch the api-v2 track object (transcodings + track_authorization).
	my $trackUrl = API_V2_BASE . '/tracks/' . $trackId . '?client_id=' . $clientId;
	$log->info('SoundCloud api-v2 call to ' . $trackUrl);
	my $res = _apiV2Get($ua, $trackUrl, $client);
	if (!$res->is_success) {
		$log->warn('api-v2 track fetch failed (' . $res->status_line . '), falling back to v1');
		# Even the anonymous attempt failed, so a rotated/invalid client_id is the
		# likely cause; drop it so the next attempt re-scrapes a fresh one.
		Plugins::SqueezeCloud::Oauth2::clearWebClientId() if $res->code == 401 || $res->code == 403;
		return getStreamURLv1($json);
	}

	my $track = eval { decode_json($res->content) };
	if ($@ || !$track || ref($track) ne 'HASH') {
		$log->warn('Could not decode api-v2 track response, falling back to v1');
		return getStreamURLv1($json);
	}

	# Capture the authenticated duration. For Go+ tracks the v1 metadata only
	# reports the 30-second snippet length, but api-v2 (authenticated with a Go+
	# token) returns the full track, so record it on the shared track object and
	# cache so the now-playing/browse duration is correct instead of cutting off.
	my $realDurationMs = $track->{'full_duration'} || $track->{'duration'};
	if ($realDurationMs) {
		$json->{'sc_duration_ms'} = $realDurationMs;
		$cache->set('duration:' . $trackId, $realDurationMs, QUALITY_CACHE_TTL);
	}

	my $trackAuth = $track->{'track_authorization'};
	my $transcodings = $track->{'media'} && $track->{'media'}->{'transcodings'};
	if (!$transcodings || ref($transcodings) ne 'ARRAY' || !@$transcodings) {
		$log->warn('No transcodings in api-v2 response, falling back to v1');
		return getStreamURLv1($json);
	}

	# Log every offered transcoding (preset / protocol / snipped) so it is clear
	# which formats are actually available and playable for a given track. Go+
	# tracks typically only offer the full-length audio through a DRM-protected
	# (encrypted) transcoding LMS cannot decode.
	if ($log->is_debug) {
		$log->debug('api-v2 transcodings offered: ' . join(', ', map {
			($_->{'preset'} || '?')
			. '/' . (($_->{'format'} && $_->{'format'}->{'protocol'}) || '?')
			. ($_->{'snipped'} ? ' snipped' : '')
		} @$transcodings));
	}

	# 2. Select the best transcoding for the configured quality preference.
	my $chosen = _selectTranscoding($transcodings, $quality);
	if (!$chosen) {
		$log->warn('No playable (non-DRM) transcoding found, falling back to v1');
		return getStreamURLv1($json);
	}
	my $protocol = ($chosen->{'format'} && $chosen->{'format'}->{'protocol'}) || 'unknown';
	$log->info('Selected transcoding preset ' . ($chosen->{'preset'} || '?') . ' (' . $protocol . ')');

	# Record the real codec/bitrate so the track info can display it accurately.
	# Stash on the track object (read immediately by _makeMetadata) and in the
	# shared cache keyed by track id (read on subsequent now-playing lookups).
	my ($codec, $bitrate) = _presetQuality($chosen->{'preset'});
	$json->{'sc_codec'} = $codec;
	$json->{'sc_bitrate'} = $bitrate;
	$cache->set('quality:' . $trackId, { codec => $codec, bitrate => $bitrate }, QUALITY_CACHE_TTL);

	# 3. Resolve the signed CDN URL from the chosen transcoding.
	my $mediaUrl = $chosen->{'url'};
	my $sep = ($mediaUrl =~ /\?/) ? '&' : '?';
	my $sigUrl = $mediaUrl . $sep . 'client_id=' . $clientId;
	$sigUrl .= '&track_authorization=' . $trackAuth if $trackAuth;

	$log->info('SoundCloud api-v2 call to ' . $sigUrl);
	my $res2 = _apiV2Get($ua, $sigUrl, $client);
	if (!$res2->is_success) {
		$log->warn('Transcoding resolution failed (' . $res2->status_line . '), falling back to v1');
		return getStreamURLv1($json);
	}

	my $stream = eval { decode_json($res2->content) };
	my $finalUrl = $stream && ref($stream) eq 'HASH' ? $stream->{'url'} : undef;
	if (!$finalUrl) {
		$log->warn('No url in transcoding response, falling back to v1');
		return getStreamURLv1($json);
	}

	$log->info('Final URL that can be played: ' . $finalUrl);
	$cache->set($cacheKey, $finalUrl, STREAM_CACHE_TTL);
	return $finalUrl;
}

# Ordered list of preset name prefixes to look for, best first, for a given
# quality preference. SoundCloud preset names look like mp3_0_0, opus_0_0,
# aac_160k, aac_256k, abr_sq etc.
sub _presetPreference {
	my $quality = shift;

	if ($quality eq 'mp3') {
		# Force standard MP3, but still allow opus so something always plays.
		return ('mp3', 'opus');
	}
	elsif ($quality eq 'aac') {
		# Prefer the highest AAC tier, fall back to MP3 then opus.
		return ('aac_256', 'aac_160', 'aac', 'mp3', 'opus');
	}

	# 'max' (default): highest quality first.
	return ('aac_256', 'aac_160', 'aac', 'abr', 'mp3', 'opus');
}

# Map a SoundCloud preset name to a human readable (codec, bitrate) pair for
# display in the track info. Bitrate is a string like '256kbps', or '' when the
# preset does not imply a fixed bitrate.
sub _presetQuality {
	my $preset = shift || '';

	return ('AAC', '256kbps') if index($preset, 'aac_256') == 0;
	return ('AAC', '160kbps') if index($preset, 'aac_160') == 0;
	return ('AAC', '')        if index($preset, 'aac') == 0;
	return ('AAC', '')        if index($preset, 'abr') == 0;
	return ('MP3', '128kbps') if index($preset, 'mp3') == 0;
	return ('Opus', '64kbps') if index($preset, 'opus') == 0;

	return ('', '');
}

# True if a transcoding is DRM/encrypted (e.g. protocol "cbc-encrypted-hls").
# SoundCloud serves the Go+ high quality (aac_256k) as a FairPlay-encrypted
# SAMPLE-AES HLS stream (EXT-X-KEY METHOD=SAMPLE-AES, com.apple.streamingkeydelivery).
# LMS/ffmpeg have no FairPlay license client, so such a stream resolves to a URL
# but produces no audio. We must never hand one to the player.
sub _isEncryptedTranscoding {
	my $t = shift;
	my $protocol = ($t->{'format'} && $t->{'format'}->{'protocol'}) || '';
	return $protocol =~ /encrypt/i ? 1 : 0;
}

# Pick the best available transcoding for the configured quality preference.
# Encrypted (DRM) transcodings are skipped because they cannot be played, even
# though they are usually the highest quality option offered.
sub _selectTranscoding {
	my ($transcodings, $quality) = @_;

	foreach my $token (_presetPreference($quality)) {
		foreach my $t (@$transcodings) {
			next if _isEncryptedTranscoding($t);
			my $preset = $t->{'preset'} || '';
			# The preference token is matched as a prefix of the preset name, so
			# e.g. "aac" matches "aac_160k"/"aac_256k" and "aac_256" matches only
			# the 256k tier.
			return $t if index($preset, $token) == 0;
		}
	}

	return;
}

# Legacy v1 stream resolution via the public API /streams endpoint. Retained as a
# fallback for when the api-v2 browser flow is unavailable.
sub getStreamURLv1 {
	my $json = shift;
	$log->debug('getStreamURLv1 started.');

	my $ua = LWP::UserAgent->new(
		requests_redirectable => [],
	);

	my $queryUrl = $json->{'uri'}.'/streams';

	my $cachedStreamUrl = $cache->get($queryUrl);
	if ($cachedStreamUrl) {
		$log->debug('Return stream URL from cache');
		return $cachedStreamUrl;
	}

	$log->info('SoundCloud API call to ' . $queryUrl);

	# Need to call the /streams endpoint for the tracks API endpoint. This returns an object with the different stream options
	my $res = $ua->get($queryUrl, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders() );
	my $stream_res = eval { decode_json( $res->content ) };

	# Define the different formats supported in order of preference
	foreach ('hls_aac_160_url', 'hls_aac_96_url', 'hls_mp3_128_url', 'http_mp3_128_url') {
		my $format = $_;
		if (exists $stream_res->{$format}) {
			$log->info('Found format '.$format.', URL '.$stream_res->{$format}.', getting redirect location');

			my $ua = LWP::UserAgent->new(
				requests_redirectable => [],
			);

			$log->info('SoundCloud API call to ' . $stream_res->{$format});
			my $res = $ua->get($stream_res->{$format}, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders() );

			my $redirector = $res->header( 'location' );

			if (!$redirector) {
				$log->warn('Warning: Failed to get redirect location for '.$format.' from '.$stream_res->{$format});
				$log->info($res->status_line);
				next;
			}

			$log->info('Final URL that can be played: '.$redirector);
			$cache->set($queryUrl, $redirector, STREAM_CACHE_TTL);
			return $redirector;
		}
	}

	$log->error('Error: correct format could not be found in streams. Only available formats are ' . join(', ' , keys(%$stream_res)));
	return;
}

sub getBetterArtworkURL {
	my $artworkURL = shift;
	$artworkURL =~ s/-large/-t500x500/g;
	return $artworkURL;
}

sub getFormatForURL { 'soundcloud' } # custom-convert type

# When seeking, fetch the URL again. SoundCloud streams have an expiry time. Seeking
# forward should not cause an issue, as the end of the song will always be before
# the expiry time. But seeking backwards and then playing until the end could result
# in the end of the song being after the expiry time. By refreshing the URL when
# seeking this problem is avoided. Using `formatOverride()` might not be the
# proper solution for this, but it appears this custom function from a plugin
# happens to be called at the right time.
# Ref: https://github.com/LMS-Community/slimserver/blob/91c0d2f13929b57fc5d06a2cd7b4ea40be597547/Slim/Player/Song.pm#L377
sub formatOverride {
	my ($class, $song) = @_;

	my $track = $song->pluginData();
	if ($track && $track->{'uri'}) {
		my $stream = getStreamURL($track, $song->master());
		$song->streamUrl($stream) if $stream;
	}

	return 'soundcloud';
}

sub isRemote { 1 }

sub scanUrl {
	my ($class, $url, $args) = @_;
	$log->debug('scanUrl started.');
	$args->{cb}->( $args->{song}->currentTrack() );
	$log->debug('scanUrl ended.');
}

sub gotNextTrack {
	my $http   = shift;
	my $client = $http->params->{client};
	my $song   = $http->params->{song};
	my $url    = $song->currentTrack()->url;
	$log->debug('gotNextTrack started.');

	my $track  = eval { decode_json( $http->content ) };

	if ( $@ || $track->{error} ) {

		# We didn't get the next track to play
		if ( $log->is_warn ) {
			$log->warn( 'Soundcloud error getting next track: ' . ( $@ || $track->{error} ) );
		}

		if ( $client->playingSong() ) {
			$client->playingSong()->pluginData( {
				songName => $@ || $track->{error},
			} );
		}

		$http->params->{'errorCallback'}->( 'PLUGIN_SQUEEZECLOUD_NO_INFO', $track->{error} );
		return;
	}

	# Save metadata for this track
	$song->pluginData( $track );

	my $stream = getStreamURL($track, $client);

	if (!$stream) {
		$http->params->{'errorCallback'}->( 'PLUGIN_SQUEEZECLOUD_STREAM_FAILED', $track->{error} );	
		return;
	}

	$song->streamUrl($stream);

	my $args = { params => {isProtocolHandler => 1}};
	my $meta = Plugins::SqueezeCloud::Plugin::_makeMetadata($client, $track, $args);
	$song->duration( $meta->{duration} );

	$http->params->{callback}->();
	$log->debug('gotNextTrack ended.');
}

sub gotNextTrackError {
	my $http = shift;
	$log->debug('gotNextTrackError started.');
	$log->error('Error getting track '.$http->url.' - '.$http->error);
	$http->params->{errorCallback}->( 'PLUGIN_SQUEEZECLOUD_ERROR', $http->error );
	$log->debug('gotNextTrackError ended.');
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	$log->debug('getNextTrack started.');

	my $client = $song->master();
	my $url    = $song->currentTrack()->url;

	# Get next track
	my ($urn) = $url =~ m{^soundcloud://(.*)$};

	# Convert old id that might still be in favourites or cache to urn
	$urn = 'soundcloud:tracks:'.$urn unless $urn =~ /^soundcloud:tracks:/;

	# Talk to SN and get the next track to play
	my $trackURL = "https://api.soundcloud.com/tracks/" . $urn;

	if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
			Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&getNextTrack, @_);
			return;
		}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotNextTrack,
		\&gotNextTrackError,
		{
			client        => $client,
			song          => $song,
			callback      => $successCb,
			errorCallback => $errorCb,
			timeout       => 35,
		},
	);

	$log->info('SoundCloud API call to '.$trackURL);

	$http->get( $trackURL, Plugins::SqueezeCloud::Oauth2::getAuthenticationHeaders() );
	$log->debug('getNextTrack ended.');
}

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	$log->debug('new started.');

	my $client = $args->{client};

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;
	my $track     = $song->pluginData();

	$log->info( 'Remote streaming Soundcloud track: ' . $streamUrl );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
	} ) || return;

	${*$sock}{contentType} = 'audio/mpeg';

	$log->debug('new ended.');
	return $sock;
}


# Track Info menu
sub trackInfo {
	my ( $class, $client, $track ) = @_;
	$log->debug('trackInfo started.');

	my $url = $track->url;
	$log->debug("trackInfo: " . $url);
	$log->debug('trackInfo ended.');
}

# Track Info menu
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;
	$log->debug('trackInfoUrl started.');
	$log->debug("trackInfoURL: " . $url);
	$log->debug('trackInfoUrl ended.');
	return undef;
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	$log->debug('getMetadataFor started.');
	my $args = { params => {isProtocolHandler => 1}};
	$log->debug('getMetadataFor ended.');
	return Plugins::SqueezeCloud::Plugin::metadata_provider($client, $url, $args);
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;
	$log->debug('canDirectStreamSong started.');

	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	$log->debug('canDirectStreamSong ended.');
	return $class->SUPER::canDirectStream( $client, $song->streamUrl(), $class->getFormatForURL() );
}

# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;
	$log->debug('handleDirectError started.');

	$log->warn("Warning: Direct stream failed: $url [$response] $status_line");

	$client->controller()->playerStreamingFailed( $client, 'PLUGIN_SQUEEZECLOUD_STREAM_FAILED' );
	$log->debug('handleDirectError ended.');
}

sub explodePlaylist {
	my ( $class, $client, $uri, $callback ) = @_;
	$log->debug('explodePlaylist started.');

	if ( $uri =~ Plugins::SqueezeCloud::Plugin::PAGE_URL_REGEXP ) {
		Plugins::SqueezeCloud::Plugin::urlHandler(
			$client,
			sub { $callback->([map {$_->{'play'}} @{$_[0]->{'items'}}]) },
			{'search' => $uri},
		);
	}
	else {
		$callback->([$uri]);
	}
	$log->debug('explodePlaylist ended.');
}

1;
