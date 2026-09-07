# omarchy-tvremote

**Samsung TV Remote** — a Samsung smart TV's remote in the Omarchy bar.

Volume, a D-pad, OK and Back — sent to the TV over its own Tizen
remote-control WebSocket. While the popup has focus the **physical arrow
keys, Enter and Backspace drive the TV directly**, which is the point of the
widget; the on-screen D-pad is there for the mouse. Scrolling the bar icon
changes volume without opening anything, and right-clicking it mutes.

**Holding a button repeats like the real remote.** A press sends Tizen's
`Press`, the release sends `Release`, and the TV runs its own repeat
acceleration in between — so a held volume button ramps at exactly the rate
the physical remote ramps, rather than at whatever rate a timer here would
pick. A tap is just a very short hold.

Streaming apps get one-click tiles — YouTube on a full-width primary tile,
then Netflix, Prime Video and Spotify — and the panel can probe the TV for
whatever else is installed.

## Which TVs does this support?

Verified end to end on exactly one set: **QN55Q8FAAFXZC** (2017 QLED, Tizen
2.0.25, firmware reported as "Unknown"). Everything below that is not marked
*verified* is reasoned from the protocol, not tested — if you try it on
another model, please open an issue saying what worked.

| Era | Channel | Status |
|---|---|---|
| 2016+ Tizen (`TokenAuthSupport: true`) | `wss://<tv>:8002` + token | **Verified.** The Allow prompt appears once, the token is saved, everything works |
| 2014–15 Tizen (no token auth) | `ws://<tv>:8001`, no token | *Untested.* The client falls back to this automatically when 8002 refuses |
| 2011–13 (pre-Tizen) | binary protocol on `:55000` | **Not supported.** Different protocol entirely |

Run `tvctl discover` to see what your set reports:

```
192.168.100.59   55" QLED  (QN55Q8FAAFXZC)
                 mac=94:e6:ba:a2:ea:85  token-auth=yes  remote=yes
```

`remote=yes` is the one that matters — it is the TV telling you it accepts
remote keys.

Individual features degrade independently, so a partly-supported TV is still
useful:

- **Keys** need the remote-control channel. Everything else is optional.
- **The volume number** is read over UPnP `RenderingControl` on port 9197. If
  your set does not answer, keys still work and the number shows `—`.
- **App tiles** need `POST /api/v2/applications/<id>`. App ids are per-model,
  so they are probed, never assumed — see below.
- **Wake-on-LAN** needs network standby enabled on the TV.

## Finding the TV

`tvctl discover` sweeps the local /24 asking each address for `/api/v2/`. One
Samsung TV is chosen automatically and remembered; several, and the panel asks
which one on first launch. The address is cached in
`~/.local/state/omarchy/tvremote-host`, and re-discovered if the TV moves.

This is deliberately a TCP sweep rather than SSDP. SSDP is the documented way
and it is one packet instead of 254, but its replies are unicast UDP from the
TV to an ephemeral port, which conntrack does not treat as ESTABLISHED — so a
default-deny firewall eats them silently and discovery "just doesn't work"
with nothing in any log to explain it. The sweep is plain outbound TCP that
any firewall already permits, and it takes about three seconds.

## Requirements

**Python 3, and nothing else.** No pip, no AUR, no `websocket-client`: the TV
speaks plain RFC6455 over TLS with a self-signed cert, so `tvctl` implements
the handful of frames it needs with the standard library. The TV just has to
be reachable on the network.

## Install

```bash
git clone https://github.com/rdoupe/omarchy-tvremote \
  ~/.config/omarchy/plugins/io.github.rdoupe.tvremote
omarchy bar put io.github.rdoupe.tvremote --after omarchy.audio
```

Set the TV's address in the widget's settings (default `192.168.100.59`).

### First run

Opening the panel is all it takes. Measured on a wiped install:

```
+2.5s  TV found on the network, four default app tiles seeded
+2.6s  reachable, not yet paired
+8.7s  paired -- token issued and saved
```

The TV shows an **Allow / Deny** prompt the first time a given client name
connects. Accept it with the physical remote; the token is saved to
`~/.local/state/omarchy/tvremote-token` and pairing never happens again.

Two things about that prompt are worth knowing, both learned the hard way:

- **The prompt lives exactly as long as the connection that raised it.** Never
  retry while it is up — each new attempt dismisses the pending one, so a
  retry loop guarantees nobody can click it in time. This client makes one
  connection and waits.
- **A tokenless handshake is slow** (~8s here, against a routine 1.5s), so the
  first connect gets a much longer timeout than later ones. With the ordinary
  timeout it raced the deadline and failed with a bare `TimeoutError` on the
  one connection that matters most.

Right after issuing a token the TV closes the socket; the client reconnects
with it and the connection is then stable. That single disconnect on first run
is expected.

### Resetting the pairing

Deleting the token file only clears *this* side. **The TV keeps its own
allow-list**, so reconnecting under the same client name is re-authorised
silently and never re-prompts. To genuinely test a first run, either use a
name the TV has not seen (`TV_NAME=…`) or remove the entry on the TV under
*Settings → General → External Device Manager → Device Connect Manager →
Device List*. That list is also where to look if the prompt never appears —
the device was probably denied once, and the TV will not ask again.

Optional keybinding — opens the popup already focused, so the arrow keys are
live immediately:

```lua
o.bind("SUPER + CTRL + SHIFT + S", "Samsung TV Remote",
       "omarchy-shell io.github.rdoupe.tvremote toggle")
```

## Keyboard

While the popup has focus:

| Key | Does |
|---|---|
| arrows / `hjkl` | D-pad |
| Enter / Space | OK |
| Backspace / `b` | Back |
| `-` | Volume down |
| `m` | Mute |
| `1`-`9` | Launch the app on that tile |
| `=` | Volume up (`+` works too) |
| Esc | Close |

The app numbers are positional — `3` is whatever sits in the third tile — so
they keep working when a rescan changes the list. Each tile shows its number,
and each row of the panel carries its own hint underneath, rather than one
legend at the foot describing controls further up.

## Apps

App tiles are configured in `~/.config/omarchy/tvremote-apps.json`, seeded on
first run:

```json
{
  "apps": [
    { "key": "youtube", "name": "YouTube", "appId": "111299001912",
      "color": "#ff0033", "show": true }
  ]
}
```

Order is the panel's order, and the first entry gets the large primary tile —
so the app you use most is a config edit away from being the easiest thing to
click. `show: false` keeps an app out of the tiles and behind the panel's
**"N more on the TV"** section; right-clicking any app toggles that.

**"rescan"** in the panel (or `tvctl scan --save`) probes the TV for installed
apps and merges what it finds into the file, leaving your names, colours and
order alone.

### Why app ids are probed rather than listed

Tizen application ids are per-model and per-firmware — the id every list on the
internet gives for Netflix, `11101200001`, is a **404** on this set, while
`3201907018807` works. Worse, this TV answers no enumeration request at all:
there is no `/api/v2/applications/` listing and `ed.installedApp.get` never
replies. So `tvctl scan` probes a catalog of known ids one at a time (in
parallel — a full sweep takes under a second) and keeps whichever the TV
acknowledges. Anything the catalog misses can still be added to the JSON by
hand.

The TV also serves **no artwork** for its apps — `/api/v2/applications/<id>/icon`,
`/icon.png`, `/image`, `/thumbnail` and the DIAL equivalent are all 404s. The
tiles use the brand marks in the Nerd Font the bar already renders with
(YouTube, Netflix, Amazon, Spotify, Apple, Twitch), which are sharper at tile
size than a bitmap would be; apps with no mark fall back to their name in a
brand colour.

## Using it from the shell

`tvctl` is a usable remote on its own:

```bash
cd ~/.config/omarchy/plugins/io.github.rdoupe.tvremote
./tvctl volup
./tvctl left left enter      # several keys in one connection
./tvctl app netflix
./tvctl apps                 # configured apps + install status
./tvctl scan --save          # discover what is on the TV
./tvctl state
```

```bash
./tvctl hold voldown 1.5     # hold a key, the way the panel's buttons do
```

Keys: `up down left right enter back volup voldown mute home power`.
Override the address with `TV_HOST=…`, the app file with `TV_APPS_FILE=…`.

## Waking the TV

A TV that is off answers nothing on any port, so the power button cannot
reach it over the remote socket. `tvctl wake` sends a **wake-on-LAN magic
packet** to the NIC instead, which keeps listening while the set sleeps.

The MAC is learned automatically from `/api/v2/` whenever the TV is reachable
and cached in `~/.local/state/omarchy/tvremote-mac`, so it is on hand later
when the TV is off and cannot be asked. Override with `TV_MAC=…`.

In the panel, the power button turns the TV off when it is on and wakes it
when it is off — and **clicking an app tile on a sleeping TV wakes it and
opens that app**, which is what clicking Netflix on a dark screen plainly
means. The status line says so rather than leaving you to guess: *"off —
press ⏻ or an app to turn it on"*. This needs **network standby** enabled on the TV (*Settings →
General → Network → Expert Settings → Power On with Mobile*, wording varies by
model); with it off, the NIC sleeps too and no packet can reach it.

## How it works

The remote channel (`wss://<tv>:8002/api/v2/channels/samsung.remote.control`)
is **write-only in practice**: the TV confirms it took a key and tells you
nothing else — not the volume, not what is on screen. Two consequences shape
the code:

- **The volume number is read over UPnP**, not over the remote channel:
  `RenderingControl` on port 9197, queried just after a volume key lands.
- **The panel shows the TV's ack**, not the click, so a key that did not make
  it does not light up.

Apps are launched with a REST `POST /api/v2/applications/<id>` rather than a
remote key, because the remote channel can only click buttons — reaching an app
through it would mean guessing at the home screen's layout.

A TLS handshake per keypress is far too slow to steer a menu with, so `tvctl
serve` holds one socket open and takes commands on stdin; the panel starts it
when the popup opens and stops it when the popup closes. The TV pings that
socket and hangs up with `notack` if the pong never comes, so the child owns a
reader thread whose only job is to answer.

## License

MIT
