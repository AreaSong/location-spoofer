# Third-party proxy modules

Third-party proxy mode (Surge / Quantumult X / Loon / Shadowrocket / Stash /
Egern) uses modules and scripts hosted in this repository under
`ThirdParty/WlocScripts/`. The original WLOC intercept approach is based on
Yu9191/wloc; this project now vendors the adapted copies so subscriptions do
not depend on that upstream repository remaining public.

## Subscription addresses

The App builds each client's module subscription URL from this repository:

- default mirror (gh-proxy):
  `https://gh-proxy.org/https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/<file>`
- direct:
  `https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/<file>`

| Module file | Client |
|---|---|
| `wloc.module` | Shadowrocket |
| `wloc.sgmodule` | Surge and Egern |
| `wloc.conf` | Quantumult X |
| `wloc.lpx` | Loon |
| `wloc.stoverride` | Stash |

No `?v=` cache-bust is appended. Re-importing the subscription in the proxy
client re-fetches the module. Script files live at
`ThirdParty/WlocScripts/dist/v1/` and are referenced by each module's
`script-path`.

After changing these files, they must be pushed to `AreaSong/location-spoofer`
`main` before clients can download them.

## Script protocol

`wloc.js` patches Apple WLOC responses and reads coordinates from the
`wloc_settings` persistent key or the module `argument` config.
`wloc-settings.js` implements `wloc-settings/save` (query/clear/save) using
`lon`/`lat`/`acc`/`randomRadius` parameters.

The App's third-party save sends `lon`/`lat`/`acc`, matching the vendored
settings script. Motion-state simulation (fields 11/12) is not implemented by
these scripts and is unavailable in third-party mode; it remains available in
APP mode (built-in proxy).
