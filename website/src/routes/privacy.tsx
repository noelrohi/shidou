import { createFileRoute } from '@tanstack/react-router'
import type { ReactNode } from 'react'

// App Review 5.1.1 wants a privacy policy reachable at a stable URL and from
// inside the app, so this route is linked from the iOS Settings stack as well
// as the site footer. Keep desktop analytics, remote-client storage, demo
// logging, and website analytics distinct: they have different data paths.
export const Route = createFileRoute('/privacy')({
  head: () => ({
    meta: [
      { title: 'Privacy — Shidou' },
      {
        name: 'description',
        content:
          'What Shidou stores and sends: local task data, desktop usage analytics, saved connection credentials, demo logs, and website analytics.',
      },
    ],
  }),
  component: Privacy,
})

const LAST_UPDATED = '5 September 2026'
const CONTACT = 'testflight@shidou.dev'

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} className="border-t px-5 py-12 md:px-10">
      <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
      <div className="mt-4 max-w-[42rem] space-y-4 text-[15px] leading-relaxed text-muted-foreground">
        {children}
      </div>
    </section>
  )
}

function Term({ children }: { children: ReactNode }) {
  return <span className="font-medium text-foreground">{children}</span>
}

function Privacy() {
  return (
    <div className="min-h-dvh antialiased">
      <div className="mx-auto w-full max-w-[1100px] border-border/70 md:border-x">
        <header className="flex h-16 items-center px-5 md:px-10">
          <a href="/" className="flex items-center gap-2.5">
            <img src="/app-icon.png" alt="" className="size-8 rounded-[6px]" />
            <span className="text-[15px] font-semibold tracking-tight">Shidou</span>
          </a>
        </header>

        <main>
          <section className="px-5 pt-10 pb-12 md:px-10 md:pt-16">
            <div className="font-mono text-[11px] tracking-[0.14em] text-muted-foreground/80 uppercase">
              Privacy
            </div>
            <h1 className="mt-3 text-3xl font-semibold tracking-[-0.03em] text-balance md:text-[2.6rem] md:leading-[1.08]">
              Privacy policy
            </h1>
            <p className="mt-5 max-w-[42rem] text-[17px] leading-relaxed text-pretty text-muted-foreground">
              Shidou connects to agents through a daemon on your own computer, without a
              Shidou account. Configured desktop release builds send usage analytics unless
              you opt out. This page covers the{' '}
              <Term>apps</Term>, the optional <Term>demo server</Term>, and this{' '}
              <Term>website</Term>.
            </p>
            <p className="mt-4 font-mono text-xs text-muted-foreground">
              Last updated {LAST_UPDATED}
            </p>
          </section>

          <Section id="apps" title="1. The apps">
            <p>
              This covers the Desktop Client for macOS, Windows, and Linux, the iOS Client
              for iPhone and iPad delivered through TestFlight, and the Browser Client.
              When connected to your own daemon, these apps send prompts to that daemon
              and its providers, not to a Shidou-hosted agent service. The optional demo
              and desktop usage analytics are described separately below.
            </p>
            <p>
              <Term>Local storage.</Term> Projects, tasks, transcripts, tool activity,
              provider session IDs, and Git checkpoints are stored on the computer running
              your daemon and shared with connected clients. On iPhone and iPad, the app
              saves the paired daemon's addresses and display name, and stores its access
              token in the iOS <Term>Keychain</Term>.
            </p>
            <p>
              <Term>Browser credentials.</Term> The Browser Client saves your daemon's
              address and access token in browser <Term>sessionStorage</Term> by default.
              With Remember enabled, it uses <Term>localStorage</Term> instead, so those
              credentials persist across browser sessions until cleared. These credentials
              are not stored in the iOS Keychain. Use the browser app's Forget daemon action or
              clear its site data to remove them.
            </p>
            <p>
              <Term>Where your prompts go.</Term> Your daemon drives coding-agent
              command-line tools installed on its computer, under your own logins and
              configuration. What you type is passed to whichever agent you chose, and
              that agent communicates with its provider under that provider's privacy
              policy. Shidou also stores the task transcript locally on the daemon's
              computer.
            </p>
            <p>
              <Term>Remote connections.</Term> The iOS and Browser Clients connect to the
              daemon address you configure, rather than through a Shidou relay. This can
              be over your local network or Tailscale. Transport protection depends on the
              address and network: a plain ws:// connection does not itself encrypt traffic
              or the access token. iOS requests local-network permission to reach local
              daemon addresses.
            </p>
            <p>
              <Term>Camera.</Term> The iPhone and iPad app asks for camera access for one
              purpose: scanning the pairing code your desktop app displays. Frames are processed on
              device to read the code and are never stored or transmitted.
            </p>
            <p>
              <Term>Desktop usage analytics.</Term> Release builds with an analytics
              endpoint and website ID configured at build time send usage events to that
              endpoint when sharing is enabled. Sharing defaults to enabled. Debug builds
              and builds without that configuration do not send these events. The iOS and
              Browser Clients do not use this desktop analytics worker.
            </p>
            <p>
              Events include launch and feature usage, task and project counts, provider
              and model names, turn numbers, workspace type, attachment counts, whether
              input is present, turn outcomes and durations, permission decisions, rewinds,
              and forks. They include app version, OS, architecture, language, and a
              persistent, randomly generated analytics ID stored on your device. They do
              not include prompt text, transcript text, file contents, or access tokens.
              Like other network requests, they expose your IP address to the receiving
              host.
            </p>
            <p>
              Turn off <Term>Share anonymous usage data</Term> in{' '}
              <Term>Settings → General</Term> to stop sending these events. The setting
              takes effect immediately and is saved. You can also launch the desktop app
              with <Term>SHIDOU_DISABLE_ANALYTICS=1</Term>. The label does not mean events
              are unlinkable: the persistent analytics ID links events from the same
              installation.
            </p>
            <p>
              <Term>Update checks.</Term> macOS uses Sparkle to check{' '}
              <code className="font-mono text-[13px] text-foreground">
                releases.shidou.dev/appcast.xml
              </code>
              . Windows checks an architecture-specific appcast on the same host and
              verifies the downloaded installer's signature. These requests expose your
              IP address and request metadata to the release host. Automatic checks can
              be controlled in Settings; manual checks remain available. Linux has no
              in-app updater: rerunning the install script requests the release manifest
              and archive.
            </p>
          </Section>

          <Section id="demo" title="2. The demo server">
            <p>
              The iPhone and iPad app offers a <Term>Try the demo</Term> option so you can
              see the app work without a computer running Shidou. Tapping it connects
              you to a demo server we operate at{' '}
              <code className="font-mono text-[13px] text-foreground">demo.shidou.dev</code>
              . Connecting to the demo is your choice; unlike your own daemon, it receives
              demo messages on a server we operate.
            </p>
            <p>
              The demo server is a fixture. It replays a scripted session, runs no code,
              touches no repository, and holds no credentials of any kind. It has no
              account system, so nothing it receives is tied to an identity.
            </p>
            <p>
              <Term>What we log there.</Term> Messages you type into the demo are sent to
              that server, and they appear in its server logs along with your IP address
              and the time of the request. We keep those logs so we can tell whether the
              demo is working and fix it when it is not. They are deleted after{' '}
              <Term>7 days</Term>. We do not sell them, do not share them with anyone, and
              do not use them to train anything.
            </p>
            <p>
              Because those messages are logged, please treat the demo as a public place:
              do not paste real code, credentials, or anything else you would not want in a
              server log.
            </p>
          </Section>

          <Section id="website" title="3. This website">
            <p>
              <Term>Analytics.</Term> Production builds of this website load a visit
              analytics script from{' '}
              <code className="font-mono text-[13px] text-foreground">u.egoist.dev</code>
              . Development builds do not load it. Loading the script and sending analytics
              requests exposes your IP address and request metadata to that host. Website
              visit analytics are separate from the desktop usage events described above.
            </p>
            <p>
              <Term>Downloads.</Term> Download links point at our release host and at
              GitHub. Fetching a file makes an ordinary web request to whichever host serves
              it, and that host sees your IP address.
            </p>
          </Section>

          <Section id="children" title="4. Children">
            <p>
              Shidou is a developer tool and is not directed at children under 13. We do not
              knowingly collect information from them.
            </p>
          </Section>

          <Section id="changes" title="5. Changes">
            <p>
              If this policy changes, the date at the top of the page changes with it, and
              the history of every edit is public in the{' '}
              <a
                className="rounded-sm text-foreground underline underline-offset-4 outline-none hover:text-foreground/80 focus-visible:ring-2 focus-visible:ring-ring/60"
                href="https://github.com/noelrohi/shidou"
              >
                Shidou repository
              </a>
              .
            </p>
          </Section>

          <Section id="contact" title="6. Contact">
            <p>
              Questions about this policy, or about anything above, go to{' '}
              <a
                className="rounded-sm text-foreground underline underline-offset-4 outline-none hover:text-foreground/80 focus-visible:ring-2 focus-visible:ring-ring/60"
                href={`mailto:${CONTACT}`}
              >
                {CONTACT}
              </a>
              .
            </p>
          </Section>
        </main>

        <footer className="flex flex-wrap items-center gap-x-4 gap-y-2 border-t px-5 py-10 text-xs text-muted-foreground md:px-10">
          <span className="flex items-center gap-2">
            <img
              src="/app-icon.png"
              alt=""
              className="size-4 rounded-[4px] opacity-80 grayscale"
            />
            © 2026 Shidou
          </span>
          <a
            className="rounded-sm outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/60"
            href="/"
          >
            Home
          </a>
          <a
            className="rounded-sm outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/60"
            href="/LICENSE.txt"
          >
            GPL license
          </a>
          <a
            className="rounded-sm outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/60"
            href="https://github.com/noelrohi/shidou"
          >
            Source code
          </a>
        </footer>
      </div>
    </div>
  )
}
