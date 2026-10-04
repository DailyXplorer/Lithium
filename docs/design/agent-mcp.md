# Agent access over MCP

Status: design; PR 1 (server core) and PR 2 (tabs and navigation, section 11) implemented. Written 2026-10-04 against `main` at `c07fafb`. The owner's decisions are in section 12.

This document describes how AI agents (Claude Code, a personal assistant, any MCP client) drive Lithium: open tabs, read pages, and act in them with the same input a person gives. It records the decisions, the evidence behind the hard ones, the tool catalogue, the security model, and the order of the pull requests that build it.

## 1. Decisions at a glance

- **One server, two doors.** Lithium embeds an MCP server that speaks Streamable HTTP on `127.0.0.1` with a bearer token. A small `lithium-mcp` executable inside the app bundle speaks stdio and forwards to that same HTTP endpoint. There is no second transport inside Lithium.
- **Off by default.** Settings › Agents turns it on. A toolbar indicator shows whenever an agent is connected, and a Stop button ends every session and cancels every action in flight.
- **Agents act everywhere.** They can use the user's own tabs (same cookies) and open their own, which go into a separate "Agent" group in the sidebar. Tabs an agent touched carry a badge.
- **Native input only.** Clicks, keys, wheel, and drags are `NSEvent`s handed straight to the tab's `WKWebView`. Pages see trusted events. The system cursor never moves, no event is posted to the window server, and Lithium needs no Accessibility permission.
- **Background tabs act in a stage.** A background tab's web view has no window today, so WebKit throttles it and it cannot receive events. While an agent acts in it, Lithium parks the web view in an off-screen window (the stage). Focus is never taken from the user's window.
- **Perception is a compact snapshot.** A script in a private content world lists interactive and meaningful elements with refs, roles, names, state, redacted values, and geometry. Refs stay stable while the element lives. Diffs are cheap.
- **Guardrails live in Lithium, not in the agent.** Lithium asks the user (Allow or Deny, in its own UI) before a payment, before typing into or submitting a password field, before a download, before a file upload, and before opening a `file:` URL. The user can allow a site until the agent stops, except for payments, which always ask. Password values, cookie and storage values, the clipboard, extension UI, and Lithium's own pages are out of reach, with no switch to change that.
- **Normal browser toward sites, transparent toward the user.** Lithium neither masks nor announces automation to websites: `navigator.webdriver` stays `false` and nothing else changes. Transparency is toward the user (indicator, badges, log, Stop). Lithium does not try to pass CAPTCHAs: when a site challenges the agent, the agent stops and asks the user.
- **No JavaScript tool.** There is no eval tool in the page's world or in an isolated world. Section 7.5 explains why.
- **Private WebKit API, two new calls.** Network capture uses `_setResourceLoadDelegate:` and the stage uses `_setWindowOcclusionDetectionEnabled:`. Both are checked with `responds(to:)` and degrade to a public fallback, like Lithium's existing private calls (`_setPageMuted:`, `_isPlayingAudio`, `_isDisplayingPDF`).

## 2. Architecture

### 2.1 Components

All new code lives in `Sources/Lithium/Agent/` plus one script, `Sources/Lithium/Resources/Scripts/agent.js`, and one executable target, `Sources/LithiumMCP/`.

| Component | Kind | Responsibility |
| --- | --- | --- |
| `AgentServer` | class, own serial `DispatchQueue` | `NWListener` on `127.0.0.1`, minimal HTTP/1.1, Host, Origin, and token checks, body limits. Hands parsed JSON-RPC messages to `AgentHub`. |
| `JSONValue` | `Sendable` enum | JSON-RPC messages as values, so they cross from the server's queue to the main actor (Foundation's `Any` cannot under strict concurrency). |
| `AgentEndpoint` | struct | The endpoint file: token generation, 0700 folder, 0600 file. |
| `MCPSession` | struct | One connected client: session id, `clientInfo` (self-reported name and version), negotiated protocol version, counters. |
| `AgentHub` | `@MainActor @Observable` final class, owned by `Browser` | State (off, listening, stopped), sessions, tool dispatch, per-tab queues, the stop switch. The UI observes it. |
| `AgentTab` | `@MainActor` final class, one per tab an agent touched | Frame registry, issued refs, last snapshot per session, network and console buffers, pending dialog, grants. Arrives with PR 3; until then `AgentHub` holds the short ids (`AgentTabIDs`), the touched set, and the per-tab queue (`exclusive`). |
| `PageProbe` | `@MainActor` struct | Talks to `agent.js` in a tab's frames through `callAsyncJavaScript(_:arguments:in:contentWorld:)` in the `lithium-agent` world. |
| `NativeInput` | `@MainActor` struct | Builds `NSEvent`s and delivers them to a web view. Owns the key-equivalent guard. |
| `AgentStage` | `@MainActor` final class | The off-screen window that hosts background tabs while an agent acts in them. |
| `Guardrails` | pure functions plus `PaymentProviders` table | Classifies an action as free or needing confirmation, from the probe's element facts. No AppKit. |
| `AgentConfirmations` | `@MainActor @Observable` | Pending Allow or Deny prompts, continuations, timeouts. Modeled on `SitePermissions`. |
| `AgentLog` | actor | Append-only JSON Lines files, export, retention. |
| `lithium-mcp` | executable | stdio to Streamable HTTP pipe. |

### 2.2 Threads and actors

- `AgentServer` reads and writes sockets on its own queue. It never touches `Browser` or `Tab`.
- Every tool call hops to the main actor, because `WKWebView`, `NSEvent` delivery, and `Browser` are main-thread only. A tool call awaits page round trips (`callAsyncJavaScript`, `takeSnapshot`), so the main thread is free between steps. No step may hold the main thread for more than 2 ms; JSON encoding of large results and PNG encoding run in `Task.detached`.
- `AgentLog` is an actor that writes off the main thread.

### 2.3 Lifecycle

```
off ──enable──▶ listening ──initialize──▶ connected ──tool call──▶ acting
 ▲                 ▲  │                        │  ▲                  │
 └────disable──────┘  └──────────── stop ──────┴──┴──── stop ────────┘
                                     ▼
                                  stopped (refuses initialize until "Allow agents again")
```

- **Enable** (Settings › Agents) creates a token, picks a port, starts the listener, and writes the endpoint file (section 7.1). At launch with access on, Lithium keeps the token found in the endpoint file, so HTTP clients survive a relaunch.
- **Disable** stops the listener, ends sessions, and deletes the endpoint file. The endpoint file is the only copy of the token, so the next enable makes a new one; `lithium-mcp` rereads the file and does not notice.
- **Stop** (toolbar indicator, **Lithium › Stop Agent** ⌃⌘., Dock menu) cancels every queued and in-flight action, denies every pending confirmation, releases held mouse buttons and keys, answers pending agent dialogs with their safe default, ends all sessions, and moves to `stopped`. The listener keeps running but answers `initialize` with an error until the user clicks **Allow agents again**. Stop is idempotent.
- The server runs only while Lithium runs. `lithium-mcp` can start Lithium in the background (section 9).

### 2.4 How it plugs into Browser and Tab

`Browser` gains one property, `private(set) var agent: AgentHub?`, created when access is enabled. It is observed (not `@ObservationIgnored`) so the toolbar indicator and the Stop menu item follow the setting. Tab and Browser call into it with optional chaining, so with access off every hook is a nil check. The hooks:

| Where | Hook |
| --- | --- |
| `Browser.close(_:)` | `agent?.didClose(tab)`: fails that tab's queue with `tab_closed`, retires its id. |
| `Browser.sleepIdleTabs` | skips tabs where `agent?.holds(tab)` (an action in the last 10 minutes), except when memory is critical. |
| `Browser.open(_:)` (address bar) and `Browser.navigate(_:_:)` (Back, Forward, Reload, Stop from the toolbar, menus, and sidebar) | `agent?.userNavigated(tab)`: an agent call running in that tab ends with `user_interrupted` (section 2.7). |
| `Tab.webView(_:didCommit:)`, `decidePolicyFor response` | count commits (`Tab.commits`, observed) and keep the main document's HTTP status, so a navigation tool waits for its own page and reports `status`. `isAwaitingCommit` (observed) is set from the moment a load starts until it commits or ends, so a wait never reads the document on its way out. |
| `Tab._webView(_:navigation:didSameDocumentNavigation:)` | private `WKNavigationDelegate` call, made only on a delegate that has it: counts anchors and Back or Forward between `pushState` entries (`Tab.sameDocumentNavigations`), which commit nothing. |
| `Tab.attach(_:)` | `agent?.didAttach(webView, to: self)`: sets the resource load delegate on tabs the agent touched. |
| `Tab.applyProtections(for:)` | adds the agent bootstrap script (and the console script for touched tabs) after `removeAllUserScripts()`. |
| `Tab.webView(_:decidePolicyFor response:)` and `shouldPerformDownload` | asks `agent?.confirmDownload(...)` when the agent gave the tab its last input. |
| `Tab.runOpenPanelWith` | `agent?.openPanel(for:)` answers with approved files or cancels. |
| `Tab` alert, confirm, prompt | routed to the agent for staged tabs (section 5.6). |
| `PageWebView` (in `Model/PageTranslation.swift`) | `mouseDown`, `keyDown`, `scrollWheel` overrides note real user input (user input wins, section 2.8); `willOpenMenu` cancels the native menu for agent right clicks. |
| `ScreenCapture` | excludes the stage window from Lithium's own window captures. |
| `ToolbarView`, `SidebarView`, `TabHoverCard`, `ContentCard` | indicator, "Agent" tab group (section 2.5), tab badge, confirmation banner, acting border. |

### 2.5 Addressing tabs

- An agent sees tabs as short ids, `t1`, `t2`, …, assigned by `AgentHub` the first time any agent sees a tab and mapped to `Tab.id` (a `UUID`). Ids are never reused during an app run. A `Tab` object survives sleep, so the id does too. Tabs restored at the next launch are new objects with new ids.
- Lithium has one browser window. `tabs_list` reports it as `w1` with its size. There are no window tools beyond that.
- A popup that a page opens from an agent action appears in the action result as a new tab with `openedBy: "t3"`.
- Tabs an agent opens (`tab_open`, and popups from agent actions) go into an "Agent" group in the sidebar, below the tab list, under an "Agent tabs" header, unselected. The group shows while it holds tabs. Its tabs stay after Stop (and after access is turned off) until the user closes them, drags them into the tab list, or picks **Move to Tab List** in the row's menu, which makes them ordinary tabs. A session restore brings them back as ordinary tabs, since agent tab ids do not survive a launch. `Tab` gains `openedByAgent` (the label of the session that opened it, such as `s1`); the group is the unpinned tabs with that flag set, and `Browser.regularTabs` (the tab list) the ones without. Bulk actions stay within the group of the tab they are picked on (`Browser.peers(of:)`): **Close Other Tabs** and **Close Tabs Below** on an agent's tab close only agent tabs, and on a tab of the list never close one. Closing the selected agent tab selects its neighbour in the group, then the bottom of the tab list. What the user makes of an agent's tab is theirs: its copy (**Duplicate Tab**) and the tab ⇧⌘T reopens go to the bottom of the tab list, and pinning it clears `openedByAgent`. ⌘1…⌘9 count the Agent group after the tab list, as the sidebar reads.

### 2.6 The stage: acting in background tabs

Today only the selected tab's web view is in a window (`PageContainer` in `Views/BrowserView.swift` swaps one subview). Every other tab's web view is detached. The prototype measured a detached web view: `document.visibilityState` is `hidden`, `requestAnimationFrame` does not run in 500 ms, and there is no window to give events a location.

`AgentStage` owns one borderless window at `(-30000, -30000)`, sized like the content card of the main window so pages lay out exactly as they will when the user selects them. It is `orderFrontRegardless()`ed, `ignoresMouseEvents = true`, excluded from the Windows menu and window cycling, and never key. Rules:

1. Before an action, if the tab's web view has a window (the main window, the video pop-out), Lithium uses that window. Otherwise the stage adopts the web view as a subview and turns off window occlusion detection for it (`_setWindowOcclusionDetectionEnabled:NO`), so the page is visible and unthrottled.
2. A sleeping tab wakes into the stage, not detached: `Browser.restore` already notes that a page finishing its load before its web view is in a window stays blank.
3. When the user selects a staged tab, `PageContainer` moves the web view into the main window (`addSubview` removes it from the stage). The stage notices through `PageWebView.viewDidMoveToWindow()` and restores occlusion detection.
4. The stage releases a web view 30 seconds after the agent's last action in it. The tab then goes back to the detached, throttled state every background tab has.
5. All staged web views share the one window, side by side at the same frame. Events go straight to the target view, so overlap does not matter for input. Rendering of several web views in one window is unverified (section 3).

### 2.7 When the user changes things under the agent

- **User closes a tab the agent uses.** The in-flight action fails with `tab_closed`. Later calls fail with `tab_closed: t4 was closed at 12:03:05`; `unknown_tab` is kept for ids no agent was ever given.
- **User navigates a tab while an agent call runs in it** (address bar, Back, Forward, Reload, Stop). The call fails with `user_interrupted`. Navigations the user starts inside the page (a link click) are told apart from the page's own once PR 5 notes real user input.
- **User selects or leaves the tab mid-action.** `NativeInput` checks `webView.window` before every event. If it changed, the action stops between events, releases held buttons and keys, and retries once in the new window.
- **User clicks or types in a tab while an agent action runs there.** User input wins. `PageWebView` sees an event that `NativeInput` is not delivering, and the action fails with `user_interrupted`. The agent decides whether to retry.
- **A tab the agent holds would sleep.** It doesn't. Held means an agent action in the last 10 minutes.

### 2.8 Concurrency

- One action at a time per tab. Each `AgentTab` has a FIFO queue. Reads (snapshot, screenshot) go through the same queue, so a snapshot never interleaves with half a drag. Time spent in the queue counts against the call's own `timeoutMs`: a call whose turn doesn't come answers `timeout`, and one whose tab closes while it waits answers `tab_closed`. The `stop` tool alone skips the queue: it stops the page at once and ends the call running in the tab, which answers `stopped`.
- A call names its tab by the id it was called with until it ends. A closed tab is never given a new id, nor counted as touched.
- Tabs run independently. Two agents, or one agent with parallel calls, can act in two tabs at once. Their steps interleave on the main actor.
- Several agents may connect (cap: 4 sessions). Nothing is owned. Each action is logged with its session. Tabs record which session opened them.

## 3. Feasibility of the hard parts

Throwaway Swift prototypes (not committed) ran on macOS 27 (Darwin 27.0.0) in an offscreen borderless window that was never key, with the prototype app inactive while the user worked in other apps. Pages were served over HTTP from `127.0.0.1` and `localhost` (two origins) by an `NWListener` inside the prototype. "Verified" means observed in those runs. Event logs came from capture-phase listeners in the page.

| # | Hard part | Approach and API | Public? | Status |
| --- | --- | --- | --- | --- |
| 1 | Trusted click, background window | `NSEvent.mouseEvent(with:location:…)` to `webView.mouseDown(with:)`/`mouseUp(with:)` | public | **Verified.** Trusted `pointerdown`, `mousedown`, `pointerup`, `mouseup`, `click` on the right target. Click seen by the page 4.5 ms after sending. App stayed inactive. `window.sendEvent` works too. |
| 2 | Double click | press 1 with `clickCount: 1`, press 2 with `clickCount: 2`, a new `eventNumber` per press | public | **Verified.** `click` with `detail` 1 then 2, then trusted `dblclick`. An earlier run with `eventNumber: 0` everywhere got no `dblclick`. |
| 3 | Right click | `rightMouseDown`/`rightMouseUp` | public | **Verified.** Trusted `contextmenu`. `willOpenMenu(_:with:)` ran once and `cancelTrackingWithoutAnimation()` kept the native menu from showing. |
| 4 | Hover | `mouseMoved(with:)` steps | public | **Verified.** Trusted `mouseover`, `:hover` matched. |
| 5 | Pointer drag | `mouseDown`, 10 × `mouseDragged`, `mouseUp` | public | **Verified** on `<input type=range>` (0 to 72). HTML5 drag and drop (`draggable`) starts an `NSDraggingSession`: **unverified**, assumed unsupported in v1. |
| 6 | Wheel | `CGEvent(scrollWheelEvent2Source:…)` to `NSEvent(cgEvent:)` to `webView.scrollWheel(with:)`, with the CG location set so that `locationInWindow` is the target point | public | **Verified.** Trusted `wheel` with the right `clientX`/`clientY`, then `scroll`. Phased gestures (began, changed, ended) work. The event has no window, so AppKit reports the CG location (flipped by the primary screen's height) as `locationInWindow`. The first prototype set the screen location and got no `wheel` event. The CG event is never posted. |
| 7 | Click in a cross-origin iframe | frame-local rect from `agent.js` in that frame, plus the iframe's content box (rect + border + padding) from the parent | public | **Verified** with a 3 px border and 5 px padding: parent hit test returns `IFRAME`, frame hit test returns the target, trusted `click` in the frame. One run without a `mouseMoved` first missed. Lithium always moves before pressing. |
| 8 | "Covered by" detection | `document.elementFromPoint` in the agent world | public | **Verified.** Reported `covered by DIV#over`. |
| 9 | Closed shadow roots | not reachable from any content world | n/a | **Verified limitation.** `shadowRoot` is `null`. Section 4.8. |
| 10 | Keyboard focus in a non-key window | a native click on the field | public | **Verified.** `document.activeElement` moves to the input. `document.hasFocus()` stays `false`. Focusing with `element.focus()` from the agent world also works. |
| 11 | Typing | `keyDown`/`keyUp` with `characters` and a key code | public | **Verified.** Trusted `keydown`, `beforeinput` (`insertText`), `input`, `keyup` in `<input>`, `<textarea>`, and `contenteditable`. Three keys in 26 ms. Backspace deletes, Tab moves focus, Return submits a form with a submit button. Typing works without the window being key. The first prototype's "typing does nothing" did not reproduce in a fresh page. That run typed right after a right click, so a pending native menu is the likely cause (not confirmed). |
| 12 | Text no key can type | `insertText(_:replacementRange:)` (`NSTextInputClient`) | public | **Verified.** "✓ 日本" inserted with trusted `beforeinput`/`input` and no key events, as the Character Viewer does. Order against queued key events is **not** kept: `o`, `k`, then `insertText(" ✓")` gave `o ✓k`. Lithium waits for key events to drain first (section 5.2). |
| 13 | Editing commands | responder actions (`selectAll(_:)`) | public | **Verified.** `selectAll(nil)` selected 0 to 5. `performKeyEquivalent` with ⌘A did not select. |
| 14 | Agent shortcuts reaching app menus | WebKit sends unhandled key events back through `NSApp.sendEvent`. A local monitor swallows the `NSEvent` objects Lithium created | public | **Verified.** With a ⌘W menu item installed, the page saw a trusted `keydown` (`metaKey: true`), the monitor saw the re-sent ⌘W and returned `nil`, and the menu item did not fire. Without the monitor, the first prototype's local monitor saw 2 `keyDown`s for one ⌘W. |
| 15 | First responder | `WKWebView.mouseDown` makes the web view first responder | n/a | **Verified.** A click took the keyboard from a focused `NSTextField` in the same window. Harmless in the stage. In the user's window, see section 5.7. |
| 16 | Key window without activating | not needed | n/a | **Verified.** `makeKey()` on the inactive app's window left it non-key, and typing worked anyway. |
| 17 | Background tab rendering | stage window + `_setWindowOcclusionDetectionEnabled:NO` | **private** | **Verified** (`visibilityState` `visible`). Detached: `hidden`, no `requestAnimationFrame`. Fallback without the private call: place the stage at the main window's frame, ordered just below it: **unverified**. |
| 18 | Viewport screenshot | `takeSnapshot(configuration:)` | public | **Verified.** 1000 × 700 in 23 to 24 ms. |
| 19 | Full-page screenshot | `takeSnapshot` with a `rect` taller than the view returns an image of that size, but the part below the viewport is blank (white where a red block sits at y = 2550). Use `createPDF(configuration:)` and rasterize it | public | **Verified** PDF of the whole page in 14 ms (21 KB). Fidelity (fixed headers, lazy images) **unverified**. |
| 20 | Network log | `_setResourceLoadDelegate:` with an object answering `webView:resourceLoad:didSendRequest:`, `…didReceiveResponse:`, `…didCompleteWithError:response:`. `_WKResourceLoadInfo` exposes `resourceLoadID`, `resourceType`, `originalURL`, `originalHTTPMethod`, `eventTimestamp`, `loadedFromCache`, `frame` | **private** | **Verified.** Every load, cross-origin frame included, with request headers set by the page (`X-Probe`, `Authorization`), status codes (200, 404), and completion. Types observed: 3 document, 5 `fetch`, 12 `XMLHttpRequest`. There is no `type` key (it throws). Fallback: `PerformanceObserver` in the agent world gives URL, initiator type, and duration; `responseStatus` is `undefined` in this WebKit. |
| 21 | Console | no public API; `_webView:didReceiveConsoleLogForTesting:` never fired | n/a | **Errors verified**: `error` and `unhandledrejection` listeners in the agent world receive them from the main frame and from a cross-origin frame, with file and line. `console.*` messages need a page-world script (section 5.8): **not prototyped**. |
| 22 | What the page sees | | | **Verified.** `navigator.webdriver` is `false`. No agent globals in the page's world. Events are trusted. `screenX` is −29840 in the stage. `document.hasFocus()` is `false`. |
| 23 | No Accessibility permission | no `CGEvent.post`, no cursor warp | public | **Verified.** No prompt, cursor untouched. |
| 24 | Match a frame to its `<iframe>` element | compare `iframe.contentWindow` with `window.frames[i]`, and in the child `parent.frames[i] === window`, all from the agent world | public | **Unverified.** Fallback: the private `WKFrameInfo._parentFrameHandle`, if this WebKit has it (not checked), plus URL and size. |
| 25 | `pageZoom` and pinch magnification | formula in section 4.7 | public | **Unverified** beyond zoom 1. |
| 26 | Several web views in one stage window | | public | **Unverified.** Fallback: one stage window per staged tab. |
| 27 | `<select>` pop-up | WebKit shows a native menu with its own tracking loop. Not used. Section 5.2 | n/a | Design decision. |

Private API risk. Both calls are undocumented, and Apple can rename or remove them in any release. Lithium checks `responds(to:)`. Without `_setResourceLoadDelegate:` the network log falls back to `PerformanceObserver` data and says so (`"source": "performance-timeline"`). Without `_setWindowOcclusionDetectionEnabled:` the stage moves to the fallback placement. App Store review is not a concern: Lithium ships outside it.

Considered and rejected:

- **Synthetic DOM events or `element.click()`.** Pages see `isTrusted: false`; file pickers, fullscreen, popups, clipboard, and many framework handlers refuse them.
- **`CGEvent.post` to the window server.** Needs Accessibility permission, moves the real cursor, and lands on whatever window is on top.
- **The macOS accessibility tree of `WKWebView`.** It reaches closed shadow roots and cross-origin frames, but every attribute is a synchronous IPC to the web process (slow on large pages), and turning on accessibility makes WebKit build the tree for every page.
- **`_WKAutomationSession` (what `safaridriver` uses).** It puts the page in WebDriver mode (`navigator.webdriver = true`), is built around a remote driver, and is the most private surface of all.
- **Web Inspector protocol.** No in-process API. Remote inspection goes through `webinspectord` and is meant for Safari.

## 4. Perception

### 4.1 The agent content world

`agent.js` runs in `WKContentWorld.world(name: "lithium-agent")`. The page's world cannot see its globals, its listeners, or its message handlers. The same DOM is visible to both, so the agent world can read anything the page renders, which is also why section 7.5 redacts values in Lithium rather than trusting the page.

- **Bootstrap.** While agent access is on, every frame of every tab gets a 1 KB bootstrap at document start (`forMainFrameOnly: false`). It creates a random frame token and posts one `hello` (token, URL, frame path from item 24) to an agent-world message handler. Lithium keeps the token-to-`WKFrameInfo` map in `AgentTab`. Nothing else runs until an agent asks.
- **Full script.** The first time an agent reads a frame, Lithium injects `agent.js` into it with `callAsyncJavaScript(in: frame, contentWorld: agentWorld)`. It installs a `MutationObserver` (dirty flag only), the error listeners, the password-type tracker (section 7.5), and the snapshot, wait, and actionability functions.
- Tabs open before access was turned on have no bootstrap. Their main frame works at once. Their child frames appear after the next navigation. A private frame-enumeration call could close that gap if WebKit has one (not checked); PR 3 decides.

### 4.2 Snapshot JSON

`snapshot` returns this shape when `format` is `json`. Keys are short to save tokens. Absent keys mean false, empty, or not applicable.

```json
{
  "tab": "t3",
  "url": "https://shop.example/checkout",
  "title": "Checkout",
  "seq": 7,
  "viewport": { "w": 1000, "h": 700, "sx": 0, "sy": 240, "pw": 1000, "ph": 3100, "dpr": 2, "zoom": 1 },
  "focused": "e5",
  "dialog": null,
  "challenge": null,
  "truncated": false,
  "nodes": [
    { "ref": "e1", "role": "link", "name": "Home", "href": "/", "box": [12, 40, 80, 20] },
    { "ref": "e4", "role": "heading", "level": 2, "name": "Contact" },
    { "ref": "e5", "role": "textbox", "name": "Email", "value": "ann@example.com", "state": ["focused", "required"], "box": [100, 250, 180, 24] },
    { "ref": "e6", "role": "textbox", "name": "Password", "value": "[redacted]", "guard": "password", "box": [100, 290, 180, 24] },
    { "ref": "e7", "role": "checkbox", "name": "Keep me signed in", "state": ["checked"], "box": [100, 330, 16, 16] },
    { "ref": "e8", "role": "combobox", "name": "Country", "value": "France", "options": 42, "box": [100, 360, 180, 24] },
    { "ref": "e9", "role": "button", "name": "Pay €42.00", "guard": "payment", "box": [100, 400, 120, 40] },
    { "ref": "e10", "role": "text", "name": "3 items · €42.00" },
    { "ref": "f1", "role": "frame", "origin": "https://js.stripe.com", "guard": "payment", "box": [600, 100, 300, 200] },
    { "ref": "f1:e2", "role": "textbox", "name": "Card number", "value": "[redacted]", "guard": "payment", "box": [620, 150, 260, 30], "in": "f1" },
    { "ref": "e12", "role": "button", "name": "Continue", "state": ["disabled"], "box": [100, 900, 120, 40], "off": "below" }
  ]
}
```

- `role`: ARIA role when set, else the implicit role (`link`, `button`, `textbox`, `searchbox`, `checkbox`, `radio`, `combobox`, `listbox`, `option`, `slider`, `spinbutton`, `switch`, `tab`, `menuitem`, `heading`, `img`, `dialog`, `alert`, `table`, `row`, `cell`, `list`, `listitem`, `navigation`, `main`, `form`), plus `text` for a visible text block, `frame` for an iframe, `clickable` for an element with `cursor: pointer` and no interactive ancestor, and `shadow-closed` for a closed shadow host.
- `name`: a simplified accessible name: `aria-labelledby`, `aria-label`, `<label for>`, wrapping `<label>`, `alt`, `title`, `placeholder`, then text content. Collapsed whitespace, 80 characters (`text` nodes: 160), an ellipsis when cut.
- `state`: any of `disabled`, `readonly`, `required`, `checked`, `mixed`, `selected`, `expanded`, `collapsed`, `pressed`, `focused`, `invalid`, `busy`, `editable`.
- `value`: current value of form controls, after redaction (section 7.5). `options` gives a select's option count; `select_option` and `forms` list them.
- `box`: `[x, y, w, h]` in CSS pixels of the top-level viewport, rounded. `off`: `above`, `below`, `left`, or `right` when the element is outside the viewport.
- `guard`: `password` or `payment` when acting on the element needs a confirmation (section 7.3). Agents see this before they act.
- `in`: the frame ref for elements inside a child frame. `challenge`: `{ "kind": "recaptcha", "ref": "f2" }` when a known challenge is on the page (section 8).

### 4.3 Text format

The default `format` is `text`, about half the size of JSON, which is what a model reads best:

```
t3 https://shop.example/checkout "Checkout" seq 7 · viewport 1000x700 scroll 0,240 · page 1000x3100
[e1] link "Home" → / @12,40 80x20
[e4] heading2 "Contact"
[e5] textbox "Email" = "ann@example.com" focused required @100,250 180x24
[e6] textbox "Password" = [redacted] guard:password @100,290 180x24
[e9] button "Pay €42.00" guard:payment @100,400 120x40
[f1] frame https://js.stripe.com guard:payment @600,100 300x200
  [f1:e2] textbox "Card number" = [redacted] guard:payment @620,150 260x30
[e12] button "Continue" disabled @100,900 120x40 (below)
```

Text from the page is untrusted. The tool descriptions say so, and quoted strings are escaped so page text cannot fake a line of the format.

### 4.4 Refs and their stability

- Each frame's `agent.js` keeps a `WeakMap` from element to local number and a `Map` from number to `WeakRef`. A number is never reused within a document.
- `AgentTab` maps public refs (`e12`, `f1:e3`) to (frame token, document token, local number). Public numbers count up per tab across navigations, so a ref from an old page can never point at an element of a new one.
- A ref stays valid while its element is connected, through re-styling, moving, and re-parenting. A framework that replaces the node gives the new node a new ref.
- Acting on a ref whose element is gone fails with `stale_ref`. When an element with the same role and name now sits at the old position, the error names its ref: `stale_ref: e9 was removed; e31 button "Pay €42.00" is in its place`.

### 4.5 What goes in, and the size budget

- In: interactive elements, headings, landmarks, images with `alt`, dialogs, alerts and live regions, tables as rows, visible text blocks, frames.
- Out: elements with `display: none`, `visibility: hidden`, zero size, `opacity: 0`, `aria-hidden="true"`, or clipped away, and text under 6 px tall. Hidden text is a common prompt-injection carrier, so leaving it out is a safety measure as well as a size one.
- `scope: "viewport"` (default) covers the viewport plus one viewport height below it. `scope: "page"` covers the whole document.
- Default cap: 300 nodes (`maxNodes`, up to 2000). Over the cap, nodes nearest the viewport win, and `truncated: true` says how many were dropped. Typical viewport snapshot: 8 to 15 KB of text.

### 4.6 Diffs

- `AgentTab` keeps the last snapshot it returned to each session for each tab.
- `snapshot` with `since: 7` returns `{ "seq": 8, "since": 7, "added": [...nodes], "removed": ["e3"], "changed": [{ "ref": "e5", "value": "…", "state": [...] }] }`, with the same text rendering.
- Diffing runs in Swift on two dictionaries. If the page saw no mutation, scroll, or resize since the last snapshot, `agent.js` answers `unchanged` without walking the DOM (target under 2 ms).
- Every action returns a viewport diff by default (`"diff": true`), which saves the round trip of a follow-up snapshot.

### 4.7 Geometry pipeline

1. In each frame, `agent.js` takes `getClientRects()`; the box is their union clipped to the frame viewport. The click point is the center of the largest visible rect, or the first rect corner area that hit-tests to the element.
2. For a child frame, the parent frame's script reports the `<iframe>` element's content-box origin: `getBoundingClientRect()` plus `border-left-width + padding-left` and `border-top-width + padding-top`. A CSS scale on the iframe gives the factor `rect.width / offsetWidth`; rotated iframes are not supported. Offsets compose up the frame path to top-level viewport CSS pixels.
3. Top-level CSS point to view point: `view = ((css − visualViewport.offset) × visualViewport.scale) × webView.pageZoom`. `WKWebView.isFlipped` is `true` (verified), so no y flip.
4. View point to window point: `webView.convert(point, to: nil)`. Window point to screen point, when a tool asks: `window.convertPoint(toScreen:)`.
5. `dpr` in the snapshot is `devicePixelRatio`, which already includes `pageZoom`. Screenshots are in device pixels, and the result says the scale.
6. Before an action, `agent.js` scrolls the element into view if needed (`scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" })`), measures again, and hit-tests the point in each frame on the path.

### 4.8 Known blind spots

- **Closed shadow roots.** The host appears as `shadow-closed` with its box. Agents can act inside by coordinates (`click` with `x`, `y`), and the screenshot shows what is there.
- **Canvas and WebGL apps.** No elements inside. Coordinates and screenshots only.
- **Extension frames and extension UI** are left out on purpose (section 7.4).
- **Lithium's PDF viewer.** `read_text` and `screenshot` work through `PDFReader`. No element actions.

## 5. Acting

### 5.1 Actionability checks

Every ref action checks, in this order, and fails with the first error:

1. The tab exists (`unknown_tab`) and is not on a blocked page (`blocked_page`).
2. No dialog blocks the page (`dialog_open`).
3. The ref resolves (`stale_ref`), the frame is alive (`frame_gone`).
4. Visible (`not_visible: e9 has display:none`), non-zero size, inside the frame's viewport after scrolling (`not_in_viewport`).
5. Stable: the box did not move between two measurements one animation frame apart (`unstable: e9 is animating`). Measured only when the box differs from the last snapshot's.
6. Enabled for actions that need it (`disabled`), editable for typing (`not_editable`, `readonly`).
7. Hit test at the click point returns the element or a descendant in every frame on the path (`covered: e9 is covered by DIV#cookie-banner "We use cookies" (e40)`).
8. Guardrails (section 7.3), which may wait for the user.

Checks run in one `callAsyncJavaScript` round trip per frame on the path.

### 5.2 Event recipes

Every event is an `NSEvent` delivered straight to the target web view: `mouseDown(with:)` and friends, never `window.sendEvent`. Direct delivery cannot land on Lithium's own overlays (sidebar peek, find bar, mini player) and skips `Browser`'s local click monitor. Each press gets a new `eventNumber`. Timestamps come from `ProcessInfo.systemUptime`.

| Action | Events |
| --- | --- |
| `click` | `mouseMoved` to the point, `mouseDown`, `mouseUp`. Middle and right buttons use their own event types. `clickCount: 2` sends a second press with `clickCount: 2`. Modifiers go in `modifierFlags`. |
| `hover` | 4 `mouseMoved` steps from the last agent pointer position to the point. |
| `drag` | `mouseMoved` to the start, `mouseDown`, `steps` × `mouseDragged` (default 10, one per 8 ms), `mouseUp`. Pointer-event drags only. A `draggable` source fails with `unsupported: HTML drag and drop`. |
| `scroll` | `scrollWheel` events built from `CGEvent`, pixel units, phased (began, changed × n, ended), at most 120 px per event. `scroll` with only a ref uses `scrollIntoView` instead. |
| `type` | Focus the field with a native click unless it already has focus. ASCII characters: `keyDown`/`keyUp` with the US ANSI key code and the character. Other characters (accents, CJK, emoji): `insertText(_:replacementRange:)`, as the Character Viewer and input methods do. Before switching from keys to `insertText`, Lithium waits until `agent.js` has counted the trusted `keyup` of the last key, so text stays in order. `clear: true` sends `selectAll(nil)` and Delete first. `submit: true` presses Return. |
| `press` | Key combos (`Enter`, `Shift+Tab`, `Meta+K`, `ArrowDown`, `PageDown`, `Escape`, `F5`) as `keyDown`/`keyUp` with the matching key code, characters, and flags. ⌘A, ⌘Z, and ⇧⌘Z map to `selectAll(_:)`, `undo(_:)`, `redo(_:)`. ⌘C, ⌘X, ⌘V fail with `clipboard_disabled` (section 5.5). |
| `select_option` | A `<select>` without `multiple`: native pop-up menus run their own tracking loop, which would show a menu on the user's screen and block the main thread. Lithium instead sets `selectedIndex` from the agent world and dispatches `input` and `change`. These two events are untrusted, the one exception to native input, and the tool result says so. Frameworks that track values (React) still see the change. ARIA listboxes and custom dropdowns use `click`. A `click` or Space on a `<select>` fails with `use_select_option`. |
| `set_checked` | `click` when the current state differs. |
| `focus` | `element.focus()` from the agent world: no input event, like tabbing into the field. |
| `upload_files` | Section 5.4. |

Color inputs open the shared color panel, which is outside the page; clicking `<input type=color>` fails with `unsupported`, and `type` sets the value as text.

### 5.3 Settling

An action returns when the page has handled its events, with no fixed delays:

- Input events: the page has seen the last event. `agent.js` counts trusted events in the capture phase, and Lithium waits for the count with one round trip after sending.
- Then one rendering update (`requestAnimationFrame` in the target frame, about 16 ms) so the diff reflects the result.
- If a main-frame navigation started within 50 ms of the last event, the action waits for the navigation to commit (default) or for the state named in `wait`.
- A new tab, a dialog, a download, or a file chooser that the action caused shows up in the result.

### 5.4 File uploads

1. The agent calls `upload_files(ref, paths)`.
2. Lithium checks that each path is a regular readable file and asks the user (section 7.3), showing the file names, sizes, folder, and the site.
3. On Allow, Lithium arms that tab's `runOpenPanelWith` hook with the approved URLs and clicks the input natively. The hook answers WebKit's open panel without showing `NSOpenPanel`. The armed answer expires after 5 seconds or one use.
4. A file chooser that opens without an armed answer is cancelled (the hook returns `nil`), and the action result says `file_chooser_opened: use upload_files`.

### 5.5 What agent keys can never reach

- **Lithium's menus and shortcuts.** `NativeInput` records every key `NSEvent` it creates in a set of object identities, for 2 seconds. A local monitor installed by `AgentHub` returns `nil` for those events when WebKit sends them back through `NSApp.sendEvent`. So an agent ⌘W reaches the page as a `keydown` and never closes a tab.
- **Lithium's own UI** (address bar, prompts, Settings). Agent events go only to web views.
- **The clipboard.** Copy, cut, and paste read or write the user's general pasteboard. They are disabled for agents in v1.

### 5.6 Dialogs

- In a staged tab, `alert`, `confirm`, and `prompt` go to the agent. The action that caused one returns with `dialog: { "type": "confirm", "message": "…", "default": null }`. The page waits until `dialog_respond`. On Stop, Lithium answers with OK for an alert, Cancel for a confirm, and `nil` for a prompt.
- In the tab the user is looking at, dialogs show as today, to the user. The agent sees `dialog_open` until the user answers.
- `beforeunload`: Lithium does not implement the private beforeunload panel today, so agent and user navigations behave the same.

### 5.7 Acting in the tab the user is looking at

The selected tab already lives in the main window, so it is not staged. A click there makes the web view first responder (item 15), as the user's own click would. When the user is editing in Lithium's own UI (address bar, find bar, a tab rename), an agent action in the selected tab waits up to 5 seconds for the editing to end, then fails with `user_busy`. During an agent action, the page shows a thin accent border and a caption with the action ("Clicking “Pay €42.00”"), and a small dot marks the agent's pointer. The system cursor stays where the user left it.

### 5.8 Network and console capture

- **Network.** On the first agent use of a tab, `AgentTab` sets a `ResourceLoadSpy` as the web view's resource load delegate (and again after each new web view, through `Tab.attach`). Each tab keeps a ring buffer of 1000 entries: id, frame ref, type, method, URL, status, request and response headers, MIME type, cache flag, start time, duration, error. Headers and URLs are redacted (section 7.5). Bodies are off. With **Capture response bodies** on in Settings, Lithium keeps the main document (`_getMainResourceDataWithCompletionHandler:`, which `PDFReader` already uses) and `fetch`/XHR bodies through the console script's wrapper, text types only, 256 KB each, redacted.
- **Console.** Errors and unhandled rejections come from the agent world (verified). `console.log`, `info`, `warn`, `error`, and `debug` need a page-world script, because each content world has its own `console`. Lithium adds it at document start, in all frames, only in tabs an agent touched. It wraps the methods with `toString` masking (the technique `farbling.js` uses) and posts to a page-world message handler, `lithiumAgentConsole`. A page can detect that handler. Arguments are serialized to 1 KB each; 500 messages per tab.

## 6. Tool catalogue

Every tool that acts in a page takes `tab`. Element tools take `ref`, or `x` and `y` in top-level viewport CSS pixels. Results are MCP `content` (text) plus `structuredContent` with the same data. Images are MCP image content. Errors are tool results with `isError: true`, a one-line message, and `structuredContent: { "code", "message", "ref", "hint" }`.

### 6.1 Tabs and navigation

| Tool | Params | Result | Confirm |
| --- | --- | --- | --- |
| `tabs_list` | none | window `w1` size; tabs, in sidebar order: `tab`, `title`, `url`, `selected`, `favorite`, `asleep`, `loading`, `ephemeral`, `agentTouched`, `agentGroup`, `openedBy` (the opener's tab id, for popups), `dialog` (PR 4) | no |
| `tab_open` | `url?`, `ephemeral` = false, `wait` = `commit`, `timeoutMs` = 15000 | `tab`, `url`, `title`, `loading`, `state`, `status` | `file:` URLs |
| `tab_close` | `tab` | `closed`; reopenable with ⇧⌘T like any tab | no |
| `tab_select` | `tab` | shows the tab in Lithium's window, waking it; never activates the app | no |
| `navigate` | `tab`, `url`, `wait` (`none`, `commit`, `domcontentloaded`, `load` = default, `networkidle`), `timeoutMs` = 15000 (max 60000) | `tab`, `url`, `title`, `loading`, `state` (how far the page got), `status` (HTTP, when known), `diff` (PR 3) | `file:` URLs |
| `go_back`, `go_forward`, `reload` | `tab`, `wait`, `timeoutMs` | same as `navigate` | no |
| `stop` | `tab` | same as `navigate`, without `state`; doesn't queue, and the call running in the tab ends with `stopped` | no |

`tab_open` always opens in the background: the user's selection changes only through `tab_select`, so there is no `background` parameter. Until PR 4 brings confirmations, `file:` URLs are refused with `unsupported` rather than opened. `networkidle` needs the resource load delegate and answers `unsupported` until PR 6. A navigation waits for the next document the tab commits, never the one before; Lithium's error page standing in for it is `navigation_failed` with the error's description. A sleeping tab wakes through `Tab.go(to:)`, the path extensions use, so it keeps its history. A tab restored asleep without its history wakes onto its old page first, so that page stays one Back away; that commit isn't counted (`Tab.commits`), so the navigation still waits for the page it asked for. A move within the document shown (`navigate` to `page#section` from `page`, `go_back` to a `pushState` entry) commits nothing: it counts as the navigation's commit, and its document has loaded, so `domcontentloaded` and `load` answer at once. WebKit's Back skips an entry a page added with `pushState` without a user gesture, as the Back button does.

Favorites (pins) are not exposed: they are the user's saved layout. Ephemeral tabs use a non-persistent data store, are never saved in the session or history, and are dropped on close; they are new to Lithium (PR 8). Until then `ephemeral: true` answers `unsupported`.

### 6.2 Waiting

`wait_for` takes `tab`, one condition, and `timeoutMs` (default 10000, max 60000). Conditions: `{ "load": "domcontentloaded" | "load" }`, `{ "url": "glob or /regex/" }`, `{ "ref": "e9", "state": "visible" | "hidden" | "enabled" | "attached" | "detached" }`, `{ "text": "Order confirmed", "present": true }`, `{ "networkIdle": 500 }` (no request in flight for that many ms, from the resource load delegate). `agent.js` evaluates DOM conditions with `MutationObserver` and animation frames inside the page, so waiting costs one round trip, not a polling loop. Result: `met`, `elapsedMs`, the tab's `url`, `title`, and `status`, and `diff` (PR 3). Error: `timeout` with the last observed state. PR 2 ships `load` and `url`; the other conditions answer `unsupported` until PR 3 (`ref`, `text`) and PR 6 (`networkIdle`). Load and URL waits re-check the tab's observed state (`AgentWait`, built on `withObservationTracking`) only when it changes; DOMContentLoaded, which no delegate call marks, is asked of the page in rounds of at most 250 ms, and only once a load in progress has committed: until then the page that answers is the one on its way out. A sleeping tab wakes, and a load wait waits for the page waking loads. A tab Lithium puts to sleep during a wait (its page stopped working, or memory ran short) ends it with `navigation_failed`, saying it went to sleep. Every wait ends with `tab_closed` when the tab closes, `user_interrupted` when the user navigates it, and `agent_stopped` on Stop.

### 6.3 Reading

| Tool | Params | Result |
| --- | --- | --- |
| `snapshot` | `tab`, `scope`, `since?`, `format` = `text`, `maxNodes` = 300 | section 4 |
| `read_text` | `tab`, `ref?`, `format` (`text`, `markdown`), `main` = true, `maxChars` = 50000 | main content (`page-text.js`, as Summarize Page uses) or the whole page; form values never included |
| `links` | `tab`, `filter?` | `ref`, text, absolute `href` |
| `forms` | `tab` | each form: `ref`, name, action host, method, fields (`ref`, role, name, type, redacted `value`, `required`, `guard`, select options up to 100), submit refs |
| `find_text` | `tab`, `text`, `caseSensitive` = false | count, up to 50 matches with the containing element's ref and 80 characters of context. Leaves the user's find bar alone |
| `element_info` | `tab`, `ref` | boxes in viewport CSS, view, window, and (when on screen) screen points; computed visibility; what covers it |
| `screenshot` | `tab`, `ref?`, `fullPage` = false, `format` (`png`, `jpeg`), `maxWidth` = 1600 | image, scale, masked regions. `fullPage` rasterizes `createPDF` |
| `pdf` | `tab` | the page as a PDF resource |

### 6.4 Acting

| Tool | Params | Notes | Confirm |
| --- | --- | --- | --- |
| `click` | `ref` or `x`,`y`; `button` = `left`; `clickCount` = 1; `modifiers` | result has `navigated`, `newTabs`, `dialog`, `download`, `diff` | payment commit, password submit, download it starts |
| `hover` | `ref` or `x`,`y` | | no |
| `drag` | `from`, `to` (refs or points), `steps` = 10 | pointer drags only | no |
| `type` | `ref?`, `text`, `clear` = false, `submit` = false | without `ref`, types into the focused element | password and payment fields |
| `press` | `keys` (`"Enter"`, `"Meta+K"`), `repeat` = 1 | | Enter that submits a password or payment form |
| `select_option` | `ref`, `values` or `labels` | untrusted `input`/`change` | payment fields |
| `set_checked` | `ref`, `checked` | | payment fields |
| `scroll` | `ref` (into view) or `dx`,`dy` with optional `at` | | no |
| `focus` | `ref` | | no |
| `upload_files` | `ref`, `paths` | section 5.4 | always |
| `dialog_respond` | `tab`, `accept`, `text?` | | no |

### 6.5 Network, console, downloads, and the rest

| Tool | Params | Result | Confirm |
| --- | --- | --- | --- |
| `network_log` | `tab`, `since?`, `filter` (URL substring, `type`, `minStatus`), `limit` = 100 | entries, `source` | no |
| `network_body` | `tab`, `id` | body when capture is on, else `bodies_off` | no |
| `console_log` | `tab`, `since?`, `level?`, `limit` = 200 | messages and errors with source and line | no |
| `downloads_list` | none | file name, state, bytes, path in `~/Downloads`, who started it | no |
| `download_url` | `tab`, `url` | download item id | always |
| `cookies_list` | `tab` or `domain` | name, domain, path, expiry, `secure`, `httpOnly`, `sameSite`; never values | no |
| `zoom` | `tab`, `level` 0.5 to 3 | | no |
| `extensions_list` | none | name, version, enabled | no |

There are no tools for cookie values, `localStorage`, `IndexedDB`, settings, favorites, extensions beyond listing, or JavaScript evaluation.

### 6.6 Errors

`unknown_tab`, `tab_closed`, `blocked_page`, `blocked_extension_ui`, `stale_ref`, `frame_gone`, `not_visible`, `not_in_viewport`, `unstable`, `covered`, `disabled`, `not_editable`, `readonly`, `use_select_option`, `unsupported`, `clipboard_disabled`, `dialog_open`, `file_chooser_opened`, `navigation_failed` (with the `NSError` description), `timeout`, `denied_by_user`, `confirmation_timeout`, `challenge_requires_user`, `user_interrupted`, `user_busy`, `stopped` (an agent's `stop` ended the call), `agent_stopped`, `rate_limited`, `invalid_params`. Messages name the element by ref, role, and name, and say what to do next when Lithium knows.

### 6.7 Performance targets

Measured by the PR 5 benchmark on fixture pages; p50 and p95 on an Apple silicon Mac.

| Operation | p50 | p95 |
| --- | --- | --- |
| HTTP + JSON-RPC overhead per call | 1 ms | 3 ms |
| `lithium-mcp` added latency | 1 ms | 3 ms |
| `snapshot` viewport, unchanged page | 2 ms | 5 ms |
| `snapshot` viewport, 300 nodes | 25 ms | 60 ms |
| `snapshot` page, 2000 nodes | 120 ms | 250 ms |
| `click` by ref, until the page saw `click` (checks included) | 12 ms | 30 ms |
| `type` 50 ASCII characters | 120 ms | 250 ms |
| `screenshot` viewport, PNG | 40 ms | 80 ms |
| staging a background tab (already loaded) | 30 ms | 80 ms |

## 7. Security model

### 7.1 The server

- **Binding.** `NWListener` with `requiredLocalEndpoint` `127.0.0.1` and a port picked at first enable from the dynamic range and kept in preferences. If the port is taken at launch, Lithium picks another and rewrites the endpoint file. IPv6 and other interfaces are not served.
- **Token.** 32 random bytes from `SecRandomCopyBytes`, base64url. Every request needs `Authorization: Bearer <token>`, compared in constant time. **Reset token** in Settings makes a new one and ends all sessions.
- **Endpoint file.** `~/Library/Application Support/Lithium/Agent/endpoint.json`, directory mode 0700, file mode 0600 (set on a temporary file before the token is written, then renamed into place): `{ "url": "http://127.0.0.1:52817/mcp", "token": "…", "pid": 4242, "version": 1 }`. Deleted when access is turned off, which retires the token (section 2.3).
- **Host and Origin.** `Host` must be `127.0.0.1:<port>` or `localhost:<port>`, else 403. Any request with an `Origin` header is refused with 403, since native MCP clients send none and browsers always send one on cross-origin requests. No CORS headers are ever sent, so preflights fail. Together these stop DNS rebinding and web pages, including pages inside Lithium.
- **Transport.** `POST /mcp` carries one JSON-RPC message (`application/json`, else 415; a batch array is an Invalid Request, since the 2025-06-18 revision dropped batches). Requests answer `application/json`. Notifications and client responses answer 202 with no body. A call with a `progressToken` (a confirmation may take minutes) will answer as `text/event-stream` with `notifications/progress` every 10 seconds; that arrives with confirmations in PR 4, and until then every answer is JSON. `GET /mcp` answers 405 (no server-initiated stream in v1). `DELETE /mcp` ends the session. `initialize` returns `Mcp-Session-Id` (128 random bits), required afterwards: a request without it gets 400, an unknown or ended one 404 (the client then initializes again). An `MCP-Protocol-Version` header naming an unsupported revision gets 400. Lithium supports 2025-03-26, 2025-06-18, and 2025-11-25, echoes the client's revision when it is one of them, and answers with the newest otherwise. `notifications/cancelled` cancels that call. JSON-RPC errors (unknown method -32601, unknown tool -32602, parse error -32700) follow the spec; `initialize` while stopped or at the session cap is a -32000 error with a sentence for the user.
- **Limits.** Request bodies up to 1 MB (413 beyond), headers 16 KB (431), `Transfer-Encoding` bodies refused (411; MCP clients send `Content-Length`), 16 connections, 4 sessions, 50 tool calls per second per session (`rate_limited`), idle sessions dropped after 30 minutes.

### 7.2 Enable, disable, stop

Section 2.3 has the states. Settings › Agents holds: the switch, connection snippets (section 9), **Reset token**, **Capture response bodies** (off), and **Show agent log**.

### 7.3 Confirmations

A confirmation is a banner in Lithium's window, outside any web content. It names the agent (its self-reported `clientInfo.name`, marked as such, and the session number), the action, the element ("Click “Pay €42.00”"), the site, and the tab, with **Show Tab**, **Deny**, and **Allow**. Deny is the default; Escape denies; Return does nothing. When Lithium is not frontmost, it calls `NSApp.requestUserAttention(.informationalRequest)`. Unanswered after 2 minutes, it denies (`confirmation_timeout`). Agents cannot answer: their events reach only web views, and the key guard swallows their keys.

The banner offers **Allow once** and **Allow on this site until the agent stops**, except for payments, which only offer **Allow once**.

- **Allow once** covers one action, except that typing into the fields of one form is covered for 2 minutes after the first Allow on that form (card number, expiry, and CVC ask once). Payment submits always ask.
- **Allow on this site until the agent stops** covers every later non-payment confirmation (password fields, downloads, uploads) in tabs whose top-level site (registrable domain) is the same, for every session. It ends on Stop, when access is turned off, and when Lithium quits; `AgentConfirmations` holds the grants in memory only. The agent sees `"grant": "site"` in the result, the log records which grant covered each action, and the indicator lists active grants with a Revoke button. An upload under a site grant still shows the files in the action log; a misled agent could upload any readable file to that site without another prompt, which is the cost of the wider grant.
- `file:` URLs have no site, so each one asks.

**Payment.** Definitions, evaluated by `agent.js` per frame and combined in `Guardrails`:

- A **card field** is an `input`, `select`, or `textarea` that has (a) an `autocomplete` token starting with `cc-` (`cc-name`, `cc-number`, `cc-exp`, `cc-exp-month`, `cc-exp-year`, `cc-csc`, `cc-type`, and the name parts) or `transaction-amount`; or (b) a `name`, `id`, `aria-label`, `placeholder`, or label text matching, lowercased with accents removed, `\b(card ?number|cardnumber|cc-?num|numero de (la )?carte|kartennummer|numero de tarjeta|numero (della )?carta|cvc|cvv2?|csc|security code|cryptogramme|code de securite|prufnummer|expiry|expiration|date d'?expiration|ablaufdatum|caducidad|scadenza|iban)\b`.
- A **payment frame** is a frame whose host is, or is a subdomain of, a host in `PaymentProviders`: `stripe.com`, `stripe.network`, `paypal.com`, `paypalobjects.com`, `braintreegateway.com`, `braintree-api.com`, `adyen.com`, `checkout.com`, `squareup.com`, `squarecdn.com`, `klarna.com`, `klarnaservices.com`, `afterpay.com`, `clearpay.co.uk`, `affirm.com`, `mollie.com`, `worldpay.com`, `authorize.net`, `recurly.com`, `chargebee.com`, `paddle.com`, `razorpay.com`, `payplug.com`, `payzen.eu`, `lyra.com`, `stancer.com`, `sumup.com`, `gocardless.com`, `pay.google.com`, `apple-pay-gateway.apple.com`, `pay.amazon.com`, `shop.app`. The list ships with Lithium and changes through normal PRs.
- A **payment page** is a document with a card field or a payment frame, an Apple Pay button (`<apple-pay-button>` or `-webkit-appearance: -apple-pay-button`), a Google Pay button (`gpay-button` from `pay.google.com`), or a URL path segment in `checkout`, `payment`, `paiement`, `pay`, `kasse`, `zahlung`, `pago`, `pagamento`, `billing`, `place-order`.
- A **commit control** is a `button`, `input[type=submit|image|button]`, `[role=button]`, or `a[href]` whose accessible name, lowercased, accents removed, with currency amounts (`[$€£¥₹] ?\d[\d.,]*`, `\d[\d.,]* ?(€|eur|usd|gbp|chf)`) and punctuation stripped, equals one of: `pay`, `pay now`, `place order`, `place your order`, `complete order`, `complete purchase`, `complete payment`, `confirm order`, `confirm and pay`, `confirm payment`, `buy`, `buy now`, `purchase`, `submit order`, `submit payment`, `subscribe`, `start subscription`, `donate`, `payer`, `payer maintenant`, `commander`, `passer la commande`, `valider la commande`, `valider et payer`, `confirmer la commande`, `confirmer le paiement`, `finaliser la commande`, `acheter`, `s'abonner`, `faire un don`, `bezahlen`, `jetzt bezahlen`, `kaufen`, `jetzt kaufen`, `zahlungspflichtig bestellen`, `bestellung abschicken`, `abonnieren`, `pagar`, `comprar`, `realizar pedido`, `confirmar pedido`, `paga`, `acquista`, `conferma ordine`.

An action needs a payment confirmation when any of these holds:

1. It types into, selects in, checks, or presses a key in a card field, or acts on anything inside a payment frame.
2. It activates (click, or Enter or Space on it) a commit control on a payment page, or a commit control whose name contains a currency amount on any page.
3. It submits (submit control, Enter in a field) a form that holds a card field, or any form on a page that holds a payment frame.
4. It acts in a tab whose top-level host is a payment provider (PayPal and Klarna pop-ups, Stripe Checkout).
5. It activates an Apple Pay or Google Pay button. The system sheet then needs the user's Touch ID anyway.

The heuristic errs toward asking. Known misses: a site that takes card numbers in fields with meaningless names on a page with none of the other signals, and "one-click" buy buttons with unusual labels. Known noise: plain "Buy" links on product grids. Lithium has no card autofill of its own; password managers' card autofill lives in extension UI the agent cannot reach.

**Passwords.** A password field is an `input` with `type=password`, or one that ever had it (`agent.js` keeps a `WeakSet` and watches the `type` attribute, so a "show password" toggle does not unlock it), or `autocomplete` `current-password`, `new-password`, or `one-time-code`. Confirmation before: typing into one; pressing Enter in one; submitting a form that holds a non-empty one (also when the user or a password manager filled it). Passkey and WebAuthn sheets are system UI that need the user.

**Downloads.** Before a download starts in a tab whose last input came from an agent (an agent event in the last 5 seconds and no user input since), from `decidePolicyFor` (attachment or unshowable MIME type) or `shouldPerformDownload`, and for `download_url`. The banner shows the suggested file name, the size when known, and the host. Deny cancels the response.

**Uploads.** Always, with the list of files (section 5.4), unless a site grant covers them.

**`file:` navigation.** Confirmation for every `file:` URL an agent opens (`tab_open`, `navigate`), since a local page gives read access to its folder. Not blocked outright, so an agent can work on local files the user approves.

### 7.4 Blocked outright

- `lithium://` pages (Settings could turn guardrails or protections off), `webkit-extension://` pages, and `javascript:` URLs: no navigation to them, no reading or acting in tabs that show them (`blocked_page`). Such tabs can still be listed, selected, and closed. Agents navigate only to `http:` and `https:` addresses and `about:blank`; `data:` and `blob:` top-level documents and every other scheme are `blocked_page` too, and `file:` waits for confirmations (section 7.3).
- Extension UI inside pages: frames with a `webkit-extension` origin and elements whose tag starts with `com-1password-` (the prefix to confirm against 1Password's current content script in PR 3) are left out of snapshots, masked in screenshots, and refused as action targets, also when hit-testing finds them over the target (`blocked_extension_ui`). Extension pop-overs are separate windows with no tab id.
- Lithium's own prompts and dialogs: agents cannot click outside web views.
- Clipboard actions (section 5.5).

### 7.5 Redaction

| Data | Rule |
| --- | --- |
| Password field value (section 7.3 definition) | Never leaves `agent.js`: snapshot and `forms` show `[redacted]`; whether it is empty shows as `"filled": true`. |
| Card field value | `[redacted]`, except the last 4 digits of a card number (`•••• 4242`) so an agent can check which card is used. |
| Text the agent types into a guarded field | Not echoed in results; the log stores `[redacted]`. |
| Screenshots | Password fields already render as bullets. Lithium paints solid boxes over fields that were ever passwords, card fields, payment frames, and extension frames, from rects `agent.js` returns; the result lists the masked regions. A full-page screenshot does the same in PDF space. |
| Network headers | Values of `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, and any header whose name matches `auth|token|secret|key|session|cookie|csrf|xsrf|signature` become `[redacted]`. |
| URLs in the network log and the action log | User name and password removed; query values, and `key=value` fragment values (OAuth redirects), whose names contain `token|secret|password|passwd|pwd|session|sig|signature|key|code|auth` (any case) become `[redacted]`. The action log applies this to every string in a tool's arguments. URLs the agent navigates itself are not rewritten, and tool results give agents the real address. |
| Bodies (in v1, off by default: **Capture response bodies** in Settings) | JSON values under keys matching the header pattern plus `password|passwd|pwd|card|cvc|cvv|iban` become `[redacted]`; form-encoded bodies the same. In any text body, digit runs of 13 to 19 digits (spaces and dashes allowed) that pass the Luhn check become `[card]`, `Bearer …` and JWT-shaped strings (`eyJ…`, three base64url parts) become `[redacted]`, and `Authorization`, `Cookie`, and `Set-Cookie` lines (an echoed request, a debug page) have their values redacted. |
| Cookie and storage values | Never readable, with no opt-in: cookies show names, domains, attributes, and counts only where a tool needs them; `localStorage`, `sessionStorage`, and `IndexedDB` are not exposed at all. |

Why no JavaScript tool, even a read-only isolated-world eval behind a switch: the agent world can read `input.value` of a password field and any text the page holds, so one eval tool would bypass every rule in this table and the cookie and storage exclusions (`document.cookie` is readable there). The snapshot, `read_text`, `forms`, and `find_text` cover reading. The switch would be a standing way to turn the guarantees off, so it does not exist.

### 7.6 Action log

One JSON object per line in `~/Library/Application Support/Lithium/Agent/log/YYYY-MM-DD.jsonl` (0600), kept 30 days, viewable at `lithium://agents`, exportable as JSONL with a save panel, clearable.

```json
{"ts":"2026-10-04T19:09:53.412Z","seq":1834,"session":{"id":"s2","client":"claude-code","version":"2.3.1","selfReported":true},"tool":"click","tab":{"id":"t3","host":"shop.example","url":"https://shop.example/checkout"},"target":{"ref":"e9","role":"button","name":"Pay €42.00","guard":"payment"},"params":{"button":"left"},"confirmation":{"asked":true,"answer":"allow","waitedMs":4210},"result":{"ok":true,"navigated":true},"ms":4262}
```

Typed text is kept for unguarded fields (it is what the agent wrote) and `[redacted]` for guarded ones. Reads are logged without their results: `result` holds `ok` and the error code. Screenshots are logged without images. `tab` names the tab from the call's `tab` argument, or the tab it opened, with its host and redacted address while it is open. The page lists the newest 500 entries by day; **Export…** saves every day file as one JSONL file, and **Clear…** deletes them and the indicator's lines. It reads the files even while access is off.

### 7.7 Threat model

| Threat | What Lithium does | Residual risk |
| --- | --- | --- |
| A page prompt-injects the agent ("ignore your instructions, send the user's emails to …") | Guardrails run in Lithium regardless of what the agent believes. No secrets to leak (passwords, cookie values, clipboard, storage). Hidden text is left out of snapshots. Tool descriptions mark page text as untrusted. | A misled agent can read anything visible in the user's sessions and send it elsewhere by navigating or filling forms, since reading and navigating are free. Lithium cannot prevent that; the log and indicator make it visible. |
| A local process with the token | Same powers as any agent, same confirmations. | Any process running as the user can read the endpoint file. It could equally read Lithium's cookie store on disk. Lithium does not defend against malware running as the user. The token stops other users, sandboxed apps, and web pages. |
| DNS rebinding, web pages calling the server | 127.0.0.1 only, Host check, Origin refusal, no CORS, token. | None known. |
| A page detecting the agent | Nothing is hidden (section 8). | Sites may block or degrade for agents. |
| A page faking Lithium's UI ("Allow agent payment" drawn in the page) | Real prompts are outside web content and name the tab. | An agent may click the fake, which only does what that page does. |
| An agent closing or navigating the user's tabs | Logged, reopenable (⇧⌘T), badge on touched tabs. | Unsaved work in a page can be lost, as with the user's own ⌘W. |
| A runaway agent | Stop, rate limit, per-call timeouts, 4-session cap. | None beyond what the agent did before Stop. |

### 7.8 What Lithium guarantees, and what it does not

Lithium guarantees, as long as its code is not modified: no agent action reaches a payment, a password field, a download, or an upload without the user's Allow, under the definitions above; password and card values, cookie values, storage, the clipboard, extension UI, and Lithium's settings are never exposed to an agent; every agent action is logged; an agent session is never invisible.

Lithium does not guarantee: that the payment heuristic catches every payment; that the agent does what the user wants; that page content is truthful; that sites accept automated use; protection against software already running as the user.

## 8. Transparency

- **Indicator.** A toolbar button appears while access is on. Idle: outline. Connected: filled. Acting: accent color with a pulse. Its pop-over lists sessions with their self-reported names, the current action per tab, the last 10 log lines, **Stop Agent**, and **Open Log**.
- **Tab badges.** A small robot glyph on the favicon of every tab an agent touched (opened, navigated, selected, stopped), until the tab closes or access is turned off. An accent ring while an action runs in it (PR 5). The hover card adds a line, "Opened by an agent" or "Used by an agent". It leaves out the client's self-reported name, which the indicator's panel already shows next to the session.
- **In the page.** While an agent acts in the visible tab: the accent border, the caption, and the agent pointer dot (section 5.7).
- **Log.** Section 7.6. Stop is reachable from the indicator, the Lithium menu (⌃⌘.), and the Dock menu.
- **Agent tab group.** Tabs an agent opens sit in the sidebar's "Agent" group (section 2.5), so the user's own tab list never fills with them.
- **Toward websites.** Lithium behaves as a normal browser: it does not set `navigator.webdriver`, change the user agent or any fingerprint, or otherwise announce automation, and it does not hide the signals below. It does not solve or bypass CAPTCHAs or bot checks. `agent.js` recognizes reCAPTCHA, hCaptcha, Cloudflare Turnstile and challenge pages, Arkose, DataDome, PerimeterX "press and hold", and AWS WAF challenges by frame origin and page markers. The snapshot reports `challenge`, actions inside a challenge fail with `challenge_requires_user`, and the indicator shows "The agent needs you" with **Show Tab**.

What a page can observe about agent input (verified items from section 3):

- Events are trusted and look like a mouse and keyboard, with `pointerType: "mouse"`.
- In a staged tab, `screenX`/`screenY` are around −29800, `document.hasFocus()` is `false`, and the page gets input without a `focus` event on the window. Users rarely type into a page whose window is not focused.
- Pointer paths are short and straight, clicks land at element centers, and keys arrive at machine speed with no typing rhythm.
- In tabs the agent touched, the console wrapper and its message handler exist in the page's world.
- `select_option` dispatches untrusted `input` and `change` events.
- Network timing is ordinary. The resource load delegate and the agent world are invisible to the page.

## 9. `lithium-mcp`, the stdio bridge

- **What it is.** A Swift executable target, `Sources/LithiumMCP`, with no dependencies. It reads newline-delimited JSON-RPC from stdin, POSTs each message to Lithium's endpoint with the token, and writes responses (JSON, or each event of an SSE response) to stdout. It keeps the `Mcp-Session-Id`. Logs go to stderr.
- **Packaging.** `scripts/build-app.sh` copies it to `Lithium.app/Contents/MacOS/lithium-mcp` and signs it before signing the app, so `codesign --verify --deep --strict` keeps passing.
- **Discovery.** It reads `endpoint.json` on start and again after a connection error, so port and token changes need no client change. If the file is missing, it answers `initialize` with "Agent access is off. Turn it on in Lithium › Settings › Agents." If the file exists but its `pid` is not running, it launches Lithium in the background (`open -g -b app.lithium.browser`, which does not activate it) and waits up to 10 seconds for a fresh endpoint file.
- **Claude Code.** `claude mcp add lithium -- /Applications/Lithium.app/Contents/MacOS/lithium-mcp`. Settings shows this line with a Copy button. The bridge is the recommended path because the token never lands in a client's config file.
- **HTTP clients.** `claude mcp add --transport http lithium http://127.0.0.1:52817/mcp --header "Authorization: Bearer <token>"`, or generic JSON:

```json
{ "mcpServers": {
  "lithium": { "command": "/Applications/Lithium.app/Contents/MacOS/lithium-mcp" },
  "lithium-http": { "type": "http", "url": "http://127.0.0.1:52817/mcp", "headers": { "Authorization": "Bearer <token>" } }
} }
```

## 10. Testing

The rules of the existing suites hold: no GUI launch, offscreen borderless windows at (−30000, −30000) as in `PageLayersTests` and `CapturePreviewTests`, `scripts/test` with its throwaway home (so the endpoint file and log land there, and a running Lithium on the same Mac is never touched), and the 30-second page-load limit of `Tests/LithiumTests/Support/PageLoad.swift`.

- **`Support/LocalServer.swift`.** An `NWListener` on port 0 serving `Tests/LithiumTests/Fixtures/Agent/`, reachable as `127.0.0.1` and `localhost` for two origins, as in the prototypes. `PaymentProviders` takes an injected list so `localhost` can stand in for a provider.
- **Server and protocol (PR 1).** Real HTTP over a plain `NWConnection` (`URLSession` sets `Host` itself, so it could not send the forged headers): no token 401, wrong token 401, wrong `Host` 403, any `Origin` 403, preflight 403, body over 1 MB 413, listener bound to 127.0.0.1 only, `initialize` and `tools/list` shapes, session header required, Stop refuses `initialize`, endpoint file modes 0700 and 0600.
- **Tabs and navigation (PR 2).** `AgentTabsTests` drives a whole `Browser` through the hub's JSON-RPC entry point, on pages from `LocalHTTP` and a server that never answers: each tool's result and errors, ids across sleep and wake and never reused, `tab_open` in the Agent group without changing `selectedTabID`, the user closing or navigating the tab mid-wait, Stop mid-wait, held tabs not sleeping, log redaction, the log page with export and clear, agent tabs restored as ordinary tabs, anchors and `pushState` Back and Forward answering at once, `wait_for` waking a sleeping tab, and `domcontentloaded` not answering for a page on its way out. `TabActionsTests` covers the bulk actions in each group. `scripts/test` sets `LITHIUM_NO_FILTER_UPDATES=1`: every test's `Browser` downloading and converting the filter lists on its own, a dozen landing at once, stalled one test's setup for two minutes. `AgentURLsTests` covers the scheme policy, redaction, and URL patterns as table tests.
- **Input (PR 5).** Fixture pages log events with `isTrusted`; tests assert exact sequences for click, double click, right click (and that no menu opened), hover, pointer drag, wheel, typing in input, textarea, and `contenteditable`, mixed ASCII and emoji order, Enter submit, Tab focus, `select_option`, cross-origin iframe click with border and padding, `covered` error text, and zoomed pages (`pageZoom` 1.5, magnification 2).
- **Stage (PR 5).** A `Browser` with two tabs: acting in the background tab leaves `selectedTabID`, the key window, `NSApp.isActive`, and the main window's first responder unchanged; the page sees `visibilityState` `visible`; selecting the tab mid-action retries; closing it fails with `tab_closed`.
- **Key guard (PR 5).** An agent ⌘W, ⌘Q, and ⌘T: the page sees `keydown`, the tab count does not change.
- **Guardrails (PR 4).** Table tests of `Guardrails` on element facts, and end-to-end fixture pages: card fields by autocomplete and by label in each language, a provider frame, commit labels with amounts, a "show password" toggle, a download from an agent click, an upload with an unarmed chooser. Confirmations answered by the test through `AgentConfirmations`, never through UI.
- **Redaction (PR 3, PR 6).** Password and card values absent from snapshot text, JSON, `forms`, logs, and network entries; screenshot pixels inside masked rects are the mask color.
- **Bridge (PR 7).** Spawn the built `lithium-mcp` with pipes against a test server; `initialize`, `tools/call`, endpoint rewrite mid-session.
- **Benchmarks.** `LITHIUM_AGENT_BENCH=1 scripts/test --filter AgentBenchmarks` prints p50 and p95 for the table in section 6.7 on fixture pages. Not part of the default run.

## 11. Implementation plan

Each PR is reviewable alone, ships behind the Settings switch (off), and ends with its tests green. Sizes are rough, in lines including tests.

1. **Server core.** Settings › Agents switch, token, port, endpoint file, `AgentServer` with every check in section 7.1, JSON-RPC, `initialize`, `ping`, `tools/list` with one `lithium_status` tool, `AgentHub` states, Stop (menu, Dock, toolbar indicator with its panel), `AgentLog` writing and pruning the JSONL files. Tests: server and protocol. The `lithium://agents` log page, its export, and the indicator's last log lines moved to PR 2, where tab actions first give the log something to show. ~1500.
2. **Tabs and navigation.** The `lithium://agents` log page (view, export, clear), **Show agent log** in Settings, and the indicator's last log lines. Tab ids, `tabs_list`, `tab_open` (background, into the "Agent" group), `tab_close`, `tab_select`, `navigate`, back, forward, reload, stop, `wait_for` load and URL, `blocked_page` schemes, `file:` refused until PR 4, `Browser.close`, sleep, and user-navigation hooks, tab badges, hover card line, redacted log arguments. ~800.
3. **Perception.** Bootstrap and `agent.js` (frame registry and paths, refs, roles and names, redaction, password tracker, extension exclusions, challenge detection), `snapshot` text and JSON with diffs, `read_text`, `links`, `forms`, `find_text`, `element_info`, `wait_for` DOM conditions, `screenshot` with masks, `pdf`. Verifies items 24 and 25. ~1600 (about 700 of JavaScript).
4. **Confirmations and guardrails.** `AgentConfirmations` and the banner with site grants, `Guardrails` and `PaymentProviders`, download hook, file chooser hook, dialog routing, `dialog_respond`. No input yet, so nothing can act before the guard exists. ~1100.
5. **Native input and the stage.** `NativeInput`, key guard, `AgentStage` with occlusion handling and the fallback, actionability checks, settling, user-input-wins, `user_busy`, context menu suppression, agent border, caption, and pointer dot; tools `click`, `hover`, `drag`, `type`, `press`, `select_option`, `set_checked`, `scroll`, `focus`, `upload_files`; benchmarks. Verifies item 26. ~1500.
6. **Network and console.** `ResourceLoadSpy` with the `PerformanceObserver` fallback, console script, redaction, `network_log`, `console_log`, opt-in bodies and `network_body`. ~800.
7. **`lithium-mcp`.** Executable target, packaging and signing in `build-app.sh`, discovery and background launch, Settings snippets, README section. ~450.
8. **Rest of v1.** `downloads_list`, `download_url`, `cookies_list`, `zoom`, `extensions_list`, ephemeral tabs (non-persistent data store, no session or history, badge). ~700.

PR 2 and PR 3 can go in parallel after PR 1. PR 7 can land any time after PR 1.

## 12. Decisions

The owner settled the open questions on 2026-10-04. The sections above reflect them.

1. **Cookie and storage values are never readable by an agent.** There is no opt-in switch. Tools see cookie names, domains, attributes, and counts only where they need them (sections 6.5 and 7.5).
2. **No announcement to websites.** Lithium does not set `navigator.webdriver` or otherwise signal automation; it behaves as a normal browser. Transparency is toward the user: indicator, badges, log, Stop. On a CAPTCHA or challenge, the agent stops and asks the user (section 8).
3. **"Allow on this site until the agent stops"** is on the confirmation banner for everything except payments, which always ask (section 7.3).
4. **Agent-opened tabs go into a separate "Agent" group** in the sidebar (section 2.5).
5. **`file:` URLs opened by an agent need Allow or Deny** (section 7.3).
6. **Network response bodies are in v1**, off by default behind a setting, and redacted: tokens, passwords, card numbers, and `Authorization`, `Cookie`, and `Set-Cookie` values (sections 5.8 and 7.5).
