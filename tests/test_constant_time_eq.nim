# SPDX-License-Identifier: AGPL-3.0-only
# Unit tests for the comparison behind the `originKey` origin lock.
import std/unittest
import ".."/src/utils

suite "constantTimeEq":
  const key = "cf-shared-secret"

  test "accepts an identical string":
    check constantTimeEq(key, key)
    check constantTimeEq("", "")

  test "rejects a difference in the last byte":
    # The whole point of the loop: it must not stop early, so a mismatch at
    # the very end has to be caught just like one at the start.
    check not constantTimeEq(key, "cf-shared-secreT")

  test "rejects a difference in the first byte":
    check not constantTimeEq(key, "Cf-shared-secret")

  test "rejects a length mismatch either way":
    check not constantTimeEq(key, key & "x")
    check not constantTimeEq(key & "x", key)
    check not constantTimeEq(key, "")
    check not constantTimeEq("", key)

  test "rejects a prefix, so a truncated key is not enough":
    check not constantTimeEq(key, "cf-shared")

  test "compares raw bytes, not text":
    # Header values arrive as arbitrary bytes; nothing here may normalise them.
    check not constantTimeEq("\xff\x00a", "\xff\x00b")
    check constantTimeEq("\xff\x00a", "\xff\x00a")
