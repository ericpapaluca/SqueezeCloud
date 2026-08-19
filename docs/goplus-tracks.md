# Exposing SoundCloud Go+ tracks

Notes from investigating why Go+ (high-tier subscription) tracks don't show up in
browse/search, and what it takes to expose and play them.

## The short version

Go+ tracks were missing from search for one reason: the v1 search request asked
for `access=playable,preview`, which **excludes** the subscription catalogue. Add
`blocked` to that filter and the official tracks come back — already
`streamable: true`, with the correct full duration. **Playback, however, is the
catch:** every real stream for a Go+ track is DRM-locked (FairPlay + Widevine),
and the non-DRM tiers SoundCloud lists (`aac_1_0`, `mp3_1_0`) return HTTP 404 —
they are not actually served for subscription content. See "DRM" below. Net: Go+
tracks can be *browsed* but currently **cannot be played** in LMS.

## What a Go+ track looks like — v1 vs api-v2

The two APIs describe the same track very differently. This matters because
browse/search uses **v1** (`api.soundcloud.com`) while stream resolution uses
**api-v2** (`api-v2.soundcloud.com`).

Example: the official "Shake It Off" by the verified Taylor Swift account,
track id `294363326`.

| field                | v1 (registered-app token) | api-v2 (anonymous)      |
|----------------------|---------------------------|-------------------------|
| `streamable`         | `true`                    | `true`                  |
| `access`             | **`blocked`**             | — (not present)         |
| `policy`             | `null`                    | `SNIP`                  |
| `monetization_model` | `null`                    | `SUB_HIGH_TIER`         |
| `duration`           | `219246` (full 3:39)      | `30000` (30s snippet)   |
| `full_duration`      | `null`                    | `219246`                |

Key takeaways, all verified live against the user's own account token:

* **v1 does NOT return `policy` or `monetization_model`** — they are `null`. The
  only usable signal on a v1 listing is `access`: `playable` (normal),
  `preview` (30s preview track), or **`blocked`** (Go+ / subscription).
* A Go+ track is `streamable: true` in v1, so a streamable-only filter would keep
  it. It was never the `streamable` check that hid these tracks.
* v1 reports the **full** duration for a blocked track (not a 30s snippet), so the
  browse/now-playing duration is already correct — no special handling needed.
* Anonymously, api-v2 returns only a 30-second snippet (`policy: SNIP`). The full
  track and the `aac_256k` transcoding require an authenticated Go+ web-session
  token.

## Why they didn't appear

The v1 search endpoint **omits `access=blocked` tracks unless `blocked` is included
in the `access` query parameter**. The plugin requested `access=playable,preview`,
so the subscription catalogue never came back — the tracks that *did* appear for a
query like "taylor swift shake it off" were all fan reuploads and covers
(`access: playable`).

This was confirmed by re-running the same v1 search with
`access=playable,preview,blocked`: the verified-artist tracks (`294363326`,
`1650401874`) then appeared, `streamable: true`, `access: blocked`.

> An earlier revision of this branch assumed browse returned Go+ tracks but marked
> them non-streamable, and filtered on `SUB_HIGH_TIER` / `SNIP`. That was wrong on
> both counts: the tracks are streamable in v1, those fields don't exist on v1
> listings, and the tracks were simply excluded by the `access` filter.

## Change in this branch (`feature/expose-goplus-tracks`)

* `Oauth2::hasGoPlusToken()` — is a Go+ token configured?
* `Plugin::_accessParam()` — returns `playable,preview,blocked` when a Go+ token is
  configured, else `playable,preview`. Used for every v1 track listing/search. We
  only ask for `blocked` tracks when we can actually play them in full; without a
  token they'd resolve to a 30-second preview.
* `Plugin::_isTrackExposable()` — keys on `access`: a `blocked` track is shown only
  when a Go+ token is set; otherwise the normal `streamable` rule applies.
* `Plugin::_logTrackEligibility()` — debug log of `streamable/access/policy/
  monetization_model` + verdict, for diagnosing on a live server.
* `_decorateTitle()` — appends ` [Go+]` when a track is `access: blocked` (v1) or
  `SUB_HIGH_TIER`/`SNIP` (api-v2), so Go+ tracks are identifiable in lists.
* Duration: `_trackDurationMs()` still prefers the authenticated `full_duration`
  stashed by the api-v2 resolver, but v1 already reports the full duration for
  blocked tracks, so the previous "cut off at 0:30" risk does not arise from v1
  metadata.

## Verified live (2026-08-19)

Against the user's own registered-app token:

1. v1 `GET /tracks?q=…&access=playable,preview` → only covers/reuploads
   (`access: playable`); the official tracks are absent.
2. v1 `GET /tracks?q=…&access=playable,preview,blocked` → official tracks appear
   (`access: blocked`, `streamable: true`, full duration).
3. v1 `GET /tracks/294363326` directly → HTTP 200, `access: blocked`,
   `duration: 219246`, `policy`/`monetization_model` null.
4. api-v2 confirms the same id is `SUB_HIGH_TIER` / `SNIP` anonymously; with a Go+
   token the resolver returns the full track (`MONETIZE`, all 12 transcodings
   `snipped: false`).

## DRM: which tiers are playable

The authenticated api-v2 resolve returns 12 transcodings. SoundCloud is
**multi-DRM** — every explicit-bitrate tier is offered in both an Apple FairPlay
(`cbc-encrypted-hls`) and a Widevine/PlayReady (`ctr-encrypted-hls`) variant:

| preset     | protocol(s)                        | DRM? | media endpoint |
|------------|------------------------------------|------|----------------|
| `aac_256k` | cbc- / ctr-encrypted-hls           | yes  | resolves, but silent (no FairPlay/Widevine client) |
| `aac_160k` | cbc- / ctr-encrypted-hls           | yes  | resolves, silent |
| `aac_96k`  | cbc- / ctr-encrypted-hls           | yes  | resolves, silent |
| `abr_hq`   | cbc- / ctr-encrypted-hls           | yes  | resolves, silent |
| `abr_sq`   | cbc- / ctr-encrypted-hls           | yes  | resolves, silent |
| `aac_1_0`  | `hls` (AAC-LC, quality `hq`)       | no   | **HTTP 404 — not served** |
| `mp3_1_0`  | `hls` (quality `sq`)               | no   | **HTTP 404 — not served** |

**The non-DRM tiers are phantoms on Go+ tracks.** They are listed in the
transcoding array, but their media endpoint (`/media/…/{id}/stream/hls`) returns
**HTTP 404** on every auth shape (verified live 2026-08-19) — the rendition is
never actually encoded for SUB_HIGH_TIER content. The identical request chain
works on *free* tracks (e.g. `aac_96k` → ~97 kbps), so it is not a probe bug, and
`aac_1_0` never appears on free tracks at all — it is a premium-catalogue artifact.

The result: for a Go+ track, `_selectTranscoding` (commit 2bfdbaf) skips the
encrypted tiers and picks `aac_1_0`, whose media endpoint then 404s — so playback
**fails**. The DRM tiers resolve to a URL but play silence. **There is no playable
stream for a Go+ track in LMS.** No DRM-circumvention path is used or supported.

> **Open confound / definitive test:** the offline probe used a scraped anonymous
> `client_id`, not the plugin's own. A 404 (rather than 403) argues this isn't a
> client-provenance rejection, but the conclusive check is to play a Go+ track on
> the live LMS with commit 2bfdbaf deployed and confirm the `aac_1_0` 404 / no
> audio. If confirmed, the expose-Go+ feature should be reduced to browse-only or
> rolled back — surfacing tracks that cannot play is worse than hiding them.

## Widevine PSSH capture

`ProtocolHandler.pm` captures the Widevine PSSH whenever a **Go+ track** is
played. This runs during normal playback (it is *not* gated on debug logging).
Gating: `getStreamURL` calls `_diagnoseWidevine()` only when `_isGoPlusTrack()` is
true (v1 `access:blocked`, or api-v2 `monetization_model: SUB_HIGH_TIER` /
`policy: SNIP`) **and** no PSSH has been captured for the track yet (a `pssh:<id>`
cache flag makes it once-per-track, so replays don't re-spawn Python).

When it runs it:

* resolves the **first `ctr-encrypted-hls`** transcoding (Widevine/PlayReady) —
  the PSSH is identical across presets, so only one is fetched; FairPlay (`cbc-`)
  and the other tiers are ignored,
* runs `_detectDrmSystem($m3u8)` to log which systems the manifest declares —
  **FairPlay** (`com.apple.streamingkeydelivery`), **Widevine** (UUID
  `edef8ba9-…-d51d21ed`), **PlayReady** (`com.microsoft.playready` / UUID
  `9a04f079-…`), or plain **ClearKey-AES128** (`METHOD=AES-128`),
* extracts the Widevine PSSH (`_widevinePssh()`) into a variable and hands that
  base64 **directly** to `tools/pssh_inspect.py` via a `--b64` argument
  (`_runPsshInspector()`) — no file is written or read. Invoked without a shell
  (list-form `open`, so the base64 is one literal argv element); interpreter
  `python3`, override with the `pythonPath` plugin pref — and logs the decoder's
  output.

The capture line and the decoder output are logged at **info** level, so they are
visible during normal playback:

```
Widevine PSSH captured for track 294363326 (aac_256k)
Widevine diagnostic: running python3 …/tools/pssh_inspect.py --b64 <pssh>
pssh_inspect: system id : edef8ba9-79d6-4ace-a3c8-27dcd51d21ed  (Widevine)
pssh_inspect:   key_id     : …
pssh_inspect:   provider   : buydrmkeyos
pssh_inspect:   content_id : …
```

You can also run the decoder by hand on any base64 PSSH string:

```
python3 tools/pssh_inspect.py --b64 'AAAA…'
```

Cost/caveats: this adds two HTTP round-trips (resolve + manifest fetch) and one
short `python3` subprocess to the *first* play of each Go+ track. It is wrapped in
`eval` so any failure is logged and ignored — it can never break stream
resolution — and its result is never handed to the player.

`tools/pssh_inspect.py` only parses public manifest metadata — it does not contact
a license server, build a license challenge, or produce keys. Obtaining the actual
decryption key still requires a licensed CDM, which is out of scope.

It is purely informational: the whole block is wrapped in `eval` and its output
never feeds the player, so it cannot affect normal playback.

> The benign transcode-routing and ffmpeg-wrapper teaching examples
> (`sc_goplus` / `sc_demo` / `bin/scwrap.pl`) are documented separately in
> [`transcode-routing.md`](transcode-routing.md).

## To verify on the user's LMS

1. With a Go+ token set, search a mainstream artist and confirm the official
   tracks now appear tagged `[Go+]`.
2. Attempt to play one. Expected (per the offline probe): `Selected transcoding
   preset aac_1_0`, then a 404 from the media endpoint and no audio — confirming
   Go+ tracks are browse-only in LMS. If it *does* play, the offline 404 was a
   client_id-provenance artifact and this doc needs revisiting.
3. Remove/blank the token and confirm Go+ tracks disappear again (back to
   `playable,preview` only).
