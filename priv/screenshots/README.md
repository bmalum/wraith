# Theme screenshots

A reference capture of every public view in every theme: **18 themes × 10
views = 180 images**, one folder per theme.

Views per theme:

| File | View |
|---|---|
| `home.png` | front page (feed) |
| `post.png` | a full post with live widgets, author card, comments, read-next |
| `post-members.png` | a members-only post showing the paywall for anonymous readers |
| `tag.png` | a tag archive |
| `author.png` | an author profile |
| `search.png` | search results |
| `subscribe.png` | the subscribe form |
| `signin.png` | the member sign-in page |
| `mobile.png` | the front page at 390×844 (iPhone), nav collapsed |
| `mobile-nav.png` | the same with the nav drawer open |

The 18 themes, grouped by their layout:

- **editorial** — `paper`, `broadsheet`, `gallery`
- **list** — `ink`, `ledger`, `terminal`
- **grid** — `studio`, `polaroid`, `slate`
- **magazine** — `review`, `weekend`, `tabloid`
- **minimal** — `plain`, `mono`, `zen`
- **journal** — `diary`, `letters`, `nightshift`

## Regenerating

Requires Google Chrome and Node. From the project root:

```bash
bash priv/screenshots/run.sh            # all 18 themes (~25 min)
bash priv/screenshots/run.sh paper ink  # just these
```

`run.sh` compiles once, builds assets once and generates the six demo
feature images once, then for each theme boots the site (in-memory store,
seeded by `seed.exs`, no asset watchers), waits for the front page to answer
200, prints the layout being served, and `capture.mjs` drives headless
Chrome over CDP to screenshot each view.

Things the runner deliberately does up front rather than per boot, because
each one stalled the seed mid-flight when done inside the loop: compiling
(a recompile under the dev code reloader purges modules out from under
`Code.eval_file`), writing files under `priv/static` (trips the file
watcher), and esbuild/tailwind watchers (survive the beam being killed).

The matching end-to-end tests — every view rendered in every theme, plus the
search, subscribe, sign-in, comment and paywall flows — live in
`test/wraith_web/e2e_test.exs` (`mix test test/wraith_web/e2e_test.exs`).
