# Transcode routing & the ffmpeg wrapper (`sc_goplus`, `sc_demo`, `scwrap.pl`)

This document covers two **benign teaching examples** added on the
`feature/expose-goplus-tracks` branch. Both demonstrate how a Lyrion/LMS
protocol-handler plugin can influence the exact ffmpeg command LMS runs for a
stream. Neither decrypts anything, and neither makes a Go+ track playable — that
is a DRM wall, documented in [`goplus-tracks.md`](goplus-tracks.md).

- **`sc_goplus`** — conditional routing: send Go+ tracks to a *different*
  `custom-convert.conf` rule than normal tracks.
- **`sc_demo` + `bin/scwrap.pl`** — a wrapper script that carries a per-track
  value (a volume gain) to ffmpeg when no built-in placeholder exists.

## How it is wired into LMS playback

This is on the **real** play path, not a debug side-channel. When LMS plays a
`soundcloud://` track it asks the protocol handler for the *source format*, then
matches that against `custom-convert.conf`:

```
play soundcloud:// track
  → ProtocolHandler::formatOverride($class, $song)   # re-resolves the stream URL
        returns _formatForTrack($track)              #   = sc_goplus | sc_demo | soundcloud
  → ProtocolHandler::canDirectStreamSong()           # same _formatForTrack() value
        → synthetic format, no player decodes it natively → NOT direct-streamable
        → LMS is forced down the transcode path
  → LMS matches "<sourcefmt> <destfmt> * *" in custom-convert.conf
  → LMS forks THAT command line for the transcode
```

So the value returned by `_formatForTrack()` is what selects the rule, and the
selected rule's command line is what LMS actually executes. Nothing here is gated
on debug logging.

`getFormatForURL()` returns the base `soundcloud` type; `formatOverride()` is the
hook that runs at play/seek time and returns the *effective* format.

## `_formatForTrack()` — the routing decision

`ProtocolHandler.pm`:

```perl
sub _formatForTrack {
    my $track = shift;
    return 'sc_demo' if $prefs->get('demoGainDb');          # wrapper demo (see below)
    return 'soundcloud' unless ref($track) eq 'HASH';
    return _isGoPlusTrack($track, $track) ? 'sc_goplus' : 'soundcloud';
}
```

- Normal track → `soundcloud` (the original rules, unchanged).
- Go+ track (v1 `access:blocked`, or api-v2 `SUB_HIGH_TIER`/`SNIP`) → `sc_goplus`.
- `demoGainDb` pref non-zero → `sc_demo` (takes precedence, to make the wrapper
  demo easy to trigger; default `0`, so normal installs never hit it).

## Example 1 — `sc_goplus`: conditional routing

The `sc_goplus` rules in `custom-convert.conf` are identical to the plain
`soundcloud` rules except for a benign `-metadata comment=SoundCloud-GoPlus` tag,
so you can *see* the branch take effect in the forked ffmpeg command:

```
sc_goplus mp3 * *
        # RB:{BITRATE=-B %B}T:{START=-ss %s}
        [ffmpeg] -loglevel quiet -i $URL$ $START$ -metadata comment=SoundCloud-GoPlus -f wav - | [lame] --silent -q $QUALITY$ $BITRATE$ - -
```

This proves the source-format branch changes the real command line. It does not
change the audio — a Go+ stream is still DRM-locked or 404.

## Example 2 — `sc_demo` + `scwrap.pl`: a per-track value with no placeholder

`custom-convert.conf` only understands a fixed set of substitution placeholders
(`$URL$`, `$START$`, `$BITRATE$`, `$QUALITY$`, `$SAMPLERATE$`, `$CHANNELS$`, and
the capability-defined `$START$`/`$END$`/`$BITRATE$`). There is **no** placeholder
for an arbitrary plugin-computed value. The three ways to get one to ffmpeg anyway:

| technique | when | example here |
|-----------|------|--------------|
| **A. categorical** | value is one of a few states | `sc_goplus` picks a different rule |
| **B. scalar in `$URL$`** | value is a string you can attach to the URL | `#scgain=<db>` fragment |
| **C. wrapper script** | value is arbitrary / needs computation | `bin/scwrap.pl` reads it and builds the command |

(`%ENV` is *not* reliable — LMS forks the transcode pipeline itself, so environment
variables set in the plugin don't dependably reach the transcode process.)

`sc_demo` uses **B + C** together, carrying a playback **volume gain** (dB):

1. **Pref** — `Plugin::demoGainDb` (default `0` = disabled).
2. **Stash (B)** — when routed to `sc_demo`, `formatOverride()` appends a private
   `#scgain=<db>` fragment to the resolved stream URL via `_appendGainFragment()`
   (idempotent — re-tagging on seek/refresh replaces rather than stacks).
3. **Rule** — the `sc_demo` rules call the wrapper instead of ffmpeg directly:
   ```
   sc_demo pcm * *
           #
           [perl] "@PLUGINDIR@/bin/scwrap.pl" s16le $URL$
   ```
4. **Wrapper (C)** — `bin/scwrap.pl <outfmt> $URL$`:
   - reads `scgain=` out of the URL fragment,
   - **strips the fragment** so ffmpeg fetches the exact signed URL,
   - execs ffmpeg (list-form, **no shell**) with a matching `-af volume=<db>dB`.
5. **Path fixup** — `Plugin::_fixupConvertPaths()` rewrites the `@PLUGINDIR@` token
   in `custom-convert.conf` to the plugin's real basedir at init (via
   `Slim::Utils::PluginManager->dataForPlugin`), so the `[perl] "@PLUGINDIR@/…"`
   rules resolve to an absolute path. It runs once (no-op after the token is gone)
   and is `eval`-guarded so it can't break init.

This is strictly **benign**: it only adjusts playback volume. It is not, and must
not become, a decryption path.

## Trying it

1. Set the `demoGainDb` plugin pref (e.g. `3` or `-4`).
2. Play any track.
3. Watch the LMS transcode log for the wrapper's trace line:
   ```
   scwrap: outfmt=wav gain=3dB extra=
   ```
   (bump `-loglevel` off `quiet` in the rule to also see the full ffmpeg command.)
4. Set the pref back to `0` to restore normal routing.

## Files

| file | role |
|------|------|
| `ProtocolHandler.pm` | `_formatForTrack()`, `_appendGainFragment()`, `formatOverride()` wiring, `canDirectStreamSong()` |
| `Plugin.pm` | `demoGainDb` pref, `_fixupConvertPaths()` |
| `custom-convert.conf` | `sc_goplus` and `sc_demo` rules |
| `bin/scwrap.pl` | the benign ffmpeg wrapper (volume gain) |
