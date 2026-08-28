# Running nitter on Heroku

Nitter runs on Heroku's container stack as a single web dyno, backed by
Heroku Key-Value Store (the current name for Heroku Data for Redis) for cache
persistence. Heroku builds the image remotely from your pushed git ref, so you
do not need Docker locally.

## Why there is an stunnel in the dyno

Every Heroku Key-Value Store plan [requires TLS][tls] and hands you a
`rediss://` URL backed by a self-signed certificate. Nitter reaches Redis
through `redpool` → `nim-lang/redis`, whose only entry point is
`openAsync(host, port)` over a bare `newAsyncSocket` - there is no TLS support
and no config option to add it.

Rather than fork both dependencies, the image ships `stunnel`.
`docker-entrypoint.sh` parses `REDIS_URL`, points stunnel at the real host over
TLS, and has it listen on `127.0.0.1:6379`. Nitter is configured with
`redisHost = "127.0.0.1"` and connects in plaintext, unaware of any of this.

```
nitter ──plaintext──▶ 127.0.0.1:6379 (stunnel) ──TLS──▶ rediss://…:17749
```

If `REDIS_URL` uses the plaintext `redis://` scheme instead, the entrypoint
skips stunnel and points nitter straight at the host.

## Setup

```sh
heroku create your-nitter-app
heroku stack:set container -a your-nitter-app
heroku addons:create heroku-redis:mini -a your-nitter-app
```

`heroku-redis:mini` is the cheapest paid tier. Note its two limits, both of
which the entrypoint already accounts for: **25 MB** of storage and **20
concurrent connections**. Nitter's stock `redisConnections = 20` /
`redisMaxConnections = 30` would exhaust the connection cap on its own, so the
entrypoint defaults them to 4 and 8.

The default `volatile-lru` eviction policy is the right one — nitter sets a TTL
on every key it writes, so the cache degrades gracefully when full. Confirm it
with `heroku redis:info -a your-nitter-app`, and if it reads `noeviction`:

```sh
heroku redis:maxmemory your-nitter-app --policy volatile-lru
```

## Config vars

`REDIS_URL` and `PORT` are set by Heroku. You must set these two:

```sh
heroku config:set -a your-nitter-app \
  NITTER_HOSTNAME="your-nitter-app.herokuapp.com" \
  NITTER_HMAC_KEY="$(openssl rand -hex 32)"

heroku config:set -a your-nitter-app \
  NITTER_SESSIONS_B64="$(base64 -w0 sessions.jsonl)"
```

`NITTER_HMAC_KEY` signs media URLs; the entrypoint refuses to boot without it,
or with the example value `secretkey`, rather than come up forgeable. Keep it
stable — changing it invalidates every media URL already in the cache.

`NITTER_SESSIONS_B64` is your `sessions.jsonl`, base64-encoded because the file
is multi-line. Generate it with the scripts in `tools/` first; nitter cannot
serve anything without account sessions. It is a credential — it lives only in
config vars, never in the image, and `sessions.jsonl` stays gitignored.

Everything else is optional and falls back to the `nitter.example.conf` values.
The full list is in `docker-entrypoint.sh`; the ones most worth knowing:

| Config var | Default | Notes |
|---|---|---|
| `NITTER_HOSTNAME` | `$HEROKU_APP_NAME.herokuapp.com` | Used for generated links and `replaceTwitter` |
| `NITTER_TITLE` | `nitter` | |
| `NITTER_HTTPS` | `true` | Correct on Heroku — the router terminates TLS, but public URLs are https |
| `NITTER_REDIS_CONNECTIONS` | `4` | Raise only if your plan allows more than 20 connections |
| `NITTER_REDIS_MAX_CONNECTIONS` | `8` | Must stay under the plan's connection cap |
| `NITTER_STATIC_DIR` | `./public` | Widened to world-readable at boot; see Jester note below |
| `NITTER_ENABLE_DEBUG` | `false` | Turning this on exposes `/.sessions` |
| `NITTER_THEME` | `Nitter` | |

## Deploy

```sh
heroku git:remote -a your-nitter-app
```

Then push the branch to the `heroku` remote — that push is the deploy. Watch it
come up with:

```sh
heroku logs --tail -a your-nitter-app
```

A healthy boot logs `Starting Nitter at …`, the stunnel banner, and
`Connected to Redis at 127.0.0.1:6379`.

## Notes and known limitations

**Build time.** The image compiles nitter with `-d:danger -d:lto`, which is
slow. If you hit Heroku's build timeout, drop `-d:lto` from the `nimble build`
line in the `Dockerfile`; it costs some runtime performance and nothing else.

**`CONFIG` is blocked.** Heroku Key-Value Store [refuses the `CONFIG`
command][tls], which nitter calls at startup to tune
`hash-max-ziplist-entries`. That raised a `ReplyError` past the `except
OSError` handler in `src/redis_cache.nim` and killed the process, so the call
is now wrapped and treated as best-effort. You will see `Redis refused CONFIG
SET, continuing without it.` in the logs — that is expected, and only means
user-ID buckets use slightly more memory.

**Static assets and Jester's permission check.** Heroku does not run the
container as the `USER` in the `Dockerfile`. It chowns the image to an
arbitrary UID and applies a `0077` umask, which leaves `public/` at `600`
files and `700` directories:

```
uid=12488(u12488) gid=12488(dyno)   umask 0077
drwx------  /src/public
-rw-------  /src/public/css/style.css
```

Nitter can still read those files, but Jester 0.6.0 refuses to serve any
static file that is not world-readable (`jester.nim:188` returns `Http403`
when `fpOthersRead` is missing). The result is a site that returns 200 for
every page while every stylesheet, script and icon returns 403 — it renders
completely unstyled. The entrypoint runs `chmod -R a+rX` over the static
directory at boot to undo this; the dyno user owns the files, so it is allowed
to. Capital `X` adds the traversal bit to directories without making regular
files executable.

Set `NITTER_STATIC_DIR` if you move the static directory; it feeds both the
`chmod` and the rendered `staticDir`.

**stunnel is not supervised.** It is started as a daemon before nitter execs.
If stunnel dies, nitter stays up but loses Redis, and Heroku will not restart
the dyno because the web process is still alive. This has not been a problem in
practice — stunnel is long-lived and reconnects upstream per connection — but if
you see cache errors with a healthy dyno, restart it with `heroku restart`.

**Eco dynos sleep.** After 30 minutes idle an Eco dyno sleeps, and the next
request pays a cold start while nitter re-parses sessions and reopens the Redis
pool. Basic dynos or above do not sleep.

**The filesystem is ephemeral.** Nothing outside Redis survives a dyno restart,
which is fine — nitter keeps no other state. `nitter.conf`, `sessions.jsonl`,
and `stunnel.conf` are all re-rendered into `/tmp` on every boot.

## Local testing

The entrypoint no-ops when `REDIS_URL` is unset, so `compose.yml` and the
plain Docker instructions in `README.md` are unaffected.

To exercise the rendering logic:

```sh
sh tests/test_entrypoint.sh
```

To test the whole image against a TLS Redis without deploying, run a local
Redis behind stunnel in server mode and pass its `rediss://` URL as
`REDIS_URL`.

[tls]: https://devcenter.heroku.com/articles/connecting-heroku-redis
