"""Origin lock tests: nitter must reject requests that did not arrive through
the trusted reverse proxy.

Requires a running instance started with a non-empty `originKey`, and the same
value exported as NITTER_ORIGIN_KEY. Skipped otherwise, since a stock instance
has the check disabled.

    NITTER_ORIGIN_KEY=testkey pytest tests/test_origin_lock.py
"""
import os
import subprocess

import pytest
from parameterized import parameterized

BASE_URL = 'http://localhost:8080'
HEADER = 'X-Nitter-Origin-Key'
KEY = os.environ.get('NITTER_ORIGIN_KEY', '')

pytestmark = pytest.mark.skipif(
    not KEY, reason='set NITTER_ORIGIN_KEY to the instance\'s originKey')


def curl_status(path, key=None):
    """Status code for path, optionally presenting an origin key header."""
    cmd = ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}']
    if key is not None:
        cmd += ['-H', f'{HEADER}: {key}']
    cmd.append(f'{BASE_URL}{path}')
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return int(result.stdout)


# A page, a static asset and the media proxy. The asset is the important one:
# Jester serves static files from a separate code path that only runs when no
# route matched, so a check placed anywhere below a `cond` would leave every
# stylesheet and script reachable without the key.
PATHS = ['/', '/about', '/css/style.css', '/js/infiniteScroll.js']


class TestOriginLock:
    @parameterized.expand([(p,) for p in PATHS])
    def test_no_header_is_forbidden(self, path):
        assert curl_status(path) == 403, f'{path} reachable without the key'

    @parameterized.expand([(p,) for p in PATHS])
    def test_wrong_key_is_forbidden(self, path):
        assert curl_status(path, KEY + 'x') == 403, \
            f'{path} reachable with a wrong key'

    def test_empty_header_is_forbidden(self):
        assert curl_status('/', '') == 403

    @parameterized.expand([(p,) for p in PATHS])
    def test_correct_key_passes(self, path):
        assert curl_status(path, KEY) == 200, \
            f'{path} rejected despite a correct key'

    def test_malformed_path_is_forbidden_before_it_is_malformed(self):
        """The lock runs above the malformed-path check, so an unauthorised
        caller gets a uniform 403 and cannot probe routing behaviour."""
        assert curl_status('//lefty_rae') == 403
        assert curl_status('//lefty_rae', KEY) == 400
