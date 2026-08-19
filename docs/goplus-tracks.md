# Exposing SoundCloud Go+ tracks

Notes from investigating why Go+ (high-tier subscription) tracks don't show up in
browse/search, and what it takes to expose and play them.

## What a Go+ track looks like

Querying api-v2 anonymously (web `client_id` only) for a mainstream artist returns
a mix of monetization models. A Go+ track is identifiable by:

| field                 | Go+ track          | normal track            |
|-----------------------|--------------------|-------------------------|
| `monetization_model`  | `SUB_HIGH_TIER`    | `AD_SUPPORTED` / `BLACKBOX` |
| `policy`              | `SNIP`             | `MONETIZE`              |
| `streamable` (api-v2) | `true`             | `true`                  |

Example (`Aston Martin Music (feat. Drake …)`, id `278008021`), fetched
**anonymously**:

* `duration: 30000` ms but `full_duration: 270655` ms — a 30-second snippet.
* `media.transcodings`: only `mp3_0_1` (`sq`), every one flagged `snipped: true`.
  No `aac_160k`, no `aac_256k`.

So without authentication a Go+ track resolves to a **30-second MP3 preview**. Only
an authenticated Go+ session (the browser web-session token) returns `policy:
ALLOW`, the full duration, and the `aac_256k` transcoding.

## Why they don't appear today

Browsing/search goes through the **v1** API (`api.soundcloud.com`), and the v1 API
marks Go+ tracks as **not streamable** for third-party apps. Both list parsers drop
every non-streamable track:

```perl
for my $entry (@{$json->{'collection'}}) {
    if ($entry->{'streamable'}) { push @$menuEntries, _makeMetadata(...); }
}
```

So Go+ tracks are filtered out before they ever reach a menu. (v1 is requested with
`access=playable,preview`, so the API *does* return them as previews; the
client-side `streamable` check is what hides them.)

> The exact v1 field values for a Go+ track could not be observed offline — v1
> rejects the web `client_id` (403) and needs the registered-app token. The debug
> logging added in this branch (`_logTrackEligibility`) prints
> `streamable/access/policy/monetization_model` for every track so this can be
> confirmed on a live server.

## The duration trap

Even once a Go+ track is exposed and resolved via api-v2, the v1 metadata used to
build the menu reports the **30-second snippet** duration (the registered-app token
is not a Go+ session). If we trust it, the player stops at 0:30. So the api-v2
resolver now stashes the authenticated `full_duration` on the track and in the
cache, and the metadata builder prefers it.

## Change in this branch (`feature/expose-goplus-tracks`)

* `Oauth2::hasGoPlusToken()` — is a Go+ token configured?
* `Plugin::_isTrackExposable()` — keep a track if `streamable`, **or** if it looks
  like a Go+ track (`SUB_HIGH_TIER` / `SNIP` / `preview`) **and** a Go+ token is
  set. Without a token, Go+ tracks stay hidden (they'd only preview).
* `Plugin::_logTrackEligibility()` — debug log of the eligibility fields + verdict.
* Duration: `_trackDurationMs()` prefers the api-v2 `full_duration`
  (stashed as `sc_duration_ms` / cached as `duration:<id>`) over the v1 snippet;
  `_formatDuration()` uses it too.
* `_decorateTitle()` — appends ` [Go+]` so Go+ tracks are identifiable in lists.

## Open questions / to verify live

1. Confirm the v1 `streamable`/`access`/`policy` values for a Go+ track from the
   debug log (do they match the api-v2 values above?).
2. Confirm a Go+ track now (a) appears in search, (b) plays full-length at
   `aac_256k`, (c) shows the correct duration, not 0:30.
3. Non-Go+ behaviour unchanged (Go+ tracks remain hidden without a token).
