# A SoundCloud plugin for Lyrion music server #

> **This is a fork of [danielvijge/SqueezeCloud](https://github.com/danielvijge/SqueezeCloud).**
> It adds **AAC 256kbps streaming for SoundCloud Go+ subscribers** by resolving streams
> through the same api-v2 "browser" flow the web player uses. The public API already serves
> AAC 160kbps, so for non-Go+ accounts this fork matches upstream — the 256kbps tier is the
> only thing api-v2 unlocks, and it needs a browser session token (see below). Everything
> else is unchanged, and all the credit for the plugin belongs upstream — see
> [Acknowledgements](#acknowledgements) below.

This is a Lyrion Music Server (LMS) (a.k.a Squeezebox server) plugin to play tracks from SoundCloud.
It uses `ffmpeg` to transcode the SoundCloud stream.
To install, use the settings page of Lyrion Media Server.
Go to the _Plugins_ tab, scroll down to _3rd party plugins_ and select SoundCloud.
Press the _Apply_ button and restart LMS.

After installation, log in to your SoundCloud account via _Settings_ > _Advanced_ > _SoundCloud_

The plugin is included as a default third party resource. It is retrieved from this
GitHub repository. It is also possible to directly include
the repository XML as an additional repository. For the release version, include

    https://danielvijge.github.io/SqueezeCloud/public.xml

For the development version (updated with every commit), include

    https://danielvijge.github.io/SqueezeCloud/public-dev.xml

The development version might be broken at times.

## ffmpeg ##

`ffmpeg` must be installed to transcode the SoundCloud HLS stream to a stream that can be played directly by LMS.
On Debian Linux this can be installed like this:

    sudo apt install ffmpeg

When using the official Docker image, refer to the documentation how to install `ffmpeg` every time a new version is pulled.

The type of transcoding can be configured via _Settings_ > _Advanced_ > _File Types_.
Available options are flac, pmc, or mp3. Transcoding to mp3 also requires `lame` to be installed.

## SSL support ##

You need SSL support in Perl for this plugin (SoundCloud links are all over HTTPS), so you will need to install some SSL development headers on your server before installing this plugin.

You can do that on Debian Linux (Raspian, Ubuntu, Mint etc.) like this:

    sudo apt install libssl-dev
    sudo perl -MCPAN -e 'install IO::Socket::SSL'
    sudo systemctl restart lyrionmusicserver.service

And on Red Hat Enterprise Linux (Fedora, CentOS, etc.) like this:

    sudo yum -y install openssl-devel
    sudo perl -MCPAN -e 'install IO::Socket::SSL'
    sudo systemctl restart lyrionmusicserver.service

## High quality streaming ##

The upstream plugin resolves streams through SoundCloud's public **v1** API
(`api.soundcloud.com/tracks/{id}/streams`), which already returns an AAC 160kbps
HLS stream (`hls_aac_160_url`) alongside MP3 128 and Opus 64. So AAC 160 is the
baseline, available with or without this fork.

The one tier v1 never exposes is **AAC 256kbps**, the high quality stream
available to SoundCloud **Go+** subscribers. That is only reachable through the
**api-v2** "browser" flow the web player uses, and only when the request is
authenticated as the Go+ user. Unlocking that tier is the sole reason this fork
exists.

This fork rewrites **only the stream resolution** step to replicate that browser
flow:

1. Fetch the track object from `api-v2.soundcloud.com/tracks/{id}` to obtain its
   `media.transcodings` list and a per-track `track_authorization`.
2. Pick the best transcoding for the configured quality preference.
3. Resolve the signed CDN URL from the chosen transcoding.

This requires two extra credentials beyond the normal login:

* A **web `client_id`** — the anonymous id the web player uses. It is scraped
  automatically from the SoundCloud website's JavaScript bundles and cached for a
  day. It is *not* the same as the registered-app client id, and it rotates from
  time to time (the plugin re-scrapes automatically if one is rejected).
* An **OAuth token** — required for AAC 256kbps. Anonymous api-v2 requests (client
  id only) top out at AAC 160kbps, the same as v1. To unlock your own **AAC
  256kbps (Go+)** transcodings you must paste a browser-extracted web-session
  token (see below); the registered-app token from the normal login is not
  accepted by api-v2, so it is not sent.

### Settings ###

Under _Settings_ > _Advanced_ > _SoundCloud_ you will find:

* **Stream quality** — `Highest available` (default), `AAC (high quality)`, or
  `MP3 (standard quality)`.
* **Web client ID** (optional, rarely needed) — the plugin scrapes this
  automatically, so you should normally leave it blank. Only paste a value here if
  auto-scraping ever fails (you would see `Could not obtain a web client_id` in
  the log). It is *not* the same as the registered-app client id.
* **OAuth token** (needed for AAC 256kbps only) — paste a browser-extracted
  web-session token to authenticate as yourself and unlock your Go+ 256kbps
  streams. See [Getting your Go+ OAuth token](#getting-your-go-oauth-token) below.
  Leave blank if you are not a Go+ subscriber — streams resolve anonymously at AAC
  160kbps either way.

The now-playing track info reflects the codec and bitrate that were actually
resolved, rather than a fixed value.

If any part of the api-v2 flow fails, the plugin automatically falls back to the
original v1 behaviour so playback keeps working.

### Getting your Go+ OAuth token ###

AAC 256kbps is only served to an authenticated Go+ session, so you need to copy
the token your own browser uses. The token is tied to your login and **expires
after a while** — when it does, playback silently drops back to AAC 160kbps and
you simply repeat these steps to refresh it.

1. In a desktop browser, log in to <https://soundcloud.com> with your Go+ account.
2. Open the developer tools (**F12**, or right-click → *Inspect*) and select the
   **Network** tab.
3. In the Network filter box, type `api-v2` to narrow the list.
4. Play any track (or just click around) so requests appear. Click any request to
   `api-v2.soundcloud.com`.
5. In the **Headers** panel, scroll to **Request Headers** and find the
   **`Authorization`** entry. Its value looks like `OAuth 2-1234567-...`.
6. Copy that whole value and paste it into the plugin's **OAuth token** field
   (_Settings_ > _Advanced_ > _SoundCloud_). The leading `OAuth ` is optional — the
   plugin accepts it with or without.
7. Save. Play a track and confirm: with the plugin log set to *Info*
   (_Settings_ > _Advanced_ > _Logging_ > `plugin.squeezecloud`) you should see
   `Selected transcoding preset aac_256k`, and the now-playing info will read
   *256kbps AAC*.

Alternative: instead of the header, you can copy the `oauth_token` cookie value
for `soundcloud.com` from the browser's Application/Storage tab — it is the same
token.

## How this fork was built ##

The high quality support was ported with the help of [Claude Code](https://www.anthropic.com/claude-code).
Rather than reverse-engineering the SoundCloud web player from scratch, we used
the [Music Assistant](https://www.music-assistant.io/) project's
[SoundcloudPy](https://github.com/music-assistant/SoundcloudPy) client as a
reference — it already implements the api-v2 browser flow for high quality
playback in Music Assistant. Claude Code analysed how SoundcloudPy resolves a
stream (client id, `track_authorization`, `media.transcodings`) and adapted that
same flow into this Perl LMS plugin, keeping the plugin's existing structure and
conventions intact. **Huge thanks to the Music Assistant team and the SoundcloudPy
authors** — this fork would not exist without their prior work.

## Design decisions ##

* **Minimal blast radius.** Only stream resolution was changed. Browsing, search,
  favourites and the OAuth login flow all remain on the v1 API exactly as
  upstream, so the surface area for regressions is small.
* **Anonymous by default, no new login step.** The plugin auto-scrapes the web
  `client_id` and resolves streams anonymously (AAC 160kbps — the same as v1, so
  nothing regresses for non-Go+ users). AAC 256kbps (Go+) additionally needs a
  browser-extracted web-session token, pasted in Settings — the registered-app
  login token is deliberately not sent to api-v2 because it is rejected there.
* **Highest quality by default, but configurable.** The default is the best
  available transcoding, with a Settings toggle to force AAC or fall back to MP3.
* **Manual overrides as an escape hatch.** If a reused account token is not
  accepted by api-v2, or auto-scraping fails, the client id and OAuth token can be
  pasted manually in Settings.
* **Always fall back.** Any failure in the api-v2 flow (no client id, unexpected
  response, network error) transparently falls back to the original v1 path, so
  the fork is never *less* reliable than upstream.
* **Honest metadata.** The displayed codec/bitrate is derived from the transcoding
  that was actually selected instead of being hardcoded.
* **No transcoding changes.** `ffmpeg`/`custom-convert.conf` already handle the
  HLS/AAC streams, so that layer was left untouched.

## Acknowledgements ##

This is a fork and stands entirely on the shoulders of others:

* The original **[SqueezeCloud](https://github.com/danielvijge/SqueezeCloud)**
  plugin and its authors — **Daniel Vijge**, **David Blackman** (first release),
  **Robert Gibbon** (improvements), **Robert Siebert**, and **KwarkLabs** (major
  SoundCloud API changes). All of the plugin's functionality comes from their
  work; this fork only adds high quality stream resolution.
* The **[Music Assistant](https://www.music-assistant.io/)** project and the
  **[SoundcloudPy](https://github.com/music-assistant/SoundcloudPy)** client
  (**Giel Janssens**, based on the original by **Naím Rodríguez**) — the reference
  implementation of the api-v2 browser flow that this fork's high quality support
  is based on.

## Licence ##

This work is distributed under the GNU General Public License version 2. See file LICENSE for
full license details.
