## Gap analysis of the research (what was missing/unresolved)

1. **Claude Code `PermissionRequest` hook** — described only from Notchi's decompiled behavior, never verified against the official reference. RESOLVED (confirmed, with schema corrections).
2. **Codex CLI hooks** — the research's claim "Codex only emits 3 hook events (SessionStart/UserPromptSubmit/Stop)" is STALE. RESOLVED: Codex now ships ~10 hook events, and hooks are enabled by default.
3. **models.dev/api.json pricing schema** — used for the cost dashboard but shape undocumented. RESOLVED by fetching the live file.
4. **mediaremote-adapter viability on current macOS** — RESOLVED (still works; still the recommended path).
5. **OAuth usage endpoint** — corroborated, plus a critical missing requirement (User-Agent header) discovered.
6. **boring-notch doc truncated mid-sentence** — the FEATURES list cuts off at "AppleMusic and Spotify ("; the prose architecture sections above it are complete, so nothing blocking; recover the tail by reading TheBoredTeam/boring.notch on GitHub during implementation.
7. **No hard contradictions found** across the three docs. Remaining low-risk unverified items (from Notchi source only, verify empirically at build time): keychain service name "Claude Code-credentials", `codex://threads/<uuid>` deep link, `~/.codex/state_<N>.sqlite` / `logs_<N>.sqlite` table schemas, Notchi's `interrupt: false` field on deny (not in official docs — use the documented shape).

## Resolved: Claude Code hooks (code.claude.com/docs/en/hooks)

**`PermissionRequest` exists and is official.** Full current event list (29 events — far more than Notchi registers): SessionStart, Setup, UserPromptSubmit, UserPromptExpansion, PreToolUse, PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, MessageDisplay, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, Stop, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, FileChanged, WorktreeCreate, WorktreeRemove, PreCompact, PostCompact, Elicitation, ElicitationResult.

**Common input fields (stdin JSON, all hooks):** `session_id`, `prompt_id` (UUID, v2.1.196+), `transcript_path`, `cwd`, `permission_mode` (`default`/`plan`/`acceptEdits`/`auto`/`dontAsk`/`bypassPermissions`), `hook_event_name`, `effort.level` (`low`…`max`), plus `agent_id`/`agent_type` in subagent contexts. Caveat: `transcript_path` may lag real-time — on Stop/SubagentStop read `last_assistant_message` from the payload instead of tailing.

**PermissionRequest input:** adds `tool_name`, `tool_input`, `tool_use_id`, and `permission_suggestions` — an array of `{behavior, description, rule}` objects (e.g. `{"behavior":"allow","rule":"Bash(npm install)"}`). Note: Notchi's research described suggestion entries carrying `destination: localSettings` — the current docs show the `{behavior, rule}` shape; passing the first "allow" suggestion through verbatim (Notchi's approach) remains correct either way. Matcher = tool name (`"Bash"`, `"Edit|Write"`).

**PermissionRequest decision output** (print to stdout):
```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{
  "behavior":"allow"|"deny",
  "updatedInput":{...},              // allow only — rewrite args
  "updatedPermissions":[{"behavior":"allow","rule":"Bash(npm *)"}]  // "don't ask again"
}}}
```
Deny adds a message; docs do NOT show Notchi's `interrupt` field — treat it as optional/legacy.

**PreToolUse output** uses different keys: `hookSpecificOutput: {hookEventName:"PreToolUse", permissionDecision: "allow"|"deny"|"ask"|"defer", permissionDecisionReason, updatedInput, additionalContext}`. This confirms the research's "PreToolUse variant uses permissionDecision keys" claim, and adds two values Notchi didn't use (`ask`, `defer`) plus `additionalContext`.

**Notification hook** (missing from the research entirely): matchers include `permission_prompt`, `idle_prompt`, `agent_needs_input`, `agent_completed`, `auth_success`, elicitation types — a simpler, officially-supported channel for "session needs attention" notification sounds than inferring from Stop/PermissionRequest. Matchers confirmed: SessionStart (`startup`/`resume`/`clear`/`compact`), SessionEnd (`clear`/`resume`/`logout`/`other`), PreCompact (`manual`/`auto` — matches Notchi), Stop (no matcher), SubagentStop (matcher = agent type).

## Resolved: Codex CLI hooks (developers.openai.com/codex/hooks → learn.chatgpt.com/docs/hooks)

**The research is out of date — this changes the clone architecture.** Current state:
- **Enabled by default.** `[features] hooks = false` disables; `codex_hooks` is a **deprecated alias** (Notchi's forced `codex_hooks = true` still works but is legacy).
- **Locations:** `~/.codex/hooks.json`, inline `[hooks]` in `~/.codex/config.toml`, plus repo-local `.codex/hooks.json` / `.codex/config.toml`. (Known bug: issue #17532 — hooks configured via repo-local config.toml don't fire in interactive sessions.)
- **Schema:** `{"description": ..., "hooks": {"EventName": [{"matcher": "<regex or omit>", "hooks": [{"type":"command", "command": ..., "commandWindows": ..., "statusMessage": ..., "timeout": <sec>}]}]}}`. Only `type:"command"` handlers execute today (`prompt`/`agent` parsed but skipped). Default timeout **600s**.
- **Events (10, not 3):** SessionStart (matcher `source`: startup/resume/clear/compact), UserPromptSubmit (`prompt`), PreToolUse (`tool_name`, `tool_use_id`, `tool_input`), PermissionRequest (`tool_name`, `tool_input`), PostToolUse (adds `tool_response`), PreCompact, PostCompact, SubagentStart, SubagentStop, Stop (`stop_hook_active`, `last_assistant_message`). Common payload: `session_id`, `cwd`, `hook_event_name`, `model`, `permission_mode`, `transcript_path` (nullable); turn-scoped events add `turn_id`.
- **Decisions mirror Claude Code:** PreToolUse → `hookSpecificOutput.permissionDecision` (`allow`/`deny`, `updatedInput`, or exit code 2 + stderr); PermissionRequest → `hookSpecificOutput.decision.{behavior, message}`; PostToolUse → `{"decision":"block","reason":...,"continue":false}`.
- **Big caveat:** PreToolUse intercepts the **shell tool only** — `apply_patch`, Read/Edit/Write, web fetch, and MCP calls never fire it. So Notchi's rollout-transcript synthesis (function_call/function_call_output parsing, dedup by call_id) is still needed for full tool-event coverage — but native PermissionRequest/PreToolUse hooks can now replace the synthesized `exec_command` permission flow, and remote approval of Codex shell commands is possible the same way as Claude.

## Resolved: models.dev/api.json schema (cost dashboard)

Top-level: map of 167 provider ids → `{id, env, npm, name, doc, models}`. `models` is a map keyed by model id (e.g. `anthropic.models["claude-sonnet-4-6"]`). Per-model fields: `id`, `name`, `family`, `attachment`, `reasoning`, `reasoning_options`, `tool_call`, `structured_output`, `temperature`, `knowledge`, `release_date`, `last_updated`, `modalities.{input,output}`, `open_weights`, `limit.{context, output}`, and **`cost.{input, output, cache_read, cache_write}` in USD per 1M tokens**. Map onto transcript usage: `input_tokens`→cost.input, `output_tokens`→cost.output, `cache_read_input_tokens`→cost.cache_read, `cache_creation_input_tokens`→cost.cache_write. File is ~3.2 MB — fetch it live but bundle a pruned (anthropic+openai-only) fallback JSON, exactly as Notchi does.

## Resolved: mediaremote-adapter status

ungive/mediaremote-adapter remains active and self-describes as "Fully functional MediaRemote access for all versions of macOS." The perl path (`/usr/bin/perl` = bundle id `com.apple.perl5`, DynaLoader loads the bundled framework; no SIP disable required) is still the recommended adapter; no credible reports that macOS 26 (Tahoe) broke it. Safe to vendor as boring.notch does; keep the AppleScript fallback + `test`-function deprecation probe as insurance.

## Resolved/augmented: OAuth usage endpoint

Community usage (Claude-Code-Usage-Monitor issue #202) corroborates `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <keychain OAuth token>` + `anthropic-beta: oauth-2025-04-20`, returning window utilization/reset data (five_hour/seven_day shape as read from Notchi source). **Critical detail missing from the research: send `User-Agent: claude-code/<version>` — without it you land in an aggressively rate-limited bucket and get persistent 429s. With it, ~180s polling intervals are reported safe** (Notchi's event-triggered refresh on SessionStart/UserPromptSubmit with backoff is comfortably within this). Endpoint remains undocumented/unofficial — build with graceful degradation (Notchi's Retry/Reconnect/"Open Claude Code" recovery states).

FEATURES:
- Claude Code PermissionRequest hook is official: input carries tool_name, tool_input, tool_use_id, permission_suggestions[{behavior,description,rule}]; output is hookSpecificOutput.decision{behavior: allow|deny, updatedInput, updatedPermissions:[{behavior,rule}]} — enables notch-side remote approval exactly as Notchi does
- PreToolUse decision schema: hookSpecificOutput.permissionDecision = allow|deny|ask|defer + permissionDecisionReason + updatedInput + additionalContext (ask/defer and additionalContext are extra capabilities the research missed)
- Use the Notification hook (matchers: permission_prompt, idle_prompt, agent_needs_input, agent_completed) as the official 'session needs attention' signal instead of inferring from Stop/PermissionRequest status mapping
- All Claude hooks receive session_id, prompt_id, transcript_path, cwd, permission_mode (default/plan/acceptEdits/auto/dontAsk/bypassPermissions), hook_event_name, effort.level, agent_id/agent_type — permission-mode badge and per-subagent attribution come free
- transcript_path may lag real-time — read last_assistant_message from Stop/SubagentStop payloads rather than relying solely on transcript tailing for the final message
- Claude Code now has 29 hook events incl. PostToolUseFailure, PostToolBatch, SubagentStart, TaskCreated/TaskCompleted, StopFailure, PostCompact, ConfigChange, FileChanged — richer session-state machine possible than Notchi's 9-event registration
- Codex hooks are enabled by default ([features] hooks = false to disable; codex_hooks is a deprecated alias) — do not force the legacy flag in new installs
- Codex emits 10 hook events (SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, SubagentStart, SubagentStop, Stop) with Claude-compatible decision JSON — native remote approval works for Codex shell commands; no need to synthesize PermissionRequest from rollout transcripts for exec_command
- Codex PreToolUse fires for the shell tool ONLY (not apply_patch/Read/Edit/Write/web fetch/MCP) — keep Notchi-style rollout transcript parsing (function_call/function_call_output, dedupe by call_id) for full tool-event coverage
- Codex hooks.json schema: {hooks: {Event: [{matcher, hooks: [{type:'command', command, commandWindows, statusMessage, timeout}]}]}}; default timeout 600s; locations ~/.codex/hooks.json, ~/.codex/config.toml [hooks], repo-local .codex/ variants; only type:'command' runs; repo-local config.toml hooks have a known interactive-session bug (openai/codex#17532)
- Codex hook payload common fields: session_id, cwd, hook_event_name, model, permission_mode, transcript_path (nullable), turn_id on turn-scoped events; Stop carries stop_hook_active + last_assistant_message
- models.dev/api.json pricing schema: providers map → provider.models map → model.cost{input, output, cache_read, cache_write} USD per 1M tokens + limit{context, output}; ~3.2MB so bundle a pruned anthropic/openai fallback
- Cost math mapping: input_tokens×cost.input + output_tokens×cost.output + cache_read_input_tokens×cost.cache_read + cache_creation_input_tokens×cost.cache_write, per message.model, deduped on message.id|requestId
- mediaremote-adapter (perl com.apple.perl5 trick) still works on current macOS incl. 26/Tahoe and remains the recommended now-playing observation path; vendor it with boring.notch's test-probe + AppleScript fallback
- OAuth usage endpoint hardening: GET api.anthropic.com/api/oauth/usage requires Authorization: Bearer + anthropic-beta: oauth-2025-04-20 AND User-Agent: claude-code/<version> (missing it causes persistent 429s); ~180s polling is safe; keep event-triggered refresh with backoff and UI recovery states
- SessionEnd matchers are clear/resume/logout/other and SessionStart matchers are startup/resume/clear/compact — register hooks with matchers to distinguish /clear from real session end (Notchi treats all SessionEnd alike)