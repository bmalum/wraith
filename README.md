# Wraith

A Ghost-style publishing platform in Elixir/Phoenix — with **live widgets**
(tiny shared-state mini-apps readers interact with in real time), a **Lua
widget studio**, **one table** for everything (DynamoDB, PostgreSQL or
Aurora DSQL), and an **agent studio**: a Kiro agent on a Lambda MicroVM that writes posts, scripts
widgets and runs the site with you.

```
 reader ──LiveView──▶ Phoenix ──▶ Wraith.Store ──▶ DynamoDB | PostgreSQL | Aurora DSQL (one table)
                         │
                         ├─ Wraith.Widgets ── luerl sandbox (Lua) / Elixir modules
                         │                     state per instance, PubSub fan-out
                         └─ Wraith.Studio ──ACP/WebSocket──▶ Kiro Agent Server (MicroVM)
                                   ▲                              │ MCP over the bridge
                                   └──── Wraith.Studio.Tools ◀────┘
```

## What's in the box

| Area | Where |
|---|---|
| Posts & pages: draft / scheduled / published, slugs, tags, co-authors, revisions, table of contents, related posts, syntax highlighting (Lumis), canonical + OG/Twitter meta, public / members / paid visibility | `Wraith.Content`, `Wraith.Markdown`, `Wraith.Settings`, `Wraith.Accounts` |
| Images: upload from the editor (feature image, inline at the cursor), avatars; local disk or S3 | `Wraith.Uploads`, `Wraith.Uploads.{Local,S3}` |
| Members: double opt-in subscribe, magic-link sign-in, account page, newsletter on/off, self-deletion, CSV export/import, tiered paywall with a public preview above `<!--members-only-->`; Stripe Checkout + customer portal, verified webhook | `Wraith.Members`, `Wraith.Billing`, `WraithWeb.MemberAuth` |
| Mail: welcome, sign-in link, password reset, **publish & send** newsletters with per-member unsubscribe (Local mailbox in dev, SES in prod) | `Wraith.Newsletter`, `Wraith.Mailer`, `Wraith.Tokens` |
| Comments: members comment and reply (one level), reply notifications by mail, live for everyone on the page, moderation in the admin | `Wraith.Comments`, `WraithWeb.Admin.CommentsLive` |
| Staff roles: owner, admin, editor, author, contributor — enforced in every screen and the rail; staff management in Settings | `Wraith.Policy` |
| Embeds: `{{embed url "caption"}}` → YouTube/Vimeo players, X link cards, Open Graph bookmark cards | `Wraith.Embed` |
| Publishing: send-on-publish, scheduled unpublish, test mail, word count, bulk actions, per-tag/author RSS, JSON-LD, per-post noindex | `Wraith.Content`, `Wraith.Newsletter` |
| Analytics (daily views and unique readers per post, top posts, member growth) and an audit log, on the dashboard | `Wraith.Analytics`, `Wraith.Audit` |
| Security: encrypted secrets, rate limiting, session expiry, widget HTML sanitiser, `/health` — see Security notes | `Wraith.RateLimit`, `Wraith.Janitor`, `Wraith.Vault` |
| Search: in-memory inverted index over published posts, `/search` as you type | `Wraith.Search` |
| Author profiles: avatar, bio, socials, password change, reset by mail | `WraithWeb.Admin.{ProfileLive,ResetLive}` |
| Redirects (exact and `/old/*`), navigation picker for pages | `WraithWeb.Redirects`, Settings |
| **MCP server**: every admin action as a tool, posts as resources, at `/mcp` for any agent — Kiro CLI, Claude, Cursor; the studio agent uses the same registry | `Wraith.Tools`, `WraithWeb.McpController`, `Wraith.Kiro.MCP` |
| JSON APIs in Ghost's shape: Content API (read, `?key=`), Admin API (Bearer key or session), Ghost-compatible export and **import of a Ghost site** | `WraithWeb.Api.*`, `Wraith.ApiKeys`, `Wraith.Ghost` |
| Public site: feed, post, tag, author, subscribe, RSS / JSON Feed / sitemap | `WraithWeb.Site.*`, `WraithWeb.FeedController` |
| Themes: **18 themes across 6 layouts** (editorial, list, grid, magazine, minimal, journal), picked in a swatch gallery in Settings; token skins + shared base/layout CSS, light/dark | `WraithWeb.Theme`, `WraithWeb.Theme.Layout`, `WraithWeb.Themes`, `lib/wraith_web/themes/*`, `priv/static/themes/*.css` |
| Admin: setup, login, dashboard, Markdown editor with live preview (widgets live too), posts, tags, members, settings | `WraithWeb.Admin.*` |
| Widgets: behaviour, Lua sandbox, shared live state, built-ins (counter, poll, reactions, countdown, live visitors) | `Wraith.Widgets`, `Wraith.Widgets.Lua`, `priv/widgets/*.lua` |
| Widget studio: write Lua, click the live preview, versions & rollback | `WraithWeb.Admin.WidgetEditorLive` |
| Agent studio: Kiro on a MicroVM, transcript streaming, tool calls, permission prompts | `Wraith.Studio`, `Wraith.Studio.Server`, `Wraith.Studio.Tools`, `WraithWeb.Admin.StudioLive` |
| Kiro runtime (ported from shadow_corp): MicroVM API, ACP client, bridge, MCP | `Wraith.Kiro.*`, `microvm/` |
| Storage: one table; Memory, DynamoDB and SQL (PostgreSQL / Aurora DSQL) adapters | `Wraith.Store`, `Wraith.Store.Keys`, `Wraith.Store.{Memory,Dynamo,SQL}` |

## Run it

```sh
mix setup                       # deps, tailwind/esbuild (codesigns the tailwind binary on macOS)
mix phx.server                  # http://localhost:4000 → /admin/setup creates the owner
```

Dev defaults to the in-memory store (`WRAITH_STORE=memory`), so nothing persists
across restarts. For a real table:

```sh
docker compose up -d                                           # DynamoDB Local (in-memory)
export WRAITH_STORE=dynamo DYNAMO_ENDPOINT=http://127.0.0.1:8000
mix wraith.table                                               # creates `wraith` (idempotent)
mix phx.server
```

Against AWS: `WRAITH_STORE=dynamo AWS_PROFILE=… AWS_REGION=… mix wraith.table`.

PostgreSQL or Aurora DSQL instead — same one-table layout, same `mix wraith.table`:

```sh
docker compose up -d postgres
WRAITH_STORE=postgres DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5434/wraith mix wraith.table
WRAITH_STORE=postgres DATABASE_URL=… mix phx.server

WRAITH_STORE=dsql DSQL_ENDPOINT=<cluster>.dsql.eu-central-1.on.aws AWS_PROFILE=… mix wraith.table
```

DSQL authenticates with an IAM token minted per connection (`dsql:DbConnectAdmin`,
`Wraith.Store.SQL.Token`); the index is created `ASYNC`, a `40001` commit conflict
is retried. All env vars are listed in `.env.example`; `config/runtime.exs` reads them.

### Coming from Ghost

Export your site in Ghost (Settings → Labs → Export) and upload the JSON at
`/admin/integrations` (or `POST /api/admin/db`). Posts (HTML bodies turned into
Markdown), pages, tags, authors (random passwords, reset by mail) and members
come across; existing slugs and emails are skipped. The Content API at
`/api/content/*` answers in Ghost's JSON shape, so front-ends written against
Ghost's Content API need a key swap and little else — widgets appear as
`<div class="wraith-widget" data-widget=… data-props=…>` placeholders.

### Writing

Posts are Markdown (GFM). Drop a widget in on a line of its own:

```
{{widget poll question="Tabs or spaces?" options="Tabs|Spaces" id=tabs}}
{{widget counter label="Readers who agree"}}
{{widget countdown to=2027-01-01 label="Launch"}}
{{widget reactions}}
{{widget live-visitors}}
```

`id=` names the instance so several posts can share one state. The editor
palette inserts shortcodes; the preview runs the real widgets.

### Scripting a widget

`/admin/widgets/new` — a Lua chunk with three functions, a clickable preview
of the unsaved source, and a version per save:

```lua
function init(props) return { claps = 0 } end
function render(state, props, meta)
  return '<button class="w-btn" ' .. wraith.action("clap") .. '>👏 '
      .. wraith.format(state.claps) .. '</button>'
end
function handle(state, event, payload, meta)
  if event == "clap" then state.claps = state.claps + 1 end
  return state
end
```

`meta.visitor` is a stable per-browser id (one vote per reader),
`meta.presence` the readers on the page, `meta.private` this reader's own
table (return it as `handle`'s second value). Helpers: `wraith.action`,
`wraith.escape`, `wraith.format`, `wraith.split`, `wraith.json`,
`wraith.now`, and `wraith.fetch(url)` for hosts the owner allowlists in
Settings (cached 60 s). `tick = 30` at the top re-renders every 30 s. The
sandbox removes `os`/`io`/`require`, cuts a call off after 250 ms, caps the
shared state at 64 KB and sanitises the HTML a widget emits. Elixir widgets
implement `Wraith.Widgets.Widget` and are listed in `Wraith.Widgets.builtin_modules/0`.

## Themes

The public site is a theme, and a theme is two things: a **layout** (its
structure and templates) and a **skin** of design tokens (fonts, palette,
radius, measure). Six layouts ship, each a directory under
`lib/wraith_web/themes/layouts/<layout>/` with a module
(`use WraithWeb.Theme.Layout, name: "<layout>"`) and four HEEx templates —
`layout`, `index`, `post`, and a shared `listing` (tag/author/search). The
`subscribe` and `member` pages, the search box, the mode toggle and social
links are shared by every layout from `WraithWeb.Themes.Shared`.

Each layout carries three skins, so **18 themes ship**:

| Layout | Themes |
|---|---|
| editorial — masthead, lead story, card feed | `paper` (default), `broadsheet`, `gallery` |
| list — dated rows, narrow column | `ink`, `ledger`, `terminal` |
| grid — centred logo, image-first cards | `studio`, `polaroid`, `slate` |
| magazine — hero + sidebar | `review`, `weekend`, `tabloid` |
| minimal — one narrow column | `plain`, `mono`, `zen` |
| journal — dated entries, date in the margin | `diary`, `letters`, `nightshift` |

A theme module is tiny — a name, a layout, a Google Fonts URL and a `tokens`
map:

```elixir
use WraithWeb.Theme,
  name: "broadsheet", label: "Broadsheet", description: "…",
  layout: WraithWeb.Themes.Layouts.Editorial,
  fonts: "https://fonts.googleapis.com/css2?family=Playfair+Display…",
  tokens: %{"--heading" => "'Playfair Display', serif", "--accent" => "#b00020", …}
```

The root layout links `/themes/base.css` (everything the layouts share) and
`/themes/layouts/<layout>.css`, loads the theme's fonts, and inlines the
tokens as CSS variables on `:root`. The widget classes and prose styles come
from `app.css`. Pick a theme in **Settings → Theme** (a gallery of swatches
grouped by layout) or over MCP (`settings_update`, `themes_list`); your site
accent colour overrides the theme's. Dark skins declare `--scheme: dark`, and
light skins get a sensible dark palette from the reader's `prefers-color-scheme`
or the light/dark toggle.

Themes are compiled into the release, by design: no template code is loaded
at runtime. Ghost (Handlebars) theme compatibility would be a second theme
kind on top of this contract; it is not there yet.

## The MCP server

Everything you can do in the admin, an agent can do over MCP. `Wraith.Tools`
is one registry — posts, pages, revisions, publishing and scheduling,
newsletters, tags, authors, members, comments, Lua widgets (docs, test, save,
versions, rollback, live state), uploads, settings, themes, redirects, API
keys, export/import, search — served as an MCP server (Streamable HTTP, JSON)
at `POST /mcp`, and as the studio agent's tool server over the bridge.

Create a key at `/admin/integrations` and point any client at it:

```json
{"mcpServers": {"wraith": {"url": "https://your-site/mcp",
                            "headers": {"Authorization": "Bearer <key>"}}}}
```

```sh
kiro-cli mcp add --name wraith --url https://your-site/mcp --header "Authorization: Bearer <key>"
```

An Admin key gets every tool; a Content key only `site_info`, `posts_list`,
`post_get`, `search`, `tags_list` and `widget_docs`, and those see only
published posts with the paywall applied. Destructive tools carry
`destructiveHint`. `resources/list` exposes the settings, the widget guide
and every post as `wraith://posts/<slug>` (published ones only for a
Content key). The test
`test/wraith_web/mcp_test.exs` drives the whole site lifecycle through the
endpoint and checks the catalogue against the admin's actions.

## The agent studio

`/admin/studio`. Paste a Kiro API key (`ksk_…`, minted at app.kiro.dev; stored
encrypted with `Wraith.Vault`, only ever sent to the studio VM) and wake the
agent. It gets the `wraith` MCP server — `site_info`, `post_*`, `tag_*`,
`widget_docs` / `widget_test` / `widget_save`, `settings_update` — over the
bridge, so no endpoint of this app is exposed and no secret enters the VM.
Tool calls, their input and output, and permission requests show up in the
transcript; you approve or deny in place.

**Offline (default):** with no MicroVM image configured the studio runs the
scripted agent `Wraith.Kiro.ACP.Fake`. It still goes through the real tool
path: `!widget clap` makes it read the docs, `widget_test`, then `widget_save`
a working widget; `!post Hello` drafts a post; `!info` calls `site_info`;
`use a tool` raises a permission request.

**On AWS:** build the MicroVM image once (`microvm/build.sh`, same shim as
shadow_corp: lifecycle hooks and `/bridge` on :8080, KAS on :8082, S3 journal)
and set the four `WRAITH_MICROVM_*` / `WRAITH_JOURNAL_BUCKET` variables it
prints. `Wraith.Kiro.Runtime.MicroVM` then starts a VM on first wake, suspends
it when idle and terminates it after three hours without a word.

## Storage layout

One table, `pk`/`sk`, one index on `gsi1pk`/`gsi1sk` — a DynamoDB table with
a GSI, or a SQL table `items(pk, sk, gsi1pk, gsi1sk, version, data)` with the
item as JSON in `data`. `Wraith.Store` is a small key-value interface
(`get/put/delete/query/transact/batch_get/update`), so the adapters are thin and
the whole suite runs against each of them. The layout is in `Wraith.Store.Keys`:

| entity | pk | sk | gsi1 |
|---|---|---|---|
| site settings | `SITE` | `SETTINGS` | |
| user | `USER#id` | `USER` | `USERS` / email |
| post | `POST#id` | `POST` | `POSTS#status` / `sort_at#id` |
| post by slug | `SLUG#slug` | `POST` | |
| post revision | `POST#id` | `REV#at` | |
| post in tag / by author | `TAG#slug`, `AUTHOR#id` | `POST#sort_at#id` | |
| widget / version / instance state | `WIDGET#slug` / `WSTATE#slug#instance` | `WIDGET` / `VER#n` / `STATE` | `WIDGETS` |
| studio session / transcript | `STUDIO` / `STUDIO#sid` | `SESSION#id` / `MSG#at#seq` | |

Uniqueness (slugs, emails) is a conditional put inside a transaction
(`TransactWriteItems` / `INSERT … ON CONFLICT DO NOTHING` with a row-count check);
`Wraith.Store.update/3` is optimistic read-modify-write on `version`.

## Tests

```sh
mix precommit                                         # warnings-as-errors, unused deps, format, the suite
mix test                                              # 213 tests: in-memory store, fake agent, test mailer
WRAITH_TEST_DYNAMO=http://127.0.0.1:8000 mix test     # the same suite on DynamoDB Local
WRAITH_TEST_POSTGRES=postgres://postgres:postgres@127.0.0.1:5434/wraith_test mix test   # … on PostgreSQL
```

CI (`.github/workflows/ci.yml`) runs all three on every push and pull request.

## Security notes

- **Who may do what** is `Wraith.Policy` (owner, admin, editor, author,
  contributor), checked inside every door: admin LiveViews, the Admin API
  (`@policy` per action, per-post checks, `status`/`author_id` dropped for roles
  that may not set them) and every MCP tool (`Wraith.Tools`, which refuses calls
  with no resolved actor). An Admin API key acts as the owner; a signed-in
  session on the Admin API is read-only (that pipeline has no CSRF token). A
  Content API key reaches only the public read tools.
- **The paywall** is one function, `Content.readable_markdown/2`; the post page,
  feeds, search index, Content API and MCP all go through it. Locked
  posts answer with `"access": false` and the public preview only.
- **Secrets at rest** (the Kiro key, Stripe secret and webhook secret) are
  encrypted with `Wraith.Vault` under `WRAITH_VAULT_KEY` (not `SECRET_KEY_BASE`,
  so cookies can rotate without losing them); only hints are shown or exported.
  Transcripts shown in the studio are scrubbed of key-shaped strings.
- **Tokens**: sign-in, confirmation and reset links are single-use; a reset link
  is bound to the password it replaces, and a password change ends every
  session that predates it.
- **Client IP** for rate limits: `TRUSTED_PROXIES` says how many proxies sit in
  front (1 behind an ALB); the client is that many hops from the end of
  `X-Forwarded-For`. With 0 (the default) only the socket address counts.
- **Rate limits** (`Wraith.RateLimit`, per IP / visitor / address): 5 logins a
  minute, 3 magic links and 3 password resets per 15 min, 5 sign-ups an hour,
  10 comments a minute, 60 searches and 60 widget events a minute, 300 API/MCP
  calls a minute and 20 failed key attempts a minute.
- **Outbound fetches** (widget `wraith.fetch`, bookmark cards, upload-from-URL)
  go through `Wraith.SafeHTTP`: http(s) only, private/loopback/link-local/CGNAT
  addresses refused on every redirect hop, size and time capped.
- **Uploads** are sniffed by magic bytes, not trusted by extension; SVGs with
  scripts, handlers or `javascript:` links are refused, and `/uploads` is served
  with `nosniff` and a sandboxing CSP.
- **Widgets**: Lua runs in a supervised task with a heap cap, a time limit and
  capped output; widget HTML goes through an allowlist sanitiser
  (`Wraith.Widgets.sanitize/1`) and may only send `phx-click="widget"` events.
- **Caching**: public pages are cacheable only when nothing is personalised and
  no cookie is set (`Vary: Cookie`); otherwise `private, no-store`.
- Subscriptions are double opt-in. Stripe webhooks are signature-checked and
  applied once per event id.
- Sessions expire (60 days authors, 180 members); `Wraith.Janitor` deletes
  expired sessions and used-token markers hourly, and DynamoDB tables get a TTL
  on `ttl`.
- Code injection (Settings) is raw HTML by design — only the owner edits it.
- HTTP/2 is disabled in prod (`http_2_options: [enabled: false]`) while bandit
  1.12.5's HTTP/2 advisory (EEF-CVE-2026-105659) has no fixed release.
- `/health` (readiness) and `/health/live` answer `{"status": …}` only; details
  go to the log. Both are exempt from the HTTPS redirect for load balancers.

## Deploy

`Dockerfile` builds a release (`mix phx.gen.release --docker`). Required in prod
(the release refuses to boot without them):

| Variable | What |
|---|---|
| `SECRET_KEY_BASE` | signs cookies and tokens — `mix phx.gen.secret` |
| `PHX_HOST` | the public hostname; every absolute URL (feeds, mail, API) is built from it |
| `WRAITH_VAULT_KEY` | encrypts stored secrets — `mix phx.gen.secret`; changing it makes them unreadable |

Plus a store (`WRAITH_STORE=dynamo` + `WRAITH_TABLE`, `WRAITH_STORE=postgres` +
`DATABASE_URL`, or `WRAITH_STORE=dsql` + `DSQL_ENDPOINT`), `AWS_REGION`, and a
task role allowed to read/write the table (and, for the studio,
`lambda:*MicroVM*` plus the journal bucket). Set `TRUSTED_PROXIES=1` behind a
single load balancer. Run `mix wraith.table` once per environment. Everything
else is in `.env.example`.
