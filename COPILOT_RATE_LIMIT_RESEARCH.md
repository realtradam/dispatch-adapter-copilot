# GitHub Copilot Rate Limit / Quota Reset — Research Findings

How the official Copilot CLI, VS Code Copilot Chat, and the CodeCompanion Neovim
plugin retrieve and display rate-limit / quota reset information, and how to
replicate it in this adapter.

## TL;DR

The reset countdown comes from **two different places** depending on which
limit you hit:

1. **Proactive / "how much do I have left"** → `GET https://api.github.com/copilot_internal/user`
   returns structured remaining counts and an ISO reset date.
2. **Reactive / on a 429 from `chat/completions`** → either a `Retry-After`
   header (short-window throttles) or a **plain-text prose body** containing
   the reset time (weekly/monthly quota). There is **no structured reset
   timestamp on the 429 response itself** for monthly/weekly limits.

The official CLI and VS Code extension display the prose verbatim. CodeCompanion
proactively polls `/copilot_internal/user` for its quota UI.

---

## 1. Response headers on 429

When `https://api.githubcopilot.com/chat/completions` (or the
`*.business.githubcopilot.com` variant) returns 429, the response includes:

- **`retry-after`** — integer seconds (e.g. `retry-after: 60`).
  - Present for short-window throttles only.
  - **NOT** present for the weekly/monthly quota 429 — those are returned as
    `text/plain` and treated as terminal by the official clients.
- **`x-ratelimit-exceeded`** — identifies which limit tripped (e.g.
  `global-chat`).
- **`x-github-request-id`** — opaque, useful for support tickets.

The current adapter (`lib/dispatch/adapter/copilot.rb:414`) already reads
`Retry-After` for 429. That covers short-window throttles only.

## 2. Response body on 429

JSON body structure (from `vscode-copilot-release` issue threads and
Cline/CodeCompanion reports):

```json
{
  "error": {
    "message": "Sorry, you have exceeded your Copilot token usage. …",
    "code": "rate_limited"
  }
}
```

Known `error.code` values:

- **`rate_limited`** — short-window throttle.
- **`quota_exceeded`** — "You have no quota."

For weekly/monthly quota the body is often **`text/plain`** with literal text
such as:

- `"Sorry, you've hit a rate limit that restricts the number of Copilot model requests… Please try again in 2 hours."`
- `"You've reached your weekly rate limit. Please wait for your limit to reset on April 20, 2026 at 2:00 AM or switch to auto model to continue."`

**The reset time is embedded as prose in the message string** — there is no
structured reset timestamp on the 429 itself.

## 3. CodeCompanion (Neovim plugin)

`olimorris/codecompanion.nvim` does **almost nothing** with the 429 itself. In
`lua/codecompanion/adapters/http/copilot/init.lua` ~lines 288-293 it only
string-matches `"quota"` + `"exceeded"` in the response and returns:

> `"Your Copilot quota has been exceeded for this conversation"`

No header parsing, no countdown.

The reset-aware UI lives in
**`lua/codecompanion/adapters/http/copilot/stats.lua`**, which calls a
*separate* endpoint (see §6) **before** hitting the limit, not in response to
a 429.

## 4. Official Copilot CLI (`github/copilot-cli`)

The repository is a **closed-source binary** — only issues and discussions are
public. Observable behavior from issues #2828, #2336, #2742:

- It surfaces the prose message directly from the 429 plain-text body
  (e.g. *"Please wait for your limit to reset on April 20, 2026 at 2:00 AM"*).
- Parses internal `error.code` values like `rate_limited`, `quota_exceeded`.
- The "Resets in X hours" countdown the user sees comes from the **prose** in
  the API response — there is no documented header for it.

## 5. VS Code Copilot Chat (`microsoft/vscode-copilot-chat`)

- Reads `Retry-After` for status 429.
- Treats `text/plain` 429s (weekly quota) as terminal — no retries, just shows
  the message.
- Same prose-extraction pattern as the CLI.
- No header gives a structured reset timestamp.

## 6. Quota endpoint — `GET https://api.github.com/copilot_internal/user`

**This is the actual answer for showing a reset countdown proactively.**

Headers:

```
Authorization: Bearer <oauth_token>
Accept: */*
```

Note: this uses the **GitHub OAuth token**, not the short-lived Copilot bearer
token returned from `/copilot_internal/v2/token`.

Source: `codecompanion.nvim/lua/codecompanion/adapters/http/copilot/stats.lua`.

### Response fields

**Limited (Free) users**

- `access_type_sku`
- `monthly_quotas.chat`
- `monthly_quotas.completions`
- `limited_user_quotas.chat` (remaining)
- `limited_user_quotas.completions` (remaining)
- `limited_user_reset_date` (ISO `YYYY-MM-DD`)

**Premium (paid) users**

- `quota_snapshots.premium_interactions.entitlement`
- `quota_snapshots.premium_interactions.remaining`
- `quota_snapshots.premium_interactions.percent_remaining`
- `quota_snapshots.premium_interactions.unlimited`
- `quota_snapshots.premium_interactions.overage_permitted`
- `quota_snapshots.chat.{entitlement,remaining,unlimited}`
- `quota_snapshots.completions.{entitlement,remaining,unlimited}`
- `quota_reset_date` (ISO `YYYY-MM-DD`)

### CodeCompanion countdown logic

```lua
local y, m, d = reset_date:match("^(%d+)-(%d+)-(%d+)$")
local days_left = (os.time({year=tonumber(y), month=tonumber(m), day=tonumber(d)}) - os.time()) / 86400
```

### Reset semantics (from GitHub docs)

- **Pro / Pro+ premium counters** reset on the **1st of each month at 00:00 UTC**.
- **Free plan** resets on the user's billing date.

## 7. Token endpoint — `GET https://api.github.com/copilot_internal/v2/token`

Response fields actually consumed (per CodeCompanion `token.lua` `CopilotToken`
typedef):

```
token: string
expires_at: number       (unix seconds; this adapter uses it at copilot.rb:300)
chat_enabled: boolean
annotations_enabled: boolean
endpoints: { api, proxy, telemetry, "origin-tracker" }
```

**No `quota_reset_date` or `limited_user_quotas` here.** Quota info is only on
`/copilot_internal/user`.

---

## Recommendations for this adapter

1. Add a fetcher for `GET /copilot_internal/user` (with the **OAuth GitHub
   token**, not the Copilot bearer token) to get structured `quota_reset_date`
   / `limited_user_reset_date` and remaining counts. Cache the response.
2. In `handle_error_response!` (`lib/dispatch/adapter/copilot.rb:401`):
   - Read `Retry-After` (already done).
   - Parse `error.code` (`rate_limited` vs `quota_exceeded`).
   - Fall back to passing the plain-text body verbatim to the user — it
     contains the only authoritative reset prose for weekly/monthly limits.
   - On `quota_exceeded` or text-body 429, *also* fetch
     `/copilot_internal/user` to render a structured "resets in N days/hours"
     message.

---

## Sources

- [CodeCompanion Copilot adapter init.lua](https://github.com/olimorris/codecompanion.nvim/blob/main/lua/codecompanion/adapters/http/copilot/init.lua)
- [CodeCompanion stats.lua (quota fetcher)](https://github.com/olimorris/codecompanion.nvim/blob/main/lua/codecompanion/adapters/http/copilot/stats.lua)
- [CodeCompanion token.lua](https://github.com/olimorris/codecompanion.nvim/blob/main/lua/codecompanion/adapters/http/copilot/token.lua)
- [github/copilot-cli issue #2828 — Weekly rate limiting prose](https://github.com/github/copilot-cli/issues/2828)
- [github/copilot-cli issue #2336 — "Please try again in 2 hours"](https://github.com/github/copilot-cli/issues/2336)
- [github/copilot-cli issue #2742 — Persistent 429 on Pro+](https://github.com/github/copilot-cli/issues/2742)
- [vscode-copilot-release issue #6451 — exhausted model rate limit](https://github.com/microsoft/vscode-copilot-release/issues/6451)
- [GitHub Docs — Requests in GitHub Copilot (premium request reset semantics)](https://docs.github.com/en/copilot/concepts/billing/copilot-requests)
- [GitHub Docs — Monitoring Copilot usage and entitlements](https://docs.github.com/copilot/how-tos/monitoring-your-copilot-usage-and-entitlements)
- [ericc-ch/copilot-api (`/usage` endpoint mirrors `/copilot_internal/user`)](https://github.com/ericc-ch/copilot-api)
