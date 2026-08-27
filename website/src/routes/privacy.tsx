import { createFileRoute } from '@tanstack/react-router'
import type { ReactNode } from 'react'

// App Review 5.1.1 wants a privacy policy reachable at a stable URL and from
// inside the app, so this route is linked from the iOS Settings stack as well
// as the site footer. One page covers all three surfaces on purpose: the app
// runs no analytics, but the site that hosts this page does, and an app-only
// policy claiming "no analytics" would be false where it lives.
export const Route = createFileRoute('/privacy')({
  head: () => ({
    meta: [
      { title: 'Privacy — Shidou' },
      {
        name: 'description',
        content:
          'What Shidou stores, what it sends, and where. The apps have no account, no telemetry, and no Shidou server between you and your agents.',
      },
    ],
  }),
  component: Privacy,
})

const LAST_UPDATED = '27 August 2026'
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
              Shidou runs on your own machines and talks to your own agents. There is no
              Shidou account, no Shidou server in the path, and no telemetry in any of the
              apps. This page covers all three places we could touch your data anyway: the{' '}
              <Term>apps</Term>, the optional <Term>demo server</Term>, and this{' '}
              <Term>website</Term>.
            </p>
            <p className="mt-4 font-mono text-xs text-muted-foreground">
              Last updated {LAST_UPDATED}
            </p>
          </section>

          <Section id="apps" title="1. The apps">
            <p>
              This covers the Shidou desktop app for macOS and Windows and the Shidou app
              for iPhone and iPad. Neither has an account, and neither sends your projects,
              prompts, transcripts, or code to us — we operate no server that could receive
              them.
            </p>
            <p>
              <Term>What stays on your device.</Term> Projects, sessions, transcripts, tool
              activity, provider session IDs, and checkpoints are written to local storage
              on the computer running the desktop app. On iPhone and iPad, the app stores
              the address and display name of the Mac you paired with, and stores that
              Mac's access token in the iOS <Term>Keychain</Term>. Nothing in that list
              leaves your devices except as described below.
            </p>
            <p>
              <Term>Where your prompts go.</Term> The desktop app drives coding-agent
              command-line tools that are already installed on your computer, under your
              own logins. What you type is passed to whichever agent you chose, and that
              agent sends it to its own provider under that provider's privacy policy.
              Shidou is not a party to that exchange and does not copy it anywhere.
            </p>
            <p>
              <Term>The connection between phone and Mac.</Term> The iPhone and iPad app
              connects directly to the Shidou daemon running on your own Mac, over your
              local network or over your Tailscale network. Traffic goes device to device;
              it is not relayed through us. iOS asks for local-network permission the first
              time, and the app uses it only to reach the address you paired with.
            </p>
            <p>
              <Term>Camera.</Term> The iPhone and iPad app asks for camera access for one
              purpose: scanning the pairing code your Mac displays. Frames are processed on
              device to read the code and are never stored or transmitted.
            </p>
            <p>
              <Term>Update checks.</Term> The macOS desktop app checks{' '}
              <code className="font-mono text-[13px] text-foreground">
                releases.shidou.dev/appcast.xml
              </code>{' '}
              for new versions. Like any web request, that reaches our file host with your
              IP address and the app and OS version in the request. It carries no
              identifier for you, and no profile of your system is attached.
            </p>
          </Section>

          <Section id="demo" title="2. The demo server">
            <p>
              The iPhone and iPad app offers a <Term>Try the demo</Term> option so you can
              see the app work without owning a Mac that runs Shidou. Tapping it connects
              you to a demo server we operate at{' '}
              <code className="font-mono text-[13px] text-foreground">demo.shidou.dev</code>
              . This is the only case where the app talks to a server of ours, and it is
              always your choice.
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
              <Term>Analytics.</Term> shidou.dev uses a cookieless, self-hosted analytics
              instance at{' '}
              <code className="font-mono text-[13px] text-foreground">u.egoist.dev</code> to
              count visits. It records the page you viewed, the site that referred you, and
              coarse details of your browser, operating system, screen size, and country.
              It sets no cookies, assigns no persistent identifier, and cannot follow you to
              other sites. There are no ad networks and no cross-site trackers on this
              site.
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
