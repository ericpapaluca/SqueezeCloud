# Exposing SoundCloud Go+ tracks

Notes from investigating why Go+ (high-tier subscription) tracks don't show up in
browse/search, and what it takes to expose and play them.

## The short version

Go+ tracks were missing from search for one reason: the v1 search request asked
for `access=playable,preview`, which **excludes** the subscription catalogue. Add
`blocked` to that filter and the official tracks come back — already
`streamable: true`, with the correct full duration. Playback then resolves them in
full via the api-v2 browser flow when a Go+ token is configured.

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
4. api-v2 confirms the same id is `SUB_HIGH_TIER` / `SNIP`; with a Go+ token the
   resolver returns the full track + `aac_256k` (per the HQ-migration work).

## To verify on the user's LMS

1. With a Go+ token set, search a mainstream artist and confirm the official
   tracks now appear tagged `[Go+]`.
2. Confirm one plays full-length at `aac_256k` (log: `Selected transcoding preset
   aac_256k`) and shows the correct duration.
3. Remove/blank the token and confirm Go+ tracks disappear again (back to
   `playable,preview` only).
