# App Review, local-network, and background constraints for a BYO-daemon iOS client

Research for [issue #5](https://github.com/noelrohi/shidou/issues/5), against the
Apple platform constraints that bind Shidou for iOS: a SwiftUI client that is
useless without the user's own `shidou-daemon`, reached over LAN or Tailscale on
`ws(s)://…/v1`, headed for TestFlight.

Every claim below is sourced to Apple. Where Apple's own text is silent or
ambiguous, this document says so instead of guessing. Read the **Flagged as
unverified** section at the end before treating anything here as settled.

Grounding facts about the current code, for context:

| Fact | Where |
| --- | --- |
| Transport is `URLSessionWebSocketTask` | `apps/ios/Packages/ShidouKit/Sources/ShidouClient/ShidouDaemonClient.swift:28` |
| Address normalization defaults a bare `host:port` to **`ws://`** | `apps/ios/Packages/ShidouKit/Sources/ShidouClient/DaemonEndpoint.swift:25` |
| Cleartext-to-non-loopback is already modelled as a warning state | `DaemonEndpoint.isInsecureRemote`, `DaemonEndpoint.swift:58` |
| The daemon listener is a plain `TcpListener` — **no TLS server anywhere** | `crates/shidou-daemon/src/main.rs:18`, `crates/shidou-core/src/server.rs:462` |
| The token is sent in-band in the WS hello, not as a TLS-protected header | `crates/shidou-core/src/server.rs:544` |
| Reconnect already carries replay cursors and re-handshakes | `ConnectionSupervisor.swift:76,135` |
| The daemon's replay journal is a bounded in-memory ring, 4096 events per session | `crates/shidou-core/src/server.rs:31,231` |

---

## 1. App Review risk for an app that requires the user's own daemon

### 1.1 Guideline 4.2 is not the threat people assume

Guideline **4.2 Minimum Functionality** reads:

> Your app should include features, content, and UI that elevate it beyond a
> repackaged website. If your app is not particularly useful, unique, or
> "app-like," it doesn't belong on the App Store. If your App doesn't provide
> some sort of lasting entertainment value or adequate utility, it may not be
> accepted.

and **4.2.2**:

> Other than catalogs, apps shouldn't primarily be marketing materials,
> advertisements, web clippings, content aggregators, or a collection of links.

— [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

A native SwiftUI transcript, composer, and session browser is not a web clipping
and not a collection of links, so 4.2/4.2.2 is a low risk. The clause people
usually fear is **4.2.3(i)**:

> Your app should work on its own without requiring installation of another app
> to function.

Read it precisely: the requirement is *another **app***. Shidou for iOS requires
a **server the user runs on their own Mac**, not another iOS app installed
alongside it. This is the same shape as every SSH client, VNC client, Plex
client, Home Assistant client, and self-hosted-service client on the App Store.
Nothing in the current 4.2.3 text extends the prohibition to a network service.

**4.2.3(ii)** is about download size on first launch and does not apply.

> If your app needs to download additional resources in order to function on
> initial launch, disclose the size of the download and prompt users before
> doing so.

*Verified.* The historical "must indicate required non-obvious hardware or
dependency in the description" bullet that circulates in older write-ups is **not
present** in the guidelines text as fetched. It is prudent product behavior, but
do not cite it as a rule.

### 1.2 The real gate is 2.1 App Completeness — the reviewer must be able to use it

> Submissions to App Review … should be final versions with all necessary
> metadata and fully functional URLs included … Make sure your app has been
> tested on-device for bugs and stability before you submit it, and include demo
> account info (**and turn on your back-end service!**) if your app includes a
> login. If you are unable to provide a demo account due to legal or security
> obligations, you may include a built-in demo mode in lieu of a demo account
> with prior approval by Apple. Ensure the demo mode exhibits your app's full
> features and functionality. We will reject incomplete app bundles and binaries
> that crash or exhibit obvious technical problems.

— [App Review Guidelines 2.1](https://developer.apple.com/app-store/review/guidelines/)

"Turn on your back-end service" is the operative instruction, and it is the one
constraint that actually costs us something: a reviewer on Apple's network cannot
reach a daemon on the developer's LAN. Apple's own App Review page names the
escape hatch:

> If features require an environment that is hard to replicate or require
> specific hardware, be prepared to provide a demo video or the hardware.
>
> Enter all of the details needed for review in the App Review Information
> section of App Store Connect, including special configurations and their
> specifics.

— [App Review](https://developer.apple.com/distribute/app-review/)

So there are three viable postures, in descending order of safety:

1. **Reachable demo daemon.** Stand up a `shidou-daemon` on a public host with a
   real hostname and TLS, and hand the reviewer the address plus token in the
   App Review Information notes. This makes the app fully exercisable and moots
   the whole question. It also happens to be the configuration that needs no ATS
   exception (see §3).
2. **Demo video plus detailed reviewer notes.** Explicitly sanctioned by the App
   Review page for hard-to-replicate environments.
3. **Built-in demo mode.** Sanctioned by 2.1, but note the text says *with prior
   approval by Apple* — it is not something you can unilaterally ship.

Option 1 for the submission and option 2 as the fallback is the low-risk path.

### 1.3 Two other guidelines worth knowing about

**2.5.2** is the one to keep an eye on as the transcript grows richer:

> Apps should be self-contained in their bundles, and may not read or write data
> outside the designated container area, nor may they download, install, or
> execute code which introduces or changes features or functionality of the app,
> including other apps.

Shidou for iOS **displays** agent-authored code and **relays** commands to a
daemon that executes them on the user's Mac. It does not download or execute code
that changes the iOS app's own functionality. That reading is sound, but it is
worth stating plainly in reviewer notes, because "coding agent" plus "runs
commands" is a phrase that invites a second look. Do not ship anything that
interprets server-delivered code *inside the app*.

**2.5.4** governs background modes and is the constraint referenced again in §4:

> Multitasking apps may only use background services for their intended
> purposes: VoIP, audio playback, location, task completion, local
> notifications, etc.

**Consequence:** declaring the `voip` background mode to keep a WebSocket alive
is a guideline violation, not a clever trick.

---

## 2. Local Network privacy

The authoritative source is **TN3179 Understanding local network privacy**, which
superseded the old "Local Network Privacy FAQ" forum thread on 2024-10-31.

### 2.1 What the key is and when you need it

> A message that tells people why the app is requesting access to the local
> network.
>
> Any app that uses the local network, directly or indirectly, should include
> this description. This includes apps that use Bonjour and services implemented
> with Bonjour, as well as direct unicast or multicast connections to local
> hosts.

— [`NSLocalNetworkUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)

### 2.2 A plain `ws://192.168.x.x` **does** trigger the prompt

TN3179 defines the terms and then closes the loophole people hope for:

> A local network is an IP network associated with a broadcast-capable network
> interface. Such interfaces include Wi-Fi and Ethernet, but not cellular (WWAN)
> or VPN. A local network address is any address on a local network. Traffic to
> a local network address goes directly; it's not forwarded by a router.
>
> Outgoing traffic to a local network address requires local network access.
>
> The system implements these TCP and UDP checks **deep in the networking stack,
> and thus they apply to all networking APIs**. This includes Network framework,
> BSD Sockets, URL Loading System, and any APIs implemented on top of those.

— [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

TN3179's operation table settles it item by item. Abridged to what we do:

| Operation | Requires local network access |
| --- | --- |
| Making an outgoing TCP connection | **yes** |
| Connecting a UDP socket | **yes** |
| Sending a UDP unicast / multicast / broadcast | **yes** |
| Listening for and accepting incoming TCP connections | no |
| Receiving an incoming UDP unicast | no |
| Resolving a local (`.local`) DNS name | **yes** |
| Resolving a non-local DNS name with the system resolver | no |

A WebSocket connection is an outgoing TCP connection, and
`URLSessionWebSocketTask` is part of the URL Loading System, so a `ws://` or
`wss://` connection to a LAN IP is a local network operation. There is no
"WebSockets are exempt" carve-out and **no API-level escape hatch** — the check
is below the frameworks. Discovery is irrelevant; connecting to a known IP by
hand is enough. Connecting by a `.local` name trips it twice (the DNS resolution
and the TCP connect).

TN3179 also anticipates our exact product shape:

> If your app allows people to enter an arbitrary network address, consider what
> happens if they enter a local network address. For example, if you're building
> an email client, check that it behaves correctly when the email server is on a
> local network.

Exceptions that do *not* require local network access: traffic to a local DNS
server, traffic to a local proxy, and traffic from `WKWebView` /
`SFSafariViewController` / Safari. None of those help us.

`.local` names are separately covered: resolving a name ending in `.local` is a
DNS operation that requires local network access.

### 2.3 Tailscale does **not** trigger the prompt

This is the most consequential finding in this section. TN3179's definition
excludes VPN interfaces from "local network":

> Such interfaces include Wi-Fi and Ethernet, **but not cellular (WWAN) or VPN**.

Tailscale on iOS is a Network Extension packet-tunnel provider; its `utun`
interface is a VPN interface, and `100.64.0.0/10` CGNAT addresses and `*.ts.net`
MagicDNS names are routed through it rather than being addresses on a
broadcast-capable interface. Therefore a Tailscale-reached daemon needs **no**
local network permission at all.

Corroborating, from the app-extension section:

> Network Extension packet tunnel provider, app proxy provider, and DNS proxy
> provider app extensions have local network access regardless of the Local
> Network privilege state of their container app.

*Caveat, flagged:* TN3179 never says the words "Tailscale" or "100.64.0.0/10".
The conclusion follows from the definition of a local network as an address on a
broadcast-capable interface, which a `utun` VPN interface is not. It is a
well-founded inference, not a literal quote. **Confirm on a device before making
a product promise out of it.**

### 2.4 Bonjour

> All Bonjour operations require local network access.

and, if you browse:

> If your app's local network usage involves registering or browsing for specific
> Bonjour services, add a list of service types to the `NSBonjourServices`
> property in your app's `Info.plist`.

— TN3179 / [`NSBonjourServices`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices)

Shidou does not do discovery today. **If a "find my Mac on this network" feature
is ever added**, it needs `NSBonjourServices` with the exact service type (e.g.
`_shidou._tcp`) — an undeclared type is not browsable. Multicast or broadcast
would additionally need the
`com.apple.developer.networking.multicast` entitlement, which is a **managed
capability requiring an Apple request/approval**, not a checkbox:

> To send or receive multicast or broadcast traffic, sign your app with the
> `com.apple.developer.networking.multicast` entitlement.

Plain unicast Bonjour resolution does not need the multicast entitlement; a
`_services._dns-sd._udp.local.` "browse everything" query does.

### 2.5 UX, denial handling, and the background trap

- Three states: **Undetermined**, **Allowed**, **Denied**. The user controls it
  in **Settings > Privacy & Security > Local Network**. The OS adds the app to
  that list only *after* it first attempts local network access. MDM cannot
  configure it.
- **The first attempt can fail even when the user says yes:**

  > If the system presents a local network alert in response to one of your
  > local network operations, it may deny the operation immediately, before the
  > user has responded to the alert. To handle this smoothly, use an API that
  > supports waiting for connectivity, like Network framework or URL Loading
  > System with `waitsForConnectivity` enabled. If you can't use one of these
  > preferred APIs, add appropriate retry logic.

  `ConnectionSupervisor`'s exponential backoff already satisfies the "add
  appropriate retry logic" clause. Setting
  `URLSessionConfiguration.waitsForConnectivity = true` is the belt to that
  suspenders. **Do not surface the first failure as a hard error** — it will
  routinely be the permission prompt, not a bad address.
- **A backgrounded app is silently denied:**

  > If an iOS app is in the background and performs a local network operation
  > while its Local Network privilege is undetermined, the system denies that
  > operation **without presenting the local network alert**. The system doesn't
  > record that decision. If, later on, the app performs a local network
  > operation while in the foreground, the system presents the alert to the user
  > as if this were the first local network operation.

  So a background-refresh-driven first connection can never win the permission.
  The first LAN connection must happen in the foreground.
- **There is no API to raise the alert on demand** (Apple radar FB8711182).
  TN3179 gives a documented workaround — `connect(2)` a UDP socket to a
  link-local IPv6 address, which trips the check without sending traffic — and
  supplies sample code. Useful if we ever want to ask for permission during
  onboarding rather than at first connect.
- **The Simulator does not implement local network privacy.** All of this must be
  tested on a real device.
- iOS 18 had a state-desync bug (FB14321888) **fixed in iOS 18.6**. If permission
  behaves erratically on an iOS 18.x device, check the point release before
  debugging our code.

---

## 3. App Transport Security and cleartext `ws://`

### 3.1 ATS applies to us

> ATS requires that all HTTP connections made with the URL Loading System —
> typically using the `URLSession` class — use HTTPS.

and

> ATS doesn't apply to calls your app makes to lower-level networking interfaces
> like the Network framework or CFNetwork. In these cases, you take
> responsibility for ensuring the security of the connection.

— [`NSAppTransportSecurity`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity),
[Preventing Insecure Network Connections](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)

`URLSessionWebSocketTask` is a `URLSessionTask` on a `URLSession`, so ATS applies
to it. (Rewriting the transport on `NWConnection` would sidestep ATS entirely —
but it would *not* sidestep local network privacy, which TN3179 says is enforced
"deep in the networking stack … includ[ing] Network framework, BSD Sockets".
Dropping ATS to dodge a permission prompt buys nothing and loses the URL Loading
System.)

### 3.2 On iOS 17+, connecting to a bare IP is blocked by default

This is the second consequential finding, and it is newer than most guidance
online:

> In iOS 9 and macOS 10.11, ATS disallows connections to [unqualified domains,
> `.local` domains, and IP addresses]. …
>
> In iOS 10 through iOS 16, iPadOS 13.1 through iPadOS 16, and macOS 10.12
> through macOS 13, ATS allows all three of these connections by default …
>
> **In iOS 17, iPadOS 17, and macOS 14, ATS no longer allows connections to IP
> addresses by default.** Add individual IP addresses and classless inter-domain
> routing (CIDR) ranges in the `NSExceptionDomains` dictionary.

— [`NSAllowsLocalNetworking`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)

The map's floor is **iOS 17**, so this is squarely on the wrong side of the line.
`ws://192.168.1.42:4312/v1` and `ws://100.101.102.103:4312/v1` are both blocked
by default on every OS version we support — not because of cleartext, but because
they are IP literals.

`NSAllowsLocalNetworking` is the intended remedy:

> The local networking exception tells newer versions of the OS to ignore the
> arbitrary loads key, and enable access to unqualified domains, `.local`
> domains, and IP addresses that they would otherwise restrict.

Note that `NSAllowsLocalNetworking` suppresses `NSAllowsArbitraryLoads` on iOS 10
and later — that is the documented, intended interaction, and the reason to set
both if you also care about pre-iOS-10 (we don't):

> In iOS 10 and later and macOS 10.12 and later, the value of the
> `NSAllowsArbitraryLoads` key is ignored — and the default value of `NO` used
> instead — if any of the following keys are present … `NSAllowsLocalNetworking`.

Apple even suggests setting it as a statement of intent:

> While ATS doesn't block local loads by default in newer versions of the OS,
> consider setting `NSAllowsLocalNetworking` to `YES` as a declaration of intent,
> if appropriate, even if you don't support older OS versions.

### 3.3 Exception domains can now be IP addresses and CIDR ranges

Contrary to the long-standing folklore that exception domains must be DNS names:

> Use a DNS domain name, IP address, or range of IP addresses — In iOS 17,
> iPadOS 17, and macOS 14, you can use an IPv4 address, for example
> `192.168.42.63`, or an IPv6 address, for example `2001:db8:12::34`. You can
> also use a classless inter-domain routing (CIDR) range, for example
> `2001:db8:12::/48`.

— [`NSExceptionDomains`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)

With a critical asymmetry:

> If you exclude a DNS domain name and your app contacts a host by IP address,
> the ATS exclusion for the domain name doesn't apply to the connection even if a
> DNS query for the domain name would resolve to the IP address. If you exclude
> an IP address and your app contacts a host by DNS name that resolves to that IP
> address, the ATS exclusion for the IP address doesn't apply to the connection.

Exceptions match **the literal string in the URL**, not the resolved host. Since
the daemon address is user-entered and arbitrary, we cannot enumerate it ahead of
time. Other rules: lowercase only, no port number, no wildcards (use
`NSIncludesSubdomains`), and a per-domain dictionary makes ATS ignore *all*
global keys for that domain — even if the dictionary is empty.

### 3.4 What App Review demands as justification

> Adding certain ATS exceptions to your app's `Info.plist` file requires you to
> provide justification, and might trigger additional App Store review for your
> app. Exceptions that require justification are:
>
> - Arbitrary connection exceptions (`NSAllowsArbitraryLoads`)
> - Media streaming exceptions (`NSAllowsArbitraryLoadsForMedia`)
> - Web content loads (`NSAllowsArbitraryLoadsInWebContent`)
> - Per-domain nonsecure connections (`NSExceptionAllowsInsecureHTTPLoads`)
> - Per-domain minimum TLS version (`NSExceptionMinimumTLSVersion`)

— [Preventing Insecure Network Connections](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)

`NSAllowsArbitraryLoads` carries a standing warning of its own:

> You must supply a justification during App Store review if you set the key's
> value to `YES`.

**`NSAllowsLocalNetworking` is conspicuously absent from the justification list.**
That is the whole ballgame: the narrow key we need is the one Apple does not ask
you to defend. Among the sanctioned justification examples, the closest fit is

> The app must support connecting to devices that cannot be upgraded to use
> secure connections, and that must be accessed using public host names.

which is a poor fit for us anyway (our host names are not public), reinforcing
that we should not be reaching for the broad key.

### 3.5 Recommended configuration

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
<key>NSLocalNetworkUsageDescription</key>
<string>Shidou connects to the Shidou daemon running on your Mac.</string>
```

That is the minimal, review-safe configuration. It unblocks IP literals,
unqualified names, and `.local` names on iOS 17+; it requires no App Review
justification; and it does not weaken ATS for any public host the app might
contact later.

Two things it does **not** do, both of which matter:

- It does not make cleartext safe. The daemon token travels in-band in the WS
  hello (`crates/shidou-core/src/server.rs:544`), so on `ws://` it is on the wire
  in plaintext. `DaemonEndpoint.isInsecureRemote` already identifies this case;
  the UI should say so plainly.
- **The daemon has no TLS server today.** `crates/shidou-daemon/src/main.rs:18`
  binds a plain `TcpListener`; the only TLS in the tree is outbound
  (`rustls-tls-native-roots` in `crates/shidou-client`). So "just use `wss://`"
  is not currently an option — it is daemon work. And a self-signed `wss://`
  would be *worse* under ATS than cleartext: ATS demands a CA chain to a trusted
  anchor, so a self-signed cert fails default server trust evaluation, and
  > When ATS is enabled, you can no longer loosen trust evaluation requirements
  > that way, but you can still tighten them.

  Overriding trust for a self-signed cert means disabling ATS for that host,
  which lands us back on `NSExceptionAllowsInsecureHTTPLoads` /
  `NSAllowsArbitraryLoads` — the keys that *do* require justification. **Prefer
  cleartext-over-Tailscale (already encrypted by WireGuard at the transport
  layer) to self-signed TLS.**

This yields a clean security story to tell a reviewer and a user: *Tailscale is
the recommended transport and is encrypted end to end; plain LAN is offered for
convenience and is labelled insecure.*

---

## 4. Background execution: the WebSocket does not survive

### 4.1 Apple's answer is a flat no

Asked directly whether WebSocket connections can "continue to operate seamlessly
when the iOS app is in the background or when the device is locked", Apple's DTS
engineer replied:

> That's not possible. I recommend that you start with iOS Background Execution
> Limits then post back here with your remaining questions.

— [Apple Developer Forums thread 745182](https://developer.apple.com/forums/thread/745182)

The documentation agrees from several directions:

> Apps don't normally receive any extra execution time after they enter the
> background.

> When your app is in the background, it should do as little as possible, and
> preferably nothing. If your app was previously in the foreground, use the
> background transition to stop tasks and release any shared resources.

and, in the checklist of things to do on backgrounding:

> Unregister from Bonjour services and close any listening sockets associated
> with them.

— [Preparing your UI to run in the background](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background)

Background `URLSession` is not a way out. Apple's own taxonomy is explicit about
which task types survive:

> - **Upload tasks** are similar to data tasks, but they also send data (often in
>   the form of a file), and **support background uploads while the app isn't
>   running**.
> - **Download tasks** retrieve data in the form of a file, and **support
>   background downloads and uploads while the app isn't running**.
> - **WebSocket tasks** exchange messages over TCP and TLS, using the WebSocket
>   protocol defined in RFC 6455.

— [`URLSession`](https://developer.apple.com/documentation/foundation/urlsession)

> Background sessions let you perform **uploads and downloads** of content in the
> background while your app isn't running.

WebSocket tasks are the one type with no background clause. A
`URLSessionConfiguration.background` session is documented as "a configuration
object suitable for **transferring data files** while the app runs in the
background", and it "causes the system to perform **upload and download tasks**
in a separate process."

**Conclusion: a live `URLSessionWebSocketTask` cannot be kept alive across
suspension.** Plan for the connection to die every time the app leaves the
foreground for more than a few moments, and treat surviving longer as luck.

`beginBackgroundTask(expirationHandler:)` buys a grace period for finishing work,
not for staying connected:

> This method requests additional background execution time for your app. Call
> this method when leaving a task unfinished might be detrimental to your app's
> user experience. … Apps running background tasks have a finite amount of time
> in which to run them. (You can find out the maximum background time available
> using the `backgroundTimeRemaining` property.) If you don't call
> `endBackgroundTask(_:)` for each task before time expires, **the system kills
> the app**.

Apple documents no fixed number — read `backgroundTimeRemaining` rather than
hard-coding the ~30s figure that circulates.

### 4.2 The options that actually exist

**Background App Refresh (`BGAppRefreshTaskRequest`).** Opportunistic, not
scheduled: "A request to launch your app in the background to execute a short
refresh task." Requires the `fetch` `UIBackgroundModes` capability. Hard capacity
limit:

> There can be a total of 1 refresh task and 10 processing tasks scheduled at any
> time. Trying to schedule more tasks returns `tooManyPendingTaskRequests`.

— [`BGTaskScheduler.submit(_:)`](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/submit(_:))

Apple never promises a frequency; the user can disable Background App Refresh
system-wide or per app. Fine for "warm the cache so the app opens current",
useless for "keep the transcript live."

**Silent/background push (`content-available: 1`).** Explicitly best-effort:

> The system treats background notifications as low priority: you can use them to
> refresh your app's content, but **the system doesn't guarantee their delivery**.
> In addition, the system **may throttle** the delivery of background
> notifications if the total number becomes excessive. The number of background
> notifications allowed by the system depends on current conditions, but **don't
> try to send more than two or three per hour**.

> Your app has **30 seconds** to perform any tasks and call the provided
> completion handler.

> - When the system receives a new background notification, it discards the older
>   notification and only holds the newest one.
> - If something force quits or kills the app, the system discards the held
>   notification.
> - If the user launches the app, the system immediately delivers the held
>   notification.

— [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

Two or three per hour is nowhere near a streaming cadence. Background push is a
**nudge**, not a transport.

**VoIP push / PushKit.** Ruled out by 2.5.4 (background modes only for their
intended purposes) and by the `voip` push type's own definition: "The push type
for notifications that provide information about an incoming Voice-over-IP (VoIP)
call." Shidou has no calls. Do not go here.

**`BGContinuedProcessingTask` (iOS 26+)** is the one genuinely new option and is
worth a look later:

> On iOS and iPadOS, apps can execute long-running jobs using the Continuous
> Background Task (`BGContinuedProcessingTask`), which enables your app's
> critical work that can take minutes or more, to complete in the background if a
> person backgrounds the app before the job completes.
>
> Unlike other `BGTask` subclasses, `BGContinuedProcessingTask` **starts in the
> foreground**. In addition, your app needs to run the task **only in response to
> someone's action, such as tapping a button**. … In the background, continuous
> background tasks can also **use the network** …
>
> When the system runs a continuous background task and a person backgrounds the
> app, the system keeps them informed of the task's progress through a system
> interface. … people can cancel a continuous background task if they desire.

— [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)

The shape fits surprisingly well: the user taps Send, the agent turn runs, the app
is backgrounded, and the task keeps the connection up with a user-visible,
user-cancellable Live Activity. But it is **iOS 26+** against a **iOS 17** floor,
it only covers user-initiated turns (not idle listening), and the user can kill
it. Treat it as a future enhancement, not the v1 plan.

### 4.3 The design that follows: reconnect-on-foreground with cursor replay

This is what the codebase already does, and it is the right answer:

1. On `sceneWillEnterForeground` / `sceneDidBecomeActive`, call
   `ConnectionSupervisor.retryImmediately()` (`ConnectionSupervisor.swift:65`),
   which is already documented as the "Foreground/network-change hook."
2. Reconnect carries replay cursors (`ConnectionSupervisor.swift:76,135`), so the
   daemon replays journaled events past each cursor after the handshake.
3. The `.reconnected(DaemonHello)` event already tells consumers to "re-attach
   sessions and refetch task state" (`ConnectionSupervisor.swift:28`).

**One gap this research surfaces.** The daemon's journal is a bounded in-memory
ring of `MAX_REPLAY_EVENTS_PER_SESSION = 4096` events per session
(`crates/shidou-core/src/server.rs:31,231`). A phone backgrounded through a long
agent run will overflow it, and the cursor will point past the front of the ring.
The client must **detect a cursor the daemon can no longer honor and fall back to
a full refetch** rather than silently rendering a transcript with a hole in it.
Worth confirming the daemon signals this case rather than replaying from whatever
is left.

Also note that a **visible-but-inactive** scene (iPad Split View / Stage Manager,
or a system alert on top) is *not* suspended — UIKit distinguishes
`sceneWillResignActive` from `sceneDidEnterBackground`, and each scene has its own
lifecycle. Do not tear down the connection on mere deactivation; wait for actual
backgrounding.

---

## 5. If notifications are ever wanted: what APNs requires server-side

This section informs [#8, notifications strategy](https://github.com/noelrohi/shidou/issues/8).

### 5.1 The mechanics

- **Transport:** HTTP/2 with TLS 1.2 or later, POST to
  `https://api.push.apple.com:443/3/device/<token>` (production) or
  `api.sandbox.push.apple.com` (development). Port 2197 also works. Payload is
  JSON, uncompressed, **max 4 KB**.
- **Auth, token-based (preferred):** request an **APNs authentication token
  signing key** from the developer account, receiving a 10-character Key ID and a
  `.p8` file. Sign an ES256 JWT with header `{alg, kid}` and claims `{iss (Team
  ID), iat}`, send as `authorization: bearer <jwt>`. Refresh **no more than once
  every 20 minutes and no less than once every 60 minutes**; APNs returns
  `ExpiredProviderToken (403)` for a token older than an hour.
- **Auth, certificate-based:** a TLS client certificate presented at connection
  setup; supports only a subset of push types, and needs renewal before expiry.
- **Required headers:** `apns-topic` (the bundle ID for `alert` and `background`
  types), `apns-push-type`, `apns-priority`, plus optional `apns-expiration`,
  `apns-collapse-id`, `apns-id`. For background pushes: `apns-push-type:
  background` and `apns-priority: 5` — *"Using priority 10 is an error."*
- **Device tokens:** obtained per launch via
  `UIApplication.registerForRemoteNotifications()` →
  `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
  > You can't use the same device token for more than one app, even when the apps
  > are on the same device.

  Re-fetch every launch; never treat as permanently stable.
- **Delivery is best-effort:** APNs may reorder, may store for up to 30 days,
  stores **only one notification per bundle ID**, and may throttle.

Sources:
[Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns),
[Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).

### 5.2 The architectural problem for a BYO-daemon app

**The signing key is a per-developer-account secret, and Apple says so:**

> Secure both pieces of information carefully. You use the authentication token
> signing key to encrypt your JSON tokens, so **this key must remain private to
> prevent anyone else from generating those tokens**.
>
> If you suspect that you may have a compromised authentication token signing
> key, revoke it and request a new one.

> APNs doesn't support authentication tokens from multiple developer accounts
> over a single connection.

Pushing from the user's own daemon would mean shipping our APNs `.p8` (or a push
certificate) to every user's Mac. That is exactly the compromise Apple's text
warns about, and a single leak forces a revocation that breaks push for everyone.
There is no self-hostable APNs; the only path to a device is Apple's servers,
authenticated as *us*.

This leaves exactly three options for #8, and the tradeoff is unavoidable:

1. **A relay we operate.** The daemon calls our small service, which holds the
   `.p8` and forwards to APNs. Technically clean, but the map's charting decisions
   say *"Reachability is LAN + Tailscale; no hosted relay"* and list a hosted
   relay under **Out of scope**. This would reopen that decision — and it means
   session metadata transits a server we run, which is contrary to the product's
   whole premise.
2. **Scoped-key distribution.** Token-specific keys exist ("You can create a
   maximum of 200 keys for Sandbox and 200 for Production"), but they are still
   per-team secrets and cap out well below any user count. Not a real answer.
3. **Local notifications only.** `UNUserNotificationCenter` can fire without a
   server, but only from triggers the *device* evaluates — time, calendar,
   location — or from the app while it is running. It **cannot** be triggered by
   a remote event. In practice this means: notify at the moment the app is
   foregrounded or briefly alive in the background and observes the turn
   finishing. That is real but weak, and it will miss the exact case users want
   (phone in pocket, turn completes).

**Bottom line for #8: with no relay, remote push is architecturally unavailable,
and the honest v1 answer is local notifications while the app is alive plus
accurate catch-up on foreground.** If "notify me when the agent finishes" is a
must-have, it forces a relay decision, and that belongs on the map, not in a
notifications ticket.

---

## 6. TestFlight mechanics

### 6.1 Encryption export compliance

> When you submit your app to TestFlight or the App Store, you upload your app to
> a server in the United States. If you distribute your app outside the U.S. or
> Canada, your app is subject to U.S. export laws, regardless of where your legal
> entity is based.

> Add the `ITSAppUsesNonExemptEncryption` key to your app's information property
> list with a Boolean value that indicates whether your app uses encryption. Set
> the value to `NO` if your app — including any third-party libraries it links
> against — doesn't use encryption, **or if it only uses forms of encryption that
> are exempt** from export compliance documentation requirements.

> Typically, the use of encryption that's built into the operating system — for
> example, when your app makes HTTPS connections using `URLSession` — is exempt
> from export documentation upload requirements, whereas the use of proprietary
> encryption is not.

> If your app uses exempt forms of encryption, you might alternatively be
> required to submit a year-end self-classification report to the U.S.
> government.

— [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)

For TestFlight specifically:

> Specify encryption use for your build to avoid the beta being marked as
> **Missing Compliance**. Answer the export compliance questions or attach
> previously approved documentation in the TestFlight section.
>
> If documentation isn't required, click Save. You can indicate that your app
> doesn't use encryption or is exempt from documentation by specifying encryption
> settings in the app's `Info.plist` file in Xcode.

— [Provide export compliance information for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds)

**For Shidou for iOS:** the app uses `URLSession` over `wss://` (OS-provided TLS)
and Keychain for the token — both OS-provided. Set
`ITSAppUsesNonExemptEncryption = NO` in `Info.plist` and every build clears
compliance automatically without the per-build questionnaire.

Two caveats, and one is ours specifically:

- **Cleartext `ws://` is not an encryption question at all.** Not using encryption
  is trivially exempt. It creates no export issue; it creates the §3 issue.
- If ShidouKit ever ships its **own** crypto (rolling our own token derivation, a
  bundled TLS stack rather than the system one, at-rest encryption beyond
  Keychain), the `NO` answer becomes wrong and documentation is required.
- **France:** a separate French encryption declaration applies only when
  distributing on the App Store in France; the controlled categories are Secure
  Storage, Secure Communications, and Security/Anti-Virus. TestFlight-only
  distribution does not reach this, but a future App Store release plausibly
  does — Shidou is arguably "Secure Communications."
  ([overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/))

### 6.2 Beta App Review, and what it checks

> When you add the first build of your app to a group, the build gets sent to App
> Review **to make sure it follows the App Review Guidelines**. A review is
> required only for the first build. Subsequent builds may not require a full
> review.

> The first build you submit requires a full review, but later builds for the
> same version might not.

> You can only have one build of each version in review at a time. Once that
> build is approved, you can submit additional builds.

> You can submit up to **six builds** for TestFlight App Review within a 24-hour
> period.

> To create an external group for external testing, you must first create an
> internal group for internal testing.

— [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/),
[Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)

Crucially: **Beta App Review applies the App Review Guidelines.** TestFlight is
not a guidelines-free zone. Everything in §1 and §3.4 applies to the very first
external build — so the reviewer-access problem (§1.2) must be solved *before*
external TestFlight, not before App Store submission.

**Internal testing requires no review**, so the fastest real-device loop is
internal-only: up to 100 App Store Connect users with access to the content.

### 6.3 Limits and required metadata

| Item | Value | Source |
| --- | --- | --- |
| External testers | up to 10,000 | TestFlight overview |
| Internal testers | up to 100 App Store Connect users with access | TestFlight overview |
| Build expiry | **90 days** | TestFlight overview |
| Beta review needed | External only; not for internal | TestFlight overview |
| Builds submittable per 24h | 6 | Invite external testers |

Required test information before external testing:

> In the Beta App Description text field, enter a description of your beta
> version. **This field is required.**

plus a **Feedback Email** (the reply-to on tester invitations) and Contact
Information. Optionally, approved screenshots and app category can be shown in the
invite.
([Provide test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/))

### 6.4 Privacy policy

Guideline **5.1.1(i)** is unambiguous about the App Store:

> All apps must include a link to their privacy policy in the App Store Connect
> metadata field and within the app in an easily accessible manner. The privacy
> policy must clearly and explicitly:
> - Identify what data, if any, the app/service collects, how it collects that
>   data, and all uses of that data.
> - Confirm that any third party with whom an app shares user data … will provide
>   the same or equal protection of user data …
> - Explain its data retention/deletion policies and describe how a user can
>   revoke consent and/or request deletion of the user's data.

The App Store Connect Help pages for TestFlight test information do **not** list a
privacy policy URL among the required TestFlight fields. Since Beta App Review
applies the App Review Guidelines, and 5.1.1 says "all apps", **write one anyway**
— it is cheap, and it is a trivially avoidable rejection.

The story is genuinely easy here: the app talks only to a daemon the user runs, on
a network the user controls; there is no analytics, no third-party SDK, no
first-party server. Say exactly that.

### 6.5 Review turnaround

Apple publishes one figure, for App Review generally:

> On average, 90% of submissions are reviewed in less than 24 hours.

— [App Review](https://developer.apple.com/distribute/app-review/)

**Apple publishes no separate turnaround statistic for TestFlight Beta App
Review.** Plan around the general figure and do not promise a date.

---

## What this changes for the map

1. **Background WebSockets are not viable — Apple DTS says "That's not possible."**
   The map's "App lifecycle: background reconnect, replay-cursor resume when the
   app returns to foreground" line is not merely the pragmatic choice, it is the
   *only* choice. Remove any assumption of staying live in the background.
2. **`NSAllowsLocalNetworking` is mandatory, not optional, at our iOS 17 floor** —
   because ATS blocks IP-literal connections outright on iOS 17+, independent of
   cleartext. Without it, `ws://192.168.x.x` fails on every supported OS version.
3. **Tailscale sidesteps the local-network permission prompt entirely** (VPN
   interfaces are excluded from the definition of a local network). This is a real
   argument for making Tailscale the recommended path in onboarding rather than
   merely a supported one — fewer prompts, encrypted transport, better review
   story. *Confirm on device.*
4. **Push notifications are architecturally blocked without a relay.** The APNs
   signing key cannot ship to users' daemons. Ticket #8 should treat "no remote
   push in v1" as the default and escalate the relay question to the map if remote
   push turns out to be a must-have.
5. **Beta App Review applies the full App Review Guidelines**, so the
   reviewer-access problem must be solved before the first external TestFlight
   build. Stand up a publicly reachable demo daemon with TLS, or prepare a demo
   video plus detailed reviewer notes.
6. **The daemon has no TLS server**, so `wss://` is daemon work, not an app
   setting — and self-signed TLS would be *worse* under ATS than cleartext. Add
   this to the map's fog if `wss://` is wanted.
7. **The 4096-event replay journal is a correctness risk** for the
   reconnect-on-foreground design; a phone backgrounded through a long run can
   overflow it. The client needs an explicit "cursor too old, refetch everything"
   path.

---

## Flagged as unverified

- **Tailscale specifically.** TN3179's definition excludes VPN interfaces, and
  Tailscale is a packet-tunnel Network Extension, so the inference is strong — but
  Apple never names Tailscale, CGNAT `100.64.0.0/10`, or `*.ts.net`. Test on a
  real device before relying on it in onboarding copy.
- **Whether `NSAllowsLocalNetworking` covers a non-local IP literal.** Apple says
  it enables "unqualified domains, `.local` domains, and IP addresses that they
  would otherwise restrict", without qualifying *which* IP addresses. If a
  Tailscale `100.x` literal is treated as non-local, the iOS 17 IP-literal
  restriction might still apply to it. Not resolvable from the docs — test it.
- **App Privacy ("nutrition label") questionnaire for TestFlight external
  testing.** Not confirmed either way from App Store Connect Help.
- **Privacy policy URL as a hard TestFlight requirement.** Guideline 5.1.1 says
  "all apps"; the TestFlight help pages do not list it among required fields. The
  recommendation to write one is prudence, not a verified requirement.
- **Beta App Review turnaround.** No Apple-published figure exists.
- **The exact `beginBackgroundTask` grace period.** Apple documents no number and
  directs you to `backgroundTimeRemaining`. The widely repeated ~30s is not
  sourced here.
- **Background App Refresh frequency.** Apple documents no rate, only that a
  single refresh task may be pending at a time.
- **Whether a `webSocketTask` on a background `URLSession` throws, asserts, or
  silently misbehaves.** The DTS "not possible" answer and the absence of
  WebSocket from every background-capable task list are conclusive on the
  *outcome*; the precise failure mode is not documented.
