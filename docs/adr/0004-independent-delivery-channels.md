# Desktop, iOS, Browser, and the website ship as independent channels

Shidou is one repository that delivers four things: the Desktop Client for
macOS, Linux, and Windows with its bundled Daemon, the iOS Client through
TestFlight, the Browser Client as a Cloudflare Worker, and the marketing
website as another Worker. Until now they shared one marketing version in
`Cargo.toml`, one `CHANGELOG.md`, and no record of which commit each had last
delivered. That produced four recurring problems: an agent asked to "ship the
changes" could not tell which channel was meant, every merge redeployed
Workers whose code had not changed, desktop release notes carried iOS-only
bullets, and someone had to work out by hand whether a channel was behind.

We decided that **each channel is its own Delivery Channel** with its own
version line, its own changelog, and its own Delivery Record, and that one
front door, `bun run ship`, chooses the channel and drives it.

## Considered options

- **One version, one release for everything**: the simplest story, but a
  one-line iOS fix would force a desktop release nobody asked for, and the
  Browser Client already deploys on merge with no version at all. Rejected.
- **Separate versions for Desktop and iOS, deployment-based Browser and
  website**: the Desktop and iOS stores each compare versions on their own
  and never see each other, so nothing is gained by keeping them equal, and
  splitting them lets each ship when it is ready. Workers have no user-facing
  version; a successful deployment is their record. Chosen.
- **Infer affected channels from changed paths alone**: cheap, but shared
  code under `crates/shidou-core` and `packages/shidou-client` can reach
  every Client or none, and only the author knows which. Rejected in favor of
  explicit `app:*` labels on every pull request, with CI failing when a path
  that clearly belongs to one app changed without its label.
- **Sort release notes on release day**: the status quo. Rejected in favor of
  one Change Note per user-visible change, written when the change lands,
  with wording for every labeled Client, so a release only folds pending
  notes into its changelog.
- **Support old and new wire protocols side by side**: the safe end state,
  but nothing needs it yet. Deferred; until then a `PROTOCOL_VERSION` change
  is a labeled breaking change that must ship to Desktop, iOS, and Browser
  together, and the tooling refuses a Client whose protocol differs from the
  last Desktop Release unless explicitly forced.

## Consequences

- `Cargo.toml` is the Desktop version. `apps/ios/project.yml` carries the iOS
  App Store marketing version and latest build baseline. Routine TestFlight
  deliveries keep the marketing version and increment the globally ordered
  build number. `bun run ship ios --app-store-version <x.y.z>` changes the
  marketing version only when preparing an App Store update.
- Desktop notes live in `CHANGELOG.md` and iOS notes in `CHANGELOG-ios.md`;
  both are generated from `.changes/` by `bun run ship`. Browser notes are
  saved on the GitHub deployment record and are not yet shown to users.
- A channel counts as shipped only when users or internal testers can
  receive it: a `desktop/v*` tag exists once the GitHub release is published,
  an `ios/v<marketing-version>-build.<build-number>` tag once App Store
  Connect reports that build in internal testing, and a Worker deployment
  once its GitHub deployment status is
  `success`. Drafts, local artifacts, and processing uploads are not shipped.
- Browser and website still deploy automatically on merge to `master`.
  Desktop and iOS ship only on an explicit request, and one such request
  authorizes the whole run through publication.
- Anything that can ship reaches `master` through a pull request carrying
  `app:*` labels and, unless labeled `no-release`, a Change Note. Extra labels
  are allowed; a missing label for a clearly changed app fails CI.
- Plain `v*` tags stop at `v0.2.14`; the Release workflow now answers to
  `desktop/v*`. Older tags remain as history.
