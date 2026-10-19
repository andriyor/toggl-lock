# Toggl Lock

Your running [Toggl Track](https://track.toggl.com) timer as a Live Activity on the iPhone Lock Screen
(and Always-On Display), even when the timer is started or stopped on another device, e.g. the
desktop browser. With nothing running it shows "No running timer".

The activity stays up permanently: a small Node server watches Toggl and sends APNs pushes.
The elapsed time ticks on the phone, so pushes go out only when something changes.

## Layout

- `ios/` — the iPhone app and its Live Activity widget (XcodeGen: `ios/project.yml`)
- `server/` — the Node server that watches Toggl and sends APNs pushes (no runtime dependencies;
  `package.json` is only for Prettier and `npm test`)

## Setup

Needs a paid Apple Developer account (push notifications) and Node ≥ 22.18, which runs the
server's TypeScript directly (type stripping) — no build step, no `npm install` to run it.

1. Xcode → Settings → Accounts: add the paid account; put its team id in `ios/project.yml` (`DEVELOPMENT_TEAM`).
2. developer.apple.com → Certificates, Identifiers & Profiles → Keys → `+` → enable
   _Apple Push Notifications service (APNs)_ → download `AuthKey_<KEY_ID>.p8` (only once).
   The team id is under Membership details.
3. `cp server/.env.example server/.env` and fill it in (`.env` and `*.p8` are gitignored):
   APNs key path/id/team, and `TOGGL_API_TOKEN` from track.toggl.com/profile. Optionally
   `APP_SECRET` (`openssl rand -hex 32`), required once the server is reachable from outside the LAN;
   put the same value in `ios/Secrets.xcconfig` (`cp ios/Secrets.xcconfig.example ios/Secrets.xcconfig`,
   gitignored — the app sends it as `Authorization: Bearer …`). Leave both empty on a LAN-only setup.
4. Start the server (see the two modes below), e.g.

       cd server && npm start   # = node --env-file=.env toggl-poll.ts; needs no npm install

5. Build and run the app on the iPhone (same Wi-Fi as the Mac), allow Local Network access.
   In Xcode: `cd ios && xcodegen generate && open LockActivity.xcodeproj`, then Run.
   Or from the terminal:

       cd ios
       xcodegen generate
       xcodebuild -project LockActivity.xcodeproj -scheme LockActivity -destination 'id=<device-udid>' \
         -derivedDataPath build -allowProvisioningUpdates build
       xcrun devicectl device install app --device <device-udid> build/Build/Products/Debug-iphoneos/LockActivity.app
       xcrun devicectl device process launch --device <device-udid> com.andriyor.LockActivity

   (`xcrun devicectl list devices` shows the UDID.)

On launch the app sends the server its push token and the activities still alive on the phone; if
the server's activity isn't among them (first launch, dismissed, reinstall) it starts one. The first time,
the Lock Screen asks Allow / Don't Allow — tap Allow. `SERVER_URL` in `ios/project.yml` is where the
app reports (mine: `https://toggl.oreh.uk`, see Hosting); for a LAN-only setup use this Mac's
`.local` address, e.g. `http://<mac>.local:8790`.

## Two ways to watch Toggl

Both read `/me/time_entries/current` (`server/lib/toggl.ts`); they differ in _when_.

### Polling — `server/toggl-poll.ts` (start here)

Nothing has to be public. Changes appear within `TOGGL_POLL_SECONDS` (default 150 s, ~24 req/h).
Toggl's docs say `/me` endpoints get 30 requests/hour, but the real quota can be higher — check
`GET /api/v9/me/quota` (the `organization_id: null` entry). With 240/h (Starter) use 20.
When the quota runs out the server pauses until it resets.

    cd server && npm start

### Webhooks — `server/toggl-webhook.ts` (instant)

Toggl calls the server on every time-entry change. Needs a public HTTPS URL.

1. Pick a random secret and get your workspace id.
2. Expose **only** port 8788 (it serves just the signed `POST /toggl`). With a named Cloudflare
   Tunnel: dashboard → Networking → Tunnels → your tunnel → Routes → Add route → Published
   application, Service URL `http://localhost:8788` (mine: `https://toggl-hook.oreh.uk`). Keep it one
   subdomain level deep, or the free certificate won't cover it. Quick alternatives: `tailscale funnel
8788` or `cloudflared tunnel --url http://localhost:8788` (URL changes each run).
   Port 8790 holds push tokens in `/state` — expose it only with `APP_SECRET` set (see Hosting).
3. Set `TOGGL_WEBHOOK_SECRET=<secret>` in `server/.env` (webhook mode exits without it), run
   `npm run start:webhook` in `server/`. Check the public URL reaches this server and not something
   else on that port: `curl -X POST -d '{}' https://<public-host>/toggl` must answer `400` (bad signature).
4. Subscribe (the server answers Toggl's validation ping itself):

       curl -u $TOGGL_API_TOKEN:api_token -H 'Content-Type: application/json' \
         -d '{"url_callback":"https://<public-host>/toggl","event_filters":[{"entity":"time_entry","action":"*"}],"enabled":true,"description":"LockActivity","secret":"<secret>"}' \
         https://api.track.toggl.com/webhooks/api/v1/subscriptions/<workspace_id>

   The reply should have `validated_at` set. `GET` the same URL lists subscriptions; the workspace id
   is in `GET /api/v9/me/workspaces`.

### Which one?

|                   | Polling, 20 s (240/h quota)      | Webhooks                                                    |
| ----------------- | -------------------------------- | ----------------------------------------------------------- |
| Worst-case delay  | 20 s                             | ~1 s                                                        |
| Requests to Toggl | ~180/h, ~4,300/day               | 1 `GET` per change + fallback poll: ~150/day (~95% fewer)   |
| Public surface    | none                             | `:8788` via a tunnel + a Toggl subscription to keep enabled |
| Missed events     | impossible; next poll catches up | fixed by the fallback poll within 15 min                    |

Polling at 20 s is plenty for a glanceable timer, and 180 req/h is inside the quota Toggl grants, so
load on Toggl is no real argument either way. Pick webhooks if you already have a tunnel and want to be
a light API user. Webhook mode also polls every `TOGGL_FALLBACK_POLL_MINUTES` (default 15,
~4 req/h), since Toggl disables a subscription after repeated failed deliveries. Middle ground:
`TOGGL_POLL_SECONDS=60` (60/h, ≤1 min delay, nothing public).

## How the server works

| File                                              | Role                                                                                      |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `server/main.ts`                                  | entry: plain activity, no Toggl                                                           |
| `server/toggl-poll.ts`, `server/toggl-webhook.ts` | entries: mirror Toggl, by polling or webhooks                                             |
| `server/lib/activity.ts`                          | `show(display)` sets what should be on screen; `reconcile()` is the only code that pushes |
| `server/lib/apns.ts`                              | APNs JWT + send a push                                                                    |
| `server/lib/http.ts`                              | tiny JSON router + app routes on :8790                                                    |
| `server/lib/state.ts`                             | state + atomic save to `server/state.json`                                                |
| `server/lib/toggl.ts`                             | reads the current Toggl entry (+ project name) and calls `show()`                         |
| `server/test.ts`                                  | end-to-end test                                                                           |

`reconcile()` runs one at a time (Toggl syncs, a 1-minute tick and the routes share a queue) and:

- **starts** an activity (push-to-start) when the app's launch report (`POST /activities`) says the
  server's activity is gone — exactly once per report, retried if APNs fails — or when the current
  one nears iOS's 8h limit (re-created at 7.5h);
- **updates** it when the display changed; an update counts only once APNs returns 200, so a failed
  push is retried on the next sync or tick;
- **starts over** when APNs says the activity token is dead (410 / `Unregistered`);
- retries a start whose activity the phone never reported (e.g. it was off the server's network)
  after an hour, so it doesn't keep re-alerting.

State lives in `server/state.json` (written atomically). Manual routes for poking at it:

    curl localhost:8790/state                                   # tokens, activity, current display
    curl -XPOST localhost:8790/start                            # re-create the activity now
    curl -XPOST localhost:8790/message -d '{"message":"hi"}'    # change the text (no-Toggl mode)

With `APP_SECRET` set, add `-H "Authorization: Bearer $APP_SECRET"` to each.

Running `node --env-file=server/.env server/main.ts` alone (no Toggl) keeps a plain activity
showing that message.

Known gap: if you swipe the activity away (or reinstall the app), APNs may keep accepting updates for
it, so the server can't tell while the app stays closed; it comes back when you next open the app
(launch report) or at the next 7.5h restart.

### Test

    node server/test.ts   # real server vs fake Toggl + fake APNs, ~2 s; doesn't touch state.json

Dev tooling, in `server/` after `npm install` once (dev dependencies only — Prettier, TypeScript,
`@types/node`; running the server needs none of them):

    npm run typecheck      # tsc, strict, no emit
    npm test
    npm run format         # or format:check; server code only

Swift (`ios/`) uses Apple's `swift-format` from the Xcode toolchain with its defaults (2 spaces,
100 columns; `ios/project.yml` sets Xcode's indent to match):

    xcrun swift-format format --in-place --recursive ios/App ios/Widget ios/Shared
    xcrun swift-format lint --strict --recursive ios/App ios/Widget ios/Shared

### Hosting

Needs an always-on process (restart tick, state file) and HTTP/2 to APNs, so serverless
(Workers, Vercel) doesn't fit. Mac (stops when asleep), Raspberry Pi or a small VPS all work.

- Server → APNs needs no certificate of yours; the `.p8` key authenticates it. `APNS_HOST` must match
  the build: sandbox (default) for Xcode builds, `api.push.apple.com` for TestFlight/App Store.
- iPhone → server: ATS only allows plain `http://` to `.local` names and IP addresses, so
  `http://<mac>.local:8790` (same Wi-Fi) or `http://<tailscale-ip>:8790` (Tailscale on the phone,
  VPN On Demand so token reports never miss) work; a full domain needs HTTPS.
- Outside the LAN without a VPN: a Cloudflare Tunnel hostname (e.g. `https://toggl.oreh.uk` →
  `http://localhost:8790`) gives HTTPS; set `APP_SECRET` first, since the routes are otherwise open.
  Only the app's reports need this path — pushes reach the phone through APNs on any network.
- Docker: `cd server && docker compose up -d` reads `server/.env`, mounts the key from
  `APNS_KEY_PATH` and keeps the state in a volume (not `server/state.json`, so the phone's tokens
  are re-sent on the next app launch). It runs webhook mode: route a second tunnel hostname to
  `http://localhost:8788` for Toggl. For polling instead see the comment in `server/compose.yaml`.

## Possible next steps

- **Body size limit** (a few lines in `serve()`): reject bodies over ~64 KB — mostly matters for the
  public webhook port. (Input checks are done: `str()` in `server/lib/http.ts`.)
- **Fastify** instead of the hand-rolled router: schema validation, body limits and logging for free,
  but adds a runtime dependency to a server that has none, and the webhook needs a custom
  content-type parser to keep the raw body for the signature check. Worth it once there are more routes.
- **Detect a swiped-away activity**: the app could report `activityStateUpdates` (`.dismissed`/`.ended`)
  so the server re-creates it without waiting for the next app launch — only while iOS lets the app
  run, so not guaranteed.

## Compared with other apps

Timer changed in the **desktop browser**, iPhone locked, app closed. Tested by hand on an iPhone 17
unless noted; "—" means not tested.

| Case                                  | Toggl Lock (this repo)                              | Toggl Track iOS app (Oct 2026)  | Toggl Lockscreen Widget / Timery |
| ------------------------------------- | --------------------------------------------------- | ------------------------------- | -------------------------------- |
| Start a timer                         | ✅ within one poll (~20 s) or instant (webhook)     | ✅ activity appears             | ❌ not updated                   |
| Stop the timer                        | ✅ shows "No running timer"                         | ❌ keeps counting the old timer | ❌ not updated                   |
| Start a different timer               | ✅ updates in place, no Allow prompt                | ❌ still shows the old one      | ❌ not updated                   |
| Edit description / project            | ✅ updates (`server/test.ts`)                       | —                               | —                                |
| Nothing running                       | ✅ "No running timer", stays visible                | ❌ stale old timer stays        | —                                |
| Timer longer than 8 h (iOS limit)     | ✅ re-created at 7.5 h (by design, not hand-tested) | —                               | —                                |
| Needs your own server + Apple account | yes                                                 | no                              | no                               |

So Toggl's app now push-starts its activity from the server side, but doesn't follow later changes;
keeping the Lock Screen in sync with timers changed elsewhere is what this project adds.

## Research

### Why a server at all

- iOS suspends apps ~30 s after backgrounding; no long-lived connection or on-device polling.
  Background App Refresh runs when iOS decides (often hours apart).
- The Live Activity view can't do networking, and `Activity.request` only works with the app in the
  foreground. Starting one from the background is only possible via APNs push-to-start.
- Toggl Track's own iOS app used to show a Live Activity only after the app was opened
  ([community thread](https://community.toggl.com/t/dynamic-island-only-shows-timer-when-started-from-ios-app/1303));
  by Oct 2026 it push-starts one, but doesn't follow stops or new timers (table above).
- [Toggl Lockscreen Widget](https://apps.apple.com/ca/app/toggl-lockscreen-widget/id6756894639) and
  [Timery](https://apps.apple.com/app/id1425368544): neither updates its Live Activity when the timer is
  changed in the desktop browser.
- The [Toggl Focus API](https://engineering.toggl.com/docs/focus/) (the other Toggl product) has a
  `tracking/current` endpoint but no webhooks; Toggl Track has
  [webhooks](https://engineering.toggl.com/docs/track/webhooks_start/).

### Apple Watch

The activity shows up in the watch's Smart Stack on its own: by default watchOS draws the compact
Dynamic Island views, and `.supplementalActivityFamilies([.small])` in `LockWidget.swift` gives it its own
layout (icon, project, timer; needs iOS 18).

The small icon for the Live Activity at the top of the watch face stays **blank** (default empty
circle). Tried, Oct 2026, iPhone 17 + Apple Watch Series 7:

- The iPhone app icon is fine (1024 px, no alpha), so a broken icon isn't the cause.
- `.small` layout: fixes the Smart Stack card, not the watch-face icon.
- An icon-only watchOS app (single-target, embedded in the iPhone app, no networking): the icon
  showed up in the watch's app list but **not** for the Live Activity, even after restarting the
  watch and re-creating the activity. Removed again.
  Side note: installing it needed Developer Mode on the watch and a build straight to the watch,
  so the watch got added to the team's provisioning profile. Without that, Install in the iPhone's
  Watch app fails silently.
- Apple doesn't document which image that icon uses
  ([Apple Support](https://support.apple.com/guide/watch/bz1vx4mwqbw9/watchos),
  [WWDC24 session 10098](https://developer.apple.com/videos/play/wwdc2024/10098/)).

### APNs limits

- Priority-10 Live Activity pushes draw from an hourly budget Apple doesn't publish. Past it,
  updates are throttled even though APNs still returns 200. `NSSupportsLiveActivitiesFrequentUpdates`
  (set in `ios/project.yml`) raises the budget, and the user can turn it off in Settings.
- An activity lives at most 8 h, then stays on the Lock Screen up to 4 h as ended. The server
  re-creates it at 7.5 h.
- Provider JWT: refresh at most every 20 min (else `429 TooManyProviderTokenUpdates`) and at
  least hourly. `server/lib/apns.ts` reuses it for 50 min.
- Apple prefers one long-lived HTTP/2 connection. `apns.ts` opens one per push, which is fine at
  a few pushes per timer change.
- Payload ≤ 4 KB. Sandbox tokens only work with `api.sandbox.push.apple.com`.
