#!/bin/sh
# Tests docker-entrypoint.sh config rendering. Run: sh tests/test_entrypoint.sh
set -u

ENTRYPOINT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/docker-entrypoint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# Runs the entrypoint in dry-run mode with a clean env. Args are VAR=value pairs.
run() {
  env -i \
    PATH="$PATH" \
    NITTER_ENTRYPOINT_DRY_RUN=1 \
    NITTER_CONF_FILE="$WORK/nitter.conf" \
    NITTER_SESSIONS_FILE="$WORK/sessions.jsonl" \
    STUNNEL_CONF="$WORK/stunnel.conf" \
    "$@" \
    sh "$ENTRYPOINT" /bin/true >"$WORK/stdout" 2>"$WORK/stderr"
}

check() {
  desc="$1"; file="$2"; needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc"
    echo "  expected to find: $needle"
    echo "  in $file:"
    sed 's/^/    /' "$file" 2>/dev/null | head -40
  fi
}

check_not() {
  desc="$1"; file="$2"; needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    fail=$((fail + 1))
    echo "FAIL: $desc"
    echo "  did not expect to find: $needle"
  else
    pass=$((pass + 1))
  fi
}

check_status() {
  desc="$1"; expected="$2"; actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc (expected exit $expected, got $actual)"
    sed 's/^/    /' "$WORK/stderr" | head -10
  fi
}

SESSIONS_B64="$(printf '{"oauth_token":"abc","oauth_token_secret":"def"}\n' | base64 | tr -d '\n')"

BASE_ENV_HMAC="NITTER_HMAC_KEY=0123456789abcdef"

echo "== a Heroku rediss:// URL routes nitter through stunnel =="
run REDIS_URL="rediss://:p4ssw0rd@ec2-1-2-3-4.compute-1.amazonaws.com:17749" \
    $BASE_ENV_HMAC \
    NITTER_SESSIONS_B64="$SESSIONS_B64" \
    HEROKU_APP_NAME=my-nitter \
    PORT=41234
check_status "rediss run succeeds" 0 $?
check "nitter points at loopback"     "$WORK/nitter.conf"  'redisHost = "127.0.0.1"'
check "nitter uses the local port"    "$WORK/nitter.conf"  'redisPort = 6379'
check "password extracted from URL"   "$WORK/nitter.conf"  'redisPassword = "p4ssw0rd"'
check "binds Heroku's assigned PORT"  "$WORK/nitter.conf"  'port = 41234'
check "hostname from HEROKU_APP_NAME" "$WORK/nitter.conf"  'hostname = "my-nitter.herokuapp.com"'
check "https on for herokuapp.com"    "$WORK/nitter.conf"  'https = true'
check "conn pool under Mini's cap"    "$WORK/nitter.conf"  'redisConnections = 4'
check "max conns under Mini's cap"    "$WORK/nitter.conf"  'redisMaxConnections = 8'
check_not "real redis host not used"  "$WORK/nitter.conf"  'amazonaws.com'
check "stunnel connects upstream"     "$WORK/stunnel.conf" 'connect = ec2-1-2-3-4.compute-1.amazonaws.com:17749'
check "stunnel accepts on loopback"   "$WORK/stunnel.conf" 'accept = 127.0.0.1:6379'
check "stunnel is a TLS client"       "$WORK/stunnel.conf" 'client = yes'
check "self-signed cert accepted"     "$WORK/stunnel.conf" 'verifyChain = no'
check "sessions decoded"              "$WORK/sessions.jsonl" 'oauth_token'

echo "== a plaintext redis:// URL skips stunnel entirely =="
rm -f "$WORK/stunnel.conf"
run REDIS_URL="redis://localhost:6380" \
    $BASE_ENV_HMAC \
    NITTER_SESSIONS_B64="$SESSIONS_B64" \
    NITTER_HOSTNAME=nitter.example.org
check_status "redis:// run succeeds" 0 $?
check "connects directly to the host" "$WORK/nitter.conf" 'redisHost = "localhost"'
check "keeps the upstream port"       "$WORK/nitter.conf" 'redisPort = 6380'
check "no password when URL has none" "$WORK/nitter.conf" 'redisPassword = ""'
check "explicit hostname wins"        "$WORK/nitter.conf" 'hostname = "nitter.example.org"'
if [ -f "$WORK/stunnel.conf" ]; then
  fail=$((fail + 1)); echo "FAIL: stunnel.conf written for a plaintext URL"
else
  pass=$((pass + 1))
fi

echo "== an '@' inside the password still parses =="
run REDIS_URL="rediss://:p@ss@word@host.example.com:6380" \
    $BASE_ENV_HMAC \
    NITTER_SESSIONS_B64="$SESSIONS_B64"
check_status "'@' password run succeeds" 0 $?
check "password keeps its @"    "$WORK/nitter.conf"  'redisPassword = "p@ss@word"'
check "host is after the last @" "$WORK/stunnel.conf" 'connect = host.example.com:6380'

echo "== a username in the URL is ignored, only the password is sent =="
run REDIS_URL="rediss://someuser:secret@host.example.com:6380" \
    $BASE_ENV_HMAC \
    NITTER_SESSIONS_B64="$SESSIONS_B64"
check_status "user:pass run succeeds" 0 $?
check "password without the username" "$WORK/nitter.conf" 'redisPassword = "secret"'

echo "== misconfiguration fails loudly instead of booting insecure =="
run REDIS_URL="rediss://:pw@host:6380" NITTER_SESSIONS_B64="$SESSIONS_B64"
check_status "missing hmacKey exits 1" 1 $?
check "hmacKey error names the var" "$WORK/stderr" 'NITTER_HMAC_KEY'

run REDIS_URL="rediss://:pw@host:6380" NITTER_HMAC_KEY=secretkey \
    NITTER_SESSIONS_B64="$SESSIONS_B64"
check_status "default hmacKey exits 1" 1 $?

run REDIS_URL="rediss://:pw@host:6380" $BASE_ENV_HMAC
check_status "missing sessions exits 1" 1 $?
check "sessions error names the var" "$WORK/stderr" 'NITTER_SESSIONS_B64'

run REDIS_URL="http://host:6380" $BASE_ENV_HMAC NITTER_SESSIONS_B64="$SESSIONS_B64"
check_status "bad scheme exits 1" 1 $?

echo "== no REDIS_URL means the compose path is untouched =="
rm -f "$WORK/nitter.conf"
env -i PATH="$PATH" NITTER_CONF_FILE="$WORK/nitter.conf" sh "$ENTRYPOINT" /bin/true
check_status "exec passthrough succeeds" 0 $?
if [ -f "$WORK/nitter.conf" ]; then
  fail=$((fail + 1)); echo "FAIL: rendered a config without REDIS_URL"
else
  pass=$((pass + 1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
