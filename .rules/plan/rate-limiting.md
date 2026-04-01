# Rate Limiting — Implementation Plan

Cross-process, per-account rate limiting for the Copilot adapter. All processes sharing the same GitHub account (same `token_path` directory) share a single rate limit state via the filesystem.

---

## Overview

Two rate limiting mechanisms, both enforced transparently (the adapter sleeps until allowed, never raises):

1. **Per-request cooldown** — Minimum interval between consecutive requests. Default: 3 seconds.
2. **Sliding window limit** — Maximum N requests within a time period. Default: disabled (`nil`).

Both are configured via constructor parameters. Rate limit state is stored in a file next to the persisted GitHub token, using `flock` for cross-process atomic access.

---

## Configuration

### Constructor Parameters

```ruby
Copilot.new(
  model: "gpt-4.1",
  github_token: nil,
  token_path: nil,
  max_tokens: 8192,
  thinking: nil,
  min_request_interval: 3.0,          # seconds between requests (Float/Integer, nil to disable)
  rate_limit: nil                      # sliding window config (Hash or nil to disable)
)
```

#### `min_request_interval:` (default: `3.0`)

- Minimum number of seconds that must elapse between the start of one request and the start of the next.
- Set to `nil` or `0` to disable.
- Applies system-wide across all processes sharing the same rate limit file.

#### `rate_limit:` (default: `nil` — disabled)

- A Hash with two keys: `{ requests: Integer, period: Integer }`.
  - `requests` — Maximum number of requests allowed within the window.
  - `period` — Window size in seconds.
- Example: `{ requests: 10, period: 60 }` means at most 10 requests per 60-second sliding window.
- Set to `nil` to disable sliding window limiting (only per-request cooldown applies).
- Validation: both `requests` and `period` must be positive integers when provided. Raises `ArgumentError` otherwise.

---

## Behaviour

When `chat` or `list_models` is called (any method that hits the Copilot API):

1. **Acquire the rate limit file lock** (`flock(File::LOCK_EX)`).
2. **Read the rate limit state** from the file.
3. **Check per-request cooldown**: If less than `min_request_interval` seconds have elapsed since the last request timestamp, calculate the remaining wait time.
4. **Check sliding window** (if configured): Count how many timestamps in the log fall within `[now - period, now]`. If the count >= `requests`, calculate the wait time until the oldest entry in the window expires.
5. **Take the maximum** of both wait times (they can overlap).
6. **Release the lock**, then **sleep** for the calculated wait time (if any).
7. **Re-acquire the lock**, re-read state, re-check (the state may have changed while sleeping — another process may have made a request during our sleep).
8. **Record the current timestamp** in the state file and release the lock.
9. **Proceed** with the API request.

The re-check-after-sleep loop is necessary because another process could slip in a request while we were sleeping. The loop converges quickly (at most a few iterations) because each process sleeps for the correct duration.

### Thread Safety

The existing `@mutex` protects the Copilot token refresh. Rate limiting uses a separate concern:

- **Cross-process**: `flock` on the rate limit file.
- **In-process threads**: The `flock` call itself is sufficient — Ruby's `File#flock` blocks the calling thread (does not hold the GVL while waiting), so concurrent threads in the same process will serialize correctly through the flock.

---

## File Format

### Path

```
{token_path_directory}/copilot_rate_limit
```

Where `token_path_directory` is `File.dirname(@token_path)`. Since `@token_path` defaults to `~/.config/dispatch/copilot_github_token`, the rate limit file defaults to `~/.config/dispatch/copilot_rate_limit`.

### Contents

JSON with two fields:

```json
{
  "last_request_at": 1743465600.123,
  "request_log": [1743465590.0, 1743465595.0, 1743465600.123]
}
```

- `last_request_at` — Unix timestamp (Float) of the most recent request. Used for per-request cooldown.
- `request_log` — Array of Unix timestamps (Float) for recent requests. Used for sliding window. Entries older than the window `period` are pruned on every write to keep the file small.

If sliding window is disabled, `request_log` is still maintained (empty array) so that enabling it later works immediately without losing the last-request timestamp.

When the file does not exist or is empty/corrupt, treat it as fresh state (no previous requests).

### File Permissions

Created with `0600` (same as the token file) to prevent other users from reading/tampering.

---

## Implementation Structure

### New File: `lib/dispatch/adapter/rate_limiter.rb`

A standalone class `Dispatch::Adapter::RateLimiter` that encapsulates all rate limiting logic. The Copilot adapter delegates to it.

```ruby
class RateLimiter
  def initialize(rate_limit_path:, min_request_interval:, rate_limit:)
    # ...
  end

  def wait!
    # Acquire lock, read state, compute wait, sleep, record, release.
  end
end
```

#### Public API

- `#wait!` — Blocks until the rate limit allows a request, then records the request timestamp. Called by the adapter before every API call.

#### Private Methods

- `#read_state(file)` — Parse JSON from the locked file. Returns default state on missing/corrupt file.
- `#write_state(file, state)` — Write JSON state back to the file.
- `#compute_wait(state, now)` — Returns the number of seconds to sleep (Float, 0.0 if no wait needed).
- `#prune_log(log, now, period)` — Remove timestamps older than `now - period`.
- `#record_request(state, now)` — Append `now` to log, update `last_request_at`, prune old entries.

### Changes to `Dispatch::Adapter::Copilot`

1. Add constructor parameters `min_request_interval:` and `rate_limit:`.
2. In `initialize`, create a `RateLimiter` instance.
3. Call `@rate_limiter.wait!` at the start of `chat_non_streaming`, `chat_streaming`, and `list_models` — after `ensure_authenticated!` (authentication should not be rate-limited) but before the HTTP request.
4. Validate `rate_limit:` hash structure in the constructor.

### Changes to `Dispatch::Adapter::Base`

No changes. Rate limiting is an implementation concern of the Copilot adapter, not part of the abstract interface. Other adapters may have different rate limiting strategies or none at all.

---

## Edge Cases

| Scenario | Behaviour |
|---|---|
| Rate limit file does not exist | Treat as no previous requests. Create on first write. |
| Rate limit file contains invalid JSON | Treat as no previous requests. Overwrite on next write. |
| Rate limit file directory does not exist | Create it (same as `persist_token` does for the token file). |
| `min_request_interval: nil` or `0` | Per-request cooldown disabled. |
| `rate_limit: nil` | Sliding window disabled. Only cooldown applies. |
| Both disabled | `wait!` is a no-op (returns immediately). |
| `rate_limit:` missing `requests` or `period` key | Raises `ArgumentError` in constructor. |
| `rate_limit: { requests: 0, ... }` or negative | Raises `ArgumentError` in constructor. |
| Clock skew between processes | Handled — we use monotonic-ish `Time.now.to_f`. Minor skew (sub-second) is acceptable. Major skew (NTP jump) could cause one extra wait or one early request, which is acceptable. |
| Process killed while holding lock | `flock` is automatically released by the OS when the file descriptor is closed (including process termination). No stale locks. |
| Very long `request_log` after sustained use | Pruned on every write. Maximum size = `rate_limit[:requests]` entries. |

---

## Validation Rules

In the constructor:

- `min_request_interval` must be `nil`, or a `Numeric` >= 0. Raise `ArgumentError` otherwise.
- `rate_limit` must be `nil` or a `Hash` with:
  - `:requests` — positive `Integer`
  - `:period` — positive `Integer` or `Float`
  - No extra keys required; extra keys are ignored.
- Raise `ArgumentError` with a descriptive message on invalid config.
