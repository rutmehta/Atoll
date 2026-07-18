# Features/AgentsUI — integration notes

All SwiftUI for the agent monitor. Consumes `Features/Agents` engine state
(`AgentSessionStore.shared`, `AgentHookInstaller.shared`, `AgentTerminalJump`)
and adds two managers of its own (`AgentUsageManager`, `AgentCostScanner`).

## Views + placement

| View | Placement |
|---|---|
| `AgentsPanelView(onDismiss:)` | Open-notch **Agents tab** content. Self-contained: sub-tabs Sessions / Usage / Costs, session rows with expandable activity feeds, empty state with "Install hooks" CTA. When any session has a `pendingPermission` the approval card automatically takes over the top of the panel. `onDismiss` is invoked on **Esc** from the approval card — pass `{ vm.close() }`. |
| `AgentApprovalCardView(session:payload:onDismiss:)` | Used internally by `AgentsPanelView`; only needed directly if the integrator wants the card elsewhere. Keyboard: `1` Deny, `2` Allow, `3` Allow + don't ask again (writes `updatedPermissions` from the first allow suggestion), `1…9` select AskUserQuestion options, Esc → `onDismiss`. The card needs key-window focus for keys to work (the open panel should `becomeKey`). |
| `AgentUsageBarsView()` | Inside the panel's Usage sub-tab (already wired). Reusable standalone. |
| `AgentCostDashboard()` | Inside the panel's Costs sub-tab (already wired). Reusable standalone. |
| `AgentsClosedWingView(onTap:)` | Closed-notch wing (either side; height fits 28–36 pt). One 5 pt dot per live session (max 5 + "+n"), red pulse on needs-attention. Renders `EmptyView` when no live sessions — gate `wingWidth` on `AgentSessionStore.shared.liveSessionCount > 0`. Pass `onTap: { vm.open(tab: .agents) }`. |
| `AgentsSettingsView()` | Settings window tab/section ("Agents"). Standard `.formStyle(.grouped)` styling. |

## Startup calls (AppDelegate)

Nothing beyond what `Features/Agents` already requires
(`AgentSessionStore.shared.start()`, `AgentHookInstaller.shared.refreshStatus()`).
`AgentUsageManager` / `AgentCostScanner` start themselves when the panel appears
(`AgentsPanelView.onAppear` calls `AgentUsageManager.shared.setPanelVisible(true)`
and `AgentCostScanner.shared.rescan()`).

Recommended (auto-open on approval): observe the store and honor the
`agentsui.autoOpenOnPermission` AppStorage key (Bool, default true):

```swift
AgentSessionStore.shared.$sessions
    .map { $0.values.contains { $0.pendingPermission != nil } }
    .removeDuplicates()
    .sink { pending in
        if pending, UserDefaults.standard.object(forKey: "agentsui.autoOpenOnPermission") as? Bool ?? true {
            vm.open(tab: .agents)
        }
    }
```

## Managers exposed

- `AgentUsageManager.shared` (`@MainActor ObservableObject`):
  `claudeUsage`/`codexUsage` (`AgentProviderUsage`: windows `{label, percent, resetsAt}`,
  `creditsBalance`), `claudeStatus`/`codexStatus` (`AgentUsageStatus`:
  idle/loading/loaded/stale/error+recovery), `refresh(force:)`, `retry(_:)`,
  `setPanelVisible(_:)` (drives the 300 s timer), `probeAccounts()`,
  `isStale(_:)`. Claude token via `/usr/bin/security find-generic-password -s
  "Claude Code-credentials" -w` with `~/.claude/.credentials.json` fallback;
  Codex via `~/.codex/auth.json` (JWT exp checked locally). Exponential backoff
  on 401/429 (60 s → 1 h).
- `AgentCostScanner.shared` (`@MainActor ObservableObject`): `days`
  (30 `AgentDayCost`, oldest first), `totalUSD30`, `todayUSD`, `totalTokens30`,
  `modelsSeen`, `scanning`, `rescan(force:)`. Incremental JSONL scan cache at
  `~/Library/Application Support/AgentNook/agent-cost-cache.json`; pricing =
  bundled fallback table overridden by `models.dev/api.json` (10 s timeout,
  fetched once per launch).

## Settings keys

Reuses Core keys `agentsNotifyOnAttention`, `agentsNotifyOnCompletion`,
`agentsIdleCutoffMinutes`. Adds `agentsui.autoOpenOnPermission` (Bool, default
true — read by the integrator, see above).

## Permissions / Info.plist

None. Network calls go to `api.anthropic.com`, `chatgpt.com`, `models.dev`
(unsandboxed app, no ATS exceptions needed — all HTTPS). The keychain read
shells out to `/usr/bin/security`, avoiding the ACL prompt. No TCC prompts.

## Behavior notes

- All notch-side views are designed for the dark/black notch: white text,
  `Color.white.opacity(0.06…0.16)` layers, 9–13 pt fonts. `AgentsSettingsView`
  is the only system-styled (light/dark) view.
- Clicking a session row header jumps to its terminal (`AgentTerminalJump`);
  if there is no PID (transcript-discovered session) the click expands the
  activity feed instead. The chevron always toggles expansion.
- The approval card shows a countdown (hooks give up after ~290 s). Denying
  sends the documented `hookSpecificOutput.decision.behavior = deny` shape;
  AskUserQuestion answers are injected via `updatedInput.answers[question]`.
- Usage bars: green < 50 %, amber < 80 %, red ≥ 80 %; stale data dims to gray
  with the failure message; hard errors show a recovery hint + Retry.
