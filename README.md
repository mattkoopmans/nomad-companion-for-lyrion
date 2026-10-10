# Nomad Companion for Lyrion

A Lyrion plugin for Nomad Player, the Android app: only the phone running Nomad can control its player. Lyrion's web interface and other controllers can still see what Nomad is playing.

## Installation

1. In Lyrion go to **Settings → Manage Plugins**
2. At the bottom, under **Additional Repositories**, add:
   ```
   https://raw.githubusercontent.com/mattkoopmans/nomad-companion-for-lyrion/main/repo.xml
   ```
3. Click **Apply**, then find **Nomad Companion** in the plugin list, tick it and click **Apply** again
4. Restart Lyrion when prompted

Lyrion will then offer new versions automatically.

To install by hand instead, unzip `NomadCompanion-x.y.z.zip` from the [latest release](https://github.com/mattkoopmans/nomad-companion-for-lyrion/releases/latest) into Lyrion's plugin folder (shown under **Settings → Information → Plugin Folders**) and restart Lyrion.

## What counts as control

[`Rules.pm`](NomadCompanion/Rules.pm) holds the definitions:

- **A Nomad player** is one that reports the model name "Nomad".
- **The phone** is any device at the address the player's own connection comes from.
- **Changing the player** is any command aimed at it, except a few that only read, plus the menu actions that play items (such as "favorites playlist play") even though Lyrion flags them as queries.
- **Naming the player** counts too: syncing another player with Nomad, disconnecting Nomad, or transferring a queue onto it.
- **Lyrion's own actions**, such as moving to the next track, are always allowed.

## How it works

[`Plugin.pm`](NomadCompanion/Plugin.pm) checks every request as Lyrion runs it and works out which device sent it: from the connection for JSON-RPC (Material and most apps), the command-line interface, Cometd (Squeezebox controllers and some apps) and the classic web interface. A request made while another one runs, such as a plugin acting for a controller, counts as coming from the same device.

A refused request isn't run. The device gets an `error` result ("Only the phone running Nomad can control this player.") and Lyrion's server log notes the refusal.

Known gaps:

- **Delayed requests:** a request made later, for example after fetching a menu from the internet, can't be traced to a device and is let through. The classic web interface does this when playing from online menus such as Tidal.
- **Changing network:** after the phone moves to another network, its requests are refused until its player has reconnected from the new address.
- **Not a security boundary:** any device can still turn the plugin off in Lyrion's settings. The lock prevents accidents, not deliberate changes.

## Commands for the app

| Request | Result |
| --- | --- |
| `nomad version ?` | `_version`: the installed plugin version; `_test_mode`: 1 if test mode is on |
| `nomad takeover player:<id>` | Nomad continues from the other player, which stops |
| `nomad copy player:<id> mode:replace\|append start:0\|1` | Nomad gets the other player's queue; the other player is left alone |
| `nomad send player:<id>` | The other player continues from Nomad, which stops |

The last three move music without syncing the players, and only Nomad's phone can send them. They're aimed at the Nomad player, and `player` must be another player that isn't a Nomad.

- **Queues** are copied in play order, with shuffle flattened, and repeat copied across. A player that stops keeps its own queue.
- **Starting:** the receiving player starts at the same track and time. It plays if the other player was playing; otherwise it's held paused at that point, and pressing play carries on from there. Tracks that can't be started part-way, such as radio streams, start from the beginning.
- **Copy:** `mode:replace` (the default) replaces Nomad's queue, starting it as above with `start:1`, or leaving it stopped at the top with `start:0`. `mode:append` adds the tracks to the end of Nomad's queue without touching its playback.
- **Send** switches the other player on first, without resuming its own queue.
- **Results:** `_count` (tracks copied) and, when a player was started, `_index`, `_time` (seconds) and `_mode` (`play`, `pause` or `stop`). Problems come back as `error`.

## Scrobbling

Lyrion doesn't scrobble Nomad players, to Last.fm or ListenBrainz, because it can't see what Nomad plays while offline. Scrobble from the phone instead: install the Last.fm app, sign in, and let it scrobble other apps, including Nomad. It asks for notification access to see what's playing, and keeps scrobbles made offline until the phone is back online.

The plugin keeps Lyrion's scrobbling account for Nomad players set to none, however it's chosen, and turns off any account chosen before the plugin was installed. Nomad's scrobbling settings page in Lyrion, and its Squeezebox controller menu, show this guidance instead of the choice of accounts.

## Test mode

**Settings → Advanced → Nomad Companion** has a test mode, off by default. While it's on, the computer running Lyrion can control Nomad players too, so the app can be tested from it.

## Layout

- `NomadCompanion/`: the plugin itself, installed as `Plugins/NomadCompanion` in Lyrion's plugin folder
- `t/`: tests, run with `prove t/`
- `repo.xml`: the plugin repository Lyrion reads; the release workflow keeps it up to date

## Releasing

1. Update `<version>` in `NomadCompanion/install.xml`, then commit and push
2. Tag and push, e.g. `git tag v0.2.0 && git push origin v0.2.0`

The [release workflow](.github/workflows/release.yml) runs the tests, builds the zip, publishes it as a GitHub release and then points `repo.xml` at it. Tags on a `Testing` branch become pre-releases in `repo-testing.xml` instead.

## License

GPL-3.0. See [LICENSE](LICENSE).
