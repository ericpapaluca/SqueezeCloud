# A SoundCloud plugin for Lyrion music server #

> **This is a fork of [danielvijge/SqueezeCloud](https://github.com/danielvijge/SqueezeCloud).**
> It adds **high quality streaming** (AAC, up to 256kbps for SoundCloud Go+ accounts) by
> resolving streams through the same api-v2 "browser" flow the SoundCloud web player uses,
> instead of the standard-quality v1 endpoint. Everything else is unchanged, and all the
> credit for the plugin belongs upstream — see [Acknowledgements](#acknowledgements) below.

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
(`api.soundcloud.com/tracks/{id}/streams`). For third-party applications that
endpoint now only returns a standard-quality MP3 128kbps stream — the higher
quality AAC tiers (including the 256kbps stream available to SoundCloud Go+
subscribers) are only exposed through the **api-v2** "browser" flow that the
SoundCloud web player itself uses.

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
* An **OAuth token** — by default the plugin reuses the token from your existing
  one-click login, sent in the `OAuth <token>` form api-v2 expects.

### Settings ###

Under _Settings_ > _Advanced_ > _SoundCloud_ you will find:

* **Stream quality** — `Highest available` (default), `AAC (high quality)`, or
  `MP3 (standard quality)`.
* **Web client ID** (optional) — paste a browser-extracted client id to override
  auto-scraping.
* **OAuth token** (optional) — paste a browser-extracted token to override the
  reused login token, e.g. if your account token is not accepted by api-v2.

The now-playing track info reflects the codec and bitrate that were actually
resolved, rather than a fixed value.

If any part of the api-v2 flow fails, the plugin automatically falls back to the
original v1 behaviour so playback keeps working.

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
* **Reuse the existing login.** No new login step was added. The plugin reuses the
  token from the existing one-click OAuth login and auto-scrapes the web
  `client_id`, so for most users high quality "just works" with no extra setup.
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
