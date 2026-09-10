# Third-party proxy modules

Third-party proxy mode (Surge / Quantumult X / Loon / Shadowrocket / Stash /
Egern) uses modules and scripts hosted in this repository under
`ThirdParty/WlocScripts/`. The original WLOC intercept approach is based on
Yu9191/wloc; this project now vendors the adapted copies so subscriptions do
not depend on that upstream repository remaining public.

## Subscription addresses

The App copies the same module files into the application bundle and, by default,
serves them on the device:

- on-device (default):
  `http://127.0.0.1:18766/modules/<file>`
  Script paths inside the served module are rewritten to
  `http://127.0.0.1:18766/dist/v1/wloc.js` and `wloc-settings.js`.
- GitHub mirror:
  `https://gh-proxy.org/https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/<file>`
- GitHub direct:
  `https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/<file>`

Importing or refreshing an on-device subscription requires this App to stay
running so the loopback server can answer. After the client caches the scripts,
location rewriting no longer needs GitHub.

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

After changing these files, rebuild the App so the bundled copy updates. GitHub
URLs only matter when the user switches the module source away from on-device.

## Script protocol

`wloc.js` patches Apple WLOC responses and reads coordinates from the
`wloc_settings` persistent key or the module `argument` config.
`wloc-settings.js` implements `wloc-settings/save` (query/clear/save) using
`lon`/`lat`/`acc`/`randomRadius` parameters.

The App's third-party save sends `lon`/`lat`/`acc`, matching the vendored
settings script. Motion-state simulation (fields 11/12) is not implemented by
these scripts and is unavailable in third-party mode; it remains available in
APP mode (built-in proxy).
