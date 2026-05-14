# Kairos

**STDIO MCP server for calendar and contacts collaboration on macOS.**

EventKit + Contacts, native AppKit, Objective-C. Events are identified by
`title + calendar + start` — no UUIDs in the LLM context. A confirmation
dialog appears before any deletion.

Modelled on the [ES UITest](../ES UITest) pattern: accessory app, `LSUIElement = YES`,
GCD queues for stdio framing, AppKit on the main thread.

---

## Tools

| Tool | Description |
|---|---|
| `calendar_list` | All calendars: name, type, source, editable |
| `events_in_range` | Events in a date window, optional calendar filter |
| `event_search` | Substring search across title, location, notes |
| `event_create` | Create a new event |
| `event_update` | Update by semantic key (title + calendar + start) |
| `event_delete` | Delete with native confirmation dialog |
| `reminder_lists` | All reminder lists: name, source, editable |
| `reminders_today` | Reminders due today + overdue (the morning brief) |
| `reminders_in_range` | Reminders due in a date window, optional list filter |
| `reminder_search` | Substring search across title and notes |
| `reminder_create` | Create a new reminder with optional due/priority/notes |
| `reminder_update` | Update by semantic key (title + list + due) |
| `reminder_complete` | Mark a reminder completed (reversible) |
| `reminder_delete` | Delete with native confirmation dialog |
| `contact_search` | Search contacts by name |
| `ask_user` | Native text-input popup |

---

## Xcode Project Setup

1. **New project**: macOS → App, Objective-C, bundle ID `com.elarity.kairos`
2. **Add all `.h`/`.m` files** from this folder (synchronized folder recommended)
3. **Frameworks**: EventKit.framework, Contacts.framework, AppKit.framework
4. **Info.plist** — add usage strings:
   ```
   NSCalendarsFullAccessUsageDescription  →  "Kairos needs calendar access for AI collaboration."
   NSContactsUsageDescription             →  "Kairos needs contacts access for AI collaboration."
   ```
5. **Entitlements** — App Sandbox OFF (same as ES UITest). For hardened runtime + notarization, add:
   ```xml
   <key>com.apple.security.personal-information.calendars</key><true/>
   <key>com.apple.security.personal-information.contacts</key><true/>
   ```
   These are only required for sandboxed apps, but harmless to include and
   required by notarization tooling in some configurations.
6. **Build Settings**:
   - `ENABLE_USER_SCRIPT_SANDBOXING = NO` (see ES UITest §10.5)
   - `PRODUCT_NAME = Kairos` (no spaces — avoids manifest path issues)
   - DerivedData outside iCloud (see ES UITest §10.2)
7. **Delete `MainMenu.xib`** — `main.m` bypasses `NSApplicationMain`; the xib
   is never loaded (see ES UITest §10.3), but removing it is cleaner.

---

## Event Identity

Events are identified by the triple **(title, calendar, start)**. This is
sufficient for personal calendars in virtually all real cases. An `index`
field appears in query results only when multiple events share the same
title and calendar within the result set (e.g. back-to-back recurrences).

The lookup window is ±2 minutes around the supplied start date, which
tolerates timestamp rounding in how the LLM echoes dates back.

## Reminder Identity

Reminders are identified by **(title, list, due)**. Same pattern as events
but `due` is optional — many reminders have no due date. Pass `due` as a
string when the reminder has one, omit it when it doesn't. The ±2 minute
window applies to the due date too.

The dedup `index` field appears when multiple reminders share title + list,
exactly mirroring the event mechanism.

Priorities are exposed as **strings**: `"high"` (EventKit priority 1–4),
`"medium"` (5), `"low"` (6–9), or omitted (0 = none). The numeric scale is
an EventKit-internal artifact; the LLM works better with semantic labels.

---

## Span Parameter

EventKit exposes two spans: `EKSpanThisEvent` and `EKSpanFutureEvents`.
The `span` parameter maps as follows:

| Parameter value | EKSpan |
|---|---|
| `"this"` (default) | `EKSpanThisEvent` |
| `"following"` | `EKSpanFutureEvents` |

There is no "all occurrences" that includes past events — `EKSpanFutureEvents`
covers this occurrence and all future ones, which is the standard calendar
behavior.

---

## Threading

| Concern | Thread / Queue |
|---|---|
| `[NSApp run]`, AppKit UI, NSAlert, AskUserWindowController | main thread |
| stdin reader (line-buffered) | `kairos.mcp.read` (serial) |
| per-request tool dispatch | `kairos.mcp.work` (concurrent) |
| stdout writes | `kairos.mcp.write` (serial) |
| EKEventStore operations | `kairos.ekbridge` (serial) |
| CNContactStore operations | `kairos.cnbridge` (serial) |

EKEvent and CNContact objects never cross their respective queue boundaries —
all results are converted to `NSDictionary` before being returned to callers.

---

## Authorization

Access is requested at launch in `AppDelegate`. The system permission dialog
appears on first run. Tool handlers check `isAuthorized` and return a clear
error message if the user denied access, directing them to System Settings.

---

## Build & Smoke Test

```sh
# Build
xcodebuild -project Kairos.xcodeproj -scheme Kairos \
  -configuration Debug -derivedDataPath /tmp/kairos-derived build

# Smoke test: initialize + tools/list
BIN="/tmp/kairos-derived/Build/Products/Debug/Kairos.app/Contents/MacOS/Kairos"
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
| "$BIN" 2>/tmp/kairos.err
cat /tmp/kairos.err

# Test calendar_list (keep stdin open — see ES UITest §10.8)
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"calendar_list","arguments":{}}}'
  sleep 3
} | "$BIN" 2>/tmp/kairos.err
```

---

## Gotchas Inherited from ES UITest

All of §10 from the ES UITest README applies here. Summary of the most
relevant:

- **§10.1** `setvbuf` on both stdout and stderr — done in `main.m`.
- **§10.2** Build DerivedData outside iCloud (`/tmp/kairos-derived`).
- **§10.3** Bypass `NSApplicationMain` — done in `main.m`.
- **§10.4** Hold `AppDelegate` in a static — done in `main.m`.
- **§10.8** Keep stdin open in shell tests (`sleep N` at end of pipe).

## New Dragons

### N.1 EKEventStore thread affinity

`EKEventStore` operations must run on the queue that created the store.
`EKBridge` enforces this via `dispatch_sync(self.queue, ...)` for all
store access. Never call store methods from another queue or the main thread.

### N.2 TCC prompts at first run

On first launch the system will show two permission dialogs (Calendar,
Contacts) before the MCP handshake completes. This is normal — the dialogs
are modal and block the main thread. The MCP host (Claude Desktop) will
wait. Subsequent launches skip the dialogs.

The two requests are **chained**, not parallel: Contacts only fires from
Calendar's completion handler, and only after a 500 ms hop back to the
main queue. Firing both `requestAccess` calls in parallel from
`applicationDidFinishLaunching` causes macOS TCC to silently drop the
second one — no dialog, immediate `denied`. See `AppDelegate.m`.

### N.3 EKEventStoreChangedNotification

External changes (another app saving an event) trigger this notification.
`EKBridge` observes it and calls `[store reset]` on the bridge queue.
In-flight queries complete before the reset runs (serial queue ordering).

### N.4 All-day event end dates

EventKit stores the end date of an all-day event as midnight of the *next*
day. `formatEvent:` detects `isAllDay` and emits only a `date` field
(from `startDate`), not `start`/`end`, to avoid surfacing the off-by-one
to the LLM.

### N.5 NSAlert on main thread

The delete confirmation `NSAlert` is dispatched to the main thread via
`dispatch_async` + semaphore, blocking the work queue thread while the
user responds — same pattern as `AskUserWindowController`. Only one
blocking main-thread operation should be active at a time; concurrent
`event_delete` calls will serialize on the semaphore naturally, but the
second alert won't appear until the first resolves.

### N.6 Xcode 26 declarative Resource Access (the three-gate TCC trap)

On macOS, getting a TCC dialog to appear requires **three** independent
gates lining up — miss any one and the system silently denies with no
prompt, returning immediate `CNErrorAuthorizationDenied` (or the EventKit
equivalent). All three are mandatory:

1. **Info.plist usage description** — `NSContactsUsageDescription` /
   `NSCalendarsFullAccessUsageDescription`. Set via the
   `INFOPLIST_KEY_NS...` build settings.
2. **Hardened-runtime entitlement** — auto-injected by Xcode 26's new
   resource-access build settings:
   - `ENABLE_RESOURCE_ACCESS_CALENDARS = YES` →
     `com.apple.security.personal-information.calendars`
   - `ENABLE_RESOURCE_ACCESS_CONTACTS = YES` →
     `com.apple.security.personal-information.addressbook`
     (note the *legacy* name — predates the Contacts.app rename;
     the iOS-style `personal-information.contacts` key is NOT
     recognized on macOS and including it in a hand-written
     entitlements file actively confuses TCC).
3. **Resource access build setting itself** — `ENABLE_RESOURCE_ACCESS_*`
   is the gate that tells the TCC daemon "this binary may legitimately
   ask for X." Without it, the entitlement alone isn't enough and TCC
   short-circuits the request before showing any UI.

`Kairos.entitlements` therefore only declares `app-sandbox = false`;
all personal-information entitlements are owned by the resource-access
build settings to avoid the iOS-vs-macOS key mismatch. Toggle them via
**Signing & Capabilities → + Capability → Resource Access** in Xcode.

### N.7 Reminders share the EKEventStore with events

`EKEventStore` handles both `EKEntityTypeEvent` and `EKEntityTypeReminder`.
A single bridge instance, a single queue, but **two independent TCC
entitlements** (`personal-information.calendars` and
`personal-information.reminders`) and two independent authorization
statuses. The store can be authorized for one entity type and denied for
the other — tool handlers must consult the right `isAuthorized` /
`isAuthorizedForReminders` flag.

Reminder fetches are async (`fetchRemindersMatchingPredicate:completion:`)
unlike events. `EKBridge` wraps the async API in a semaphore on the bridge
queue with a 10 s ceiling — if EventKit hangs, callers see an empty result
rather than a deadlock.

### N.8 Don't package `.mcpb` from a tested DerivedData

`xcodebuild test` injects `XCTest.framework`, `XCUnit.framework`, and
the test bundle's `.xctest` plugin into the host `.app`. The signature
of the resulting `.app` is **not** valid under `codesign -v --strict`,
and macOS TCC refuses to attribute permissions to a strict-invalid
bundle — `requestAccess` returns `denied` with no dialog.

`scripts/package-mcpb.sh` uses its own dedicated
`/tmp/kairos-release-derived` path, does a `clean build` (no `test`),
and aborts if it ever sees `PlugIns/` or `XCTest.framework` inside the
about-to-be-packaged bundle. Keep that guard.
