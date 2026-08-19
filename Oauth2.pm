package Plugins::SqueezeCloud::Oauth2;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
#
# Written by Daniel Vijge
#
# See file LICENSE for full license details

use strict;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use JSON::XS qw(decode_json);
use Digest::SHA qw(sha256_base64);
use LWP::UserAgent;

my $log   = logger('plugin.squeezecloud');
my $prefs = preferences('plugin.squeezecloud');
my $cache = Slim::Utils::Cache->new('squeezecloud');

use constant CLIENT_ID => '112d35211af80d72c8ff470ab66400d8';
use constant CLIENT_SECRET => 'fc63200fee37d02bc3216cfeffe5f5ae';
use constant REDIRECT_URI => 'https%3A%2F%2Fdanielvijge.github.io%2FSqueezeCloud%2Fcallback.html';

# The web client_id is not the same as the registered-app CLIENT_ID above. It is
# the anonymous id the SoundCloud web player uses, and is required (together with
# the account OAuth token and a per-track track_authorization) to resolve the high
# quality api-v2 stream transcodings. It rotates from time to time, so it is scraped
# from the website and cached. A user-supplied value (webClientId pref) takes priority.
use constant WEB_CLIENT_ID_TTL => 86400; # cache a scraped web client_id for one day
use constant WEB_CLIENT_ID_LENGTH => 32;

# How long to remember the health of the configured api-v2 (Go+) token, so the
# settings page can report it and playback can detect a fresh expiry.
use constant TOKEN_STATUS_TTL => 86400 * 30;

sub isLoggedIn {
	return(isRefreshTokenAvailable() || isApiKeyAvailable());
}

sub isApiKeyAvailable {
	return ($prefs->get('apiKey') ne '');
}

sub isAccessTokenAvailable {
	return ($cache->get('access_token') ne '');
}

sub isRefreshTokenAvailable {
	return ($prefs->get('refresh_token') ne '');
}

sub isAccessTokenExpired {
	return 0 if isApiKeyAvailable();       # API key cannot expire
	return 0 if isAccessTokenAvailable();  # Access token still valid
	return 1 if isRefreshTokenAvailable(); # Access token expired, refresh token available
	return 1;                              # This should not happen, equal to isLoggedIn() == false
}

sub getAccessToken {
	$log->debug('getAccessToken started.');

	if (!isRefreshTokenAvailable()) {
		$log->error('No authentication available. Use the settings page to log in first.');
		return;
	}

	if (!isAccessTokenAvailable()) {
		$log->info('Access token has expired. Getting a new access token with the refresh token.');
		getAccessTokenWithRefreshToken(\&getAccessToken, @_);
		return;
	}

	$log->debug('Cached access token ' . $cache->get('access_token'));
	return $cache->get('access_token');
}

sub getAuthorizationToken {
	$log->debug('getAuthorizationToken started.');

	my $cb = shift;
	my ($class, $client, $params, $callback, @args) = @_;

	if (!$cache->get('codeVerifier')) {
		$log->error('No code verifier is available. Reload the page and try to authenticate again.');
		return;
	}

	my $post = 'grant_type=authorization_code' .
		'&client_id=' . CLIENT_ID .
		'&client_secret=' . CLIENT_SECRET .
		'&redirect_uri=' . REDIRECT_URI .
		'&code_verifier=' . $cache->get('codeVerifier') .
		'&code=' . $params->{code};

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			$log->debug('Successful request for authorization_code.');
			my $response = shift;
			my $result = eval { decode_json($response->content) };

			$cache->set('access_token', $result->{access_token}, $result->{expires_in} - 60);
			$prefs->set('refresh_token', $result->{refresh_token});
			delete $params->{code};
			$cb->($class, $client, $params, $callback, @args) if $cb;
		},
		sub {
			$log->error('Failed request for authorization_code.');
			$log->error($_[1]);

			my $response = shift;
			my $result = eval { decode_json($response->content) };
			$log->error($result);
		},
		{
			timeout => 15,
		}
	);
	$log->debug($post);
	$http->post(
		'https://secure.soundcloud.com/oauth/token',
		'Content-Type' => 'application/x-www-form-urlencoded',
		$post,
	);
}

sub getAccessTokenWithRefreshToken {
	$log->debug('getAccessTokenWithRefreshToken started.');

	my $cb = shift;
	my @params = @_;

	if (!isRefreshTokenAvailable()) {
		$log->error('No authentication available. Use the settings page to log in first.');
		return;
	}

	if (isAccessTokenAvailable()) {
		$log->info('Access token is still valid. No need for a refresh.');
		return;
	}

	$log->debug('Cached refresh token ' . $prefs->get('refresh_token'));
	my $post = 'grant_type=refresh_token' .
		'&client_id=' . CLIENT_ID .
		'&client_secret=' . CLIENT_SECRET .
		'&refresh_token=' . $prefs->get('refresh_token');

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			$log->debug('Successful request for refresh_token');
			my $response = shift;
			my $result = eval { decode_json($response->content) };
			$cache->set('access_token', $result->{access_token}, $result->{expires_in} - 60);
			$prefs->set('refresh_token', $result->{refresh_token});
			$cb->(@params) if $cb;
		},
		sub {
			$log->error('Failed request for refresh_token');
			$log->error($_[1]);
			$log->warn('Removing refresh_token upon failed request. You are now logged out. Complete the authorisation flow on the settings page again.');
			$prefs->remove('refresh_token');
			$cb->(@params) if $cb;
		},
		{
			timeout => 15,
		}
	);
	$log->debug($post);
	$http->post(
		'https://secure.soundcloud.com/oauth/token',
		'Content-Type' => 'application/x-www-form-urlencoded',
		$post,
	);
}

sub logout {
	$log->debug('logout started.');

	my $cb = shift;
	my @params = @_;

	$log->info('Logging out...');
	
	if (isLoggedIn()) {

		if (Plugins::SqueezeCloud::Oauth2::isAccessTokenExpired()) {
			Plugins::SqueezeCloud::Oauth2::getAccessTokenWithRefreshToken(\&logout, @_);
			return;
		}

		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$log->debug('Successful request for logout');
				removeTokens();
				# delete parameter, to prevent loop of logout action
				delete @params[2]->{logout};
				$cb->(@params) if $cb;
			},
			sub {
				$log->error('Failed request for logout');
				$log->error($_[1]);
				$log->warn('Logout failed. Tokens were removed locally, but not invalidated');
				removeTokens();
				delete @params[2]->{logout};
				$cb->(@params) if $cb;
			},
			{
				timeout => 15,
			}
		);

		$http->post(
			'https://secure.soundcloud.com/sign-out',
			'{"access_token": "'. (isApiKeyAvailable() ? $prefs->get('apiKey') : $cache->get('access_token')).'"}'
		);
	}
	else {
		$log->warn('Request for logout, but you are not logged in');
	}
}

sub removeTokens {
	$log->debug('removeTokens started.');
	$prefs->remove('refresh_token');
	$cache->remove('access_token');
	$prefs->remove('apiKey');
	$cache->clear(); # clear cache, so any personal items are no longer available
}

sub getAuthenticationHeaders {
	$log->debug('getAuthenticationHeaders started.');
	if (isApiKeyAvailable()) {
		# If there is still an older API key, use this for authentication
		$log->debug('Using old API key ' . $prefs->get('apiKey'));
		return 'Authorization' => 'OAuth ' . $prefs->get('apiKey');
	}
	else {
		$log->debug('Using OAuth 2.1 bearer token for authorization');
		return 'Authorization' => 'Bearer ' . getAccessToken();
	}
}

# Authentication headers for the unofficial api-v2 (browser) endpoints used for
# high quality stream resolution.
#
# api-v2 only accepts a genuine web-session OAuth token (the kind the browser
# uses). The registered-app token obtained through the normal login flow is NOT
# such a token and is rejected with 403, so reusing it is pointless and just costs
# an extra failed request per track. We therefore only send an Authorization
# header when the user has supplied a browser-extracted token via the oauthToken
# pref (needed to unlock their own Go+ / AAC 256 transcodings). Without it we make
# an anonymous request, which still resolves public tracks up to AAC 160.
sub getApiV2AuthenticationHeaders {
	$log->debug('getApiV2AuthenticationHeaders started.');

	my $manualToken = $prefs->get('oauthToken');
	if ($manualToken && $manualToken ne '') {
		# Accept both "OAuth xxxx" and a bare token when pasted from the browser.
		$manualToken =~ s/^\s*OAuth\s+//i;
		$manualToken =~ s/^\s+|\s+$//g;
		$log->debug('Using manually configured api-v2 OAuth token');
		return ('Authorization' => 'OAuth ' . $manualToken);
	}

	$log->debug('No manual api-v2 token configured; requesting anonymously');
	return ();
}

# Health of the manually-configured api-v2 (Go+) web-session token, as last
# observed either by validateApiV2Token() or by a real stream-resolution request.
# One of 'valid', 'expired', 'unknown' or 'none' (no token configured). Cached so
# the settings page can display it and so playback can tell when a working token
# has just started being rejected.
sub setApiV2TokenStatus {
	my $status = shift;
	$cache->set('oauthTokenStatus', $status, TOKEN_STATUS_TTL);
}

sub getApiV2TokenStatus {
	my $manualToken = $prefs->get('oauthToken');
	return 'none' if !$manualToken || $manualToken eq '';
	return $cache->get('oauthTokenStatus') || 'unknown';
}

# Validate the configured api-v2 (Go+) token by making the same authenticated
# api-v2 request playback uses (GET /me). A live token returns 200; an expired or
# revoked one returns 401/403. Updates the cached token status and invokes the
# callback (no args) when done. Fully asynchronous, so it never blocks the server.
sub validateApiV2Token {
	my $cb = shift;
	$log->debug('validateApiV2Token started.');

	my $token = $prefs->get('oauthToken');
	if (!$token || $token eq '') {
		setApiV2TokenStatus('none');
		$cb->() if $cb;
		return;
	}
	$token =~ s/^\s*OAuth\s+//i;
	$token =~ s/^\s+|\s+$//g;

	my $clientId = getWebClientId();
	if (!$clientId) {
		$log->warn('Cannot validate api-v2 token without a web client_id');
		setApiV2TokenStatus('unknown');
		$cb->() if $cb;
		return;
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			$log->info('api-v2 Go+ token validated successfully');
			setApiV2TokenStatus('valid');
			$cb->() if $cb;
		},
		sub {
			my ($self, $error) = @_;
			my $code = ($self && $self->{code}) || 0;
			if ($code == 401 || $code == 403) {
				$log->warn('api-v2 Go+ token rejected (' . ($error || $code) . '); it has likely expired');
				setApiV2TokenStatus('expired');
			}
			else {
				# Network/other error: do not claim the token expired.
				$log->warn('Could not validate api-v2 Go+ token: ' . ($error || 'unknown error'));
				setApiV2TokenStatus('unknown');
			}
			$cb->() if $cb;
		},
		{
			timeout => 10,
		}
	);

	$http->get(
		'https://api-v2.soundcloud.com/me?client_id=' . $clientId,
		'Authorization' => 'OAuth ' . $token,
	);
}

# Returns a web client_id suitable for api-v2 stream resolution. Order of
# preference: a user-configured value, a previously scraped+cached value, then a
# freshly scraped value from the SoundCloud website.
sub getWebClientId {
	$log->debug('getWebClientId started.');

	my $manual = $prefs->get('webClientId');
	if ($manual && length($manual) == WEB_CLIENT_ID_LENGTH) {
		$log->debug('Using manually configured web client_id');
		return $manual;
	}

	my $cached = $cache->get('web_client_id');
	if ($cached) {
		$log->debug('Using cached web client_id');
		return $cached;
	}

	my $clientId = _scrapeWebClientId();
	if ($clientId) {
		$log->info('Scraped web client_id from SoundCloud website');
		$cache->set('web_client_id', $clientId, WEB_CLIENT_ID_TTL);
	}
	else {
		$log->warn('Could not obtain a web client_id from the SoundCloud website');
	}
	return $clientId;
}

# Clear a cached (scraped) web client_id, e.g. after it has been rejected, so the
# next resolution attempt scrapes a fresh one.
sub clearWebClientId {
	$log->debug('clearWebClientId started.');
	$cache->remove('web_client_id');
}

# Scrape the anonymous web client_id used by the SoundCloud web player. The
# homepage references a number of JavaScript bundles on sndcdn.com; one of them
# contains a client_id:"..." assignment. This mirrors what the browser does.
sub _scrapeWebClientId {
	$log->debug('_scrapeWebClientId started.');

	my $ua = LWP::UserAgent->new(
		timeout => 15,
		agent   => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0',
	);

	my $res = $ua->get('https://soundcloud.com/');
	if (!$res->is_success) {
		$log->warn('Failed to fetch SoundCloud homepage: ' . $res->status_line);
		return;
	}

	# Collect the script bundle URLs. The client_id tends to live in one of the
	# later bundles, so search them in reverse order.
	my @scripts = $res->content =~ /<script[^>]+src="([^"]+\.js)"/g;
	foreach my $src (reverse @scripts) {
		next unless $src =~ /sndcdn\.com/;

		my $js = $ua->get($src);
		next unless $js->is_success;

		# Match client_id:"..." / "client_id":"..." / client_id='...' etc.
		if ($js->content =~ /client_id["']?\s*[:=]\s*["']([0-9a-zA-Z]{32})["']/) {
			return $1;
		}
	}

	$log->warn('No client_id found in any SoundCloud script bundle');
	return;
}

# This function generates random strings of a given length
# Copied from  Slim::Player::Squeezebox, but for some reason it cannot
# be called directly.
sub generate_random_string
{
	# the length of the random string to generate
	my $length_of_randomstring = shift;

	my @chars = ('a'..'z','A'..'Z','0'..'9','_');
	my $random_string;

	foreach (1..$length_of_randomstring) {
		#rand @chars will generate a random number between 0 and scalar @chars
		$random_string .= $chars[rand @chars];
	}

	return $random_string;
}

sub getCodeChallenge {
	$log->debug('getCodeChallenge started.');
	if ($cache->get('codeChallenge')) {
		$log->debug('Random string [cached]: '. $cache->get('codeVerifier'));
		$log->debug('S256 [cached]: '.$cache->get('codeChallenge'));
		return $cache->get('codeChallenge');
	}

	my $randomString = generate_random_string(56);
	my $s256 = sha256_base64($randomString);
	# the code challange should be URL-safe, so some characters need to be replaced:
	# + => -
	# / -> _
	# trim trailing =
	$s256 =~ s/\+/-/g;
	$s256 =~ s/\//_/g;
	$s256 =~ s/=$//g;

	$log->debug('Random string: '.$randomString);
	$log->debug('S256: '.$s256);

	# user must complete the authorization flow within 5  minutes after getting the code
	# from SoundCloud, otherwise the cached code verifier is no longer available.
	# A code generated by SoundCloud only seems to be valid for some time.
	$cache->set('codeVerifier', $randomString, 300);
	$cache->set('codeChallenge', $s256, 300);
	return $s256;
}

1;
