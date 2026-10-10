# Nomad Companion for Lyrion

A Lyrion plugin for Nomad Player, the Android app: only the phone running Nomad can control its player. Lyrion's web interface and other controllers can still see what Nomad is playing.

## What counts as control

[`Rules.pm`](NomadCompanion/Rules.pm) holds the definitions:

- **A Nomad player** is one that reports the model name "Nomad".
- **The phone** is any device at the address the player's own connection comes from.
- **Changing the player** is any command aimed at it, except a few that only read, plus the menu actions that play items (such as "favorites playlist play") even though Lyrion flags them as queries.
- **Naming the player** counts too: syncing another player with Nomad, disconnecting Nomad, or transferring a queue onto it.
- **Lyrion's own actions**, such as moving to the next track, are always allowed.

## Commands for the app

| Request | Result |
| --- | --- |
| `nomad version ?` | `_version`: the installed plugin version |

## Layout

- `NomadCompanion/`: the plugin itself, installed as `Plugins/NomadCompanion` in Lyrion's plugin folder
- `t/`: tests, run with `prove t/`

## License

GPL-3.0. See [LICENSE](LICENSE).
