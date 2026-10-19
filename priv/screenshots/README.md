# Theme screenshots

A reference capture of every public view in every theme: **18 themes × 8
views = 144 images**, one folder per theme.

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
bash priv/screenshots/run.sh            # all 18 themes
bash priv/screenshots/run.sh paper ink  # just these
```

`run.sh` boots the site once per theme (in-memory store, seeded by
`seed.exs`), waits for the port, prints the layout it is serving, and
`capture.mjs` drives headless Chrome over CDP to screenshot each view.

The matching end-to-end tests — every view rendered in every theme, plus the
search, subscribe, sign-in, comment and paywall flows — live in
`test/wraith_web/e2e_test.exs` (`mix test test/wraith_web/e2e_test.exs`).
