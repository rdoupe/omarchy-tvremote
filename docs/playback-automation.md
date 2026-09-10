# Microphone playback automation

## Status

Deferred. The plugin does not currently change TV playback when an application
uses the microphone.

## Required behavior

When microphone capture begins:

1. Determine whether the foreground TV app is actively playing media.
2. Pause it only when it is playing.
3. Remember whether this automation caused the pause.

When microphone capture ends, resume only when step 3 is true. Media that was
already paused must remain paused. This must be driven by PipeWire capture-stream
activity, not by the default microphone's mute flag or by a particular dictation
application.

## Why the generic Samsung remote is insufficient

The local Samsung interfaces used by this plugin expose power, volume, mute,
foreground-application visibility, and remote key delivery. They do not expose
a verified, app-independent playing/paused state:

- The remote-control WebSocket acknowledges key delivery but does not report
  whether the foreground app was playing.
- The application endpoint reports `running` and `visible`, which do not imply
  active playback.
- UPnP AVTransport does not represent playback inside native streaming apps on
  the tested TV.
- A dedicated pause key still cannot reveal whether playback was already
  paused, and app handling of media keys is not guaranteed to be uniform.

Consequently, sending play on microphone release would start media that was
paused before microphone use. Never resuming avoids that error but does not
meet the required behavior.

This limitation is consistent with Home Assistant's Samsung TV integration,
which [assumes playback state and updates that assumption only after its own
commands](https://github.com/home-assistant/core/blob/dev/homeassistant/components/samsungtv/media_player.py).

## App-specific state sources

### YouTube

The tested Samsung TV advertises its YouTube app through DIAL. A read-only probe
returned a screen identifier, YouTube issued a Lounge token for it, and the
screen availability check succeeded. No identifiers or tokens are stored here.

YouTube Lounge reports playing and paused states and provides separate play and
pause commands, so it can support the required state-preserving behavior for
YouTube. It is YouTube-specific, cloud-backed, and undocumented; an example
implementation is [youtube-lounge-rs](https://github.com/bertybuttface/youtube-lounge-rs).

### Spotify

Spotify's authenticated Web API exposes the active device and `is_playing`, so
it can potentially provide equivalent behavior for Spotify Connect. It is also
app-specific and requires account authorization. See [Get Playback
State](https://developer.spotify.com/documentation/web-api/reference/get-information-about-the-users-current-playback).

### Other configured apps

No authoritative playback-state source has been identified for Netflix, Prime
Video, Disney+, Apple TV, Tubi, Internet, or Xbox. Supporting only YouTube and
Spotify would therefore not provide generic TV behavior.

## SmartThings

SmartThings documents a media playback capability with `playbackStatus`, but a
capability definition does not establish that this TV publishes accurate state
for every native app. Existing Samsung TV integrations still maintain an
optimistic local state instead of reading a dependable TV-wide playback value.
Treat SmartThings as unverified until real capability responses are tested on a
supported TV. See the [SmartThings media playback capability](https://developer.smartthings.com/docs/home-api/home-api-reference).

## Criteria for revisiting

Resume this feature only when an interface can provide all of the following:

- authoritative playing/paused state before microphone capture starts;
- explicit, non-toggle pause and play operations;
- identity for the same playback session on release;
- coverage across the supported foreground apps, or an honest opt-in scope that
  clearly identifies which apps are supported;
- no committed device identifiers, account tokens, or network addresses.
