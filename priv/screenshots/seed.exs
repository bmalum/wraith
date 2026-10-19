# Seed used by the screenshot run: an owner with a profile, a page, six posts
# with feature images (see images.exs), one of them members-only, live widgets
# in the lead essay. THEME selects the active theme; MEMBERS/COMMENTS are on.
Code.eval_file(Path.join(__DIR__, "images.exs"))

{:ok, owner} =
  Wraith.Accounts.setup_owner(%{
    email: "ada@example.com",
    name: "Ada Lovelace",
    password: "analytical engine"
  })

{:ok, _} =
  Wraith.Settings.update(%{
    title: "The Daily Spectre",
    description: "Notes on software, systems and the occasional ghost story.",
    theme: System.get_env("THEME", "paper"),
    members_enabled: true,
    comments_enabled: true,
    twitter: "@dailyspectre",
    navigation: [
      %{"label" => "Home", "url" => "/"},
      %{"label" => "Essays", "url" => "/tag/essays"},
      %{"label" => "Systems", "url" => "/tag/systems"},
      %{"label" => "About", "url" => "/about"}
    ]
  })

{:ok, _} =
  Wraith.Accounts.update_profile(owner, %{
    bio: "Mathematician. Wrote the first algorithm. Occasionally haunts a compiler.",
    location: "London",
    website: "https://example.com",
    twitter: "ada"
  })

Wraith.Widgets.seed_builtins()

publish = fn attrs, days_ago ->
  {:ok, p} = Wraith.Content.create_post(Map.put(attrs, :author_id, owner["id"]))
  {:ok, p} = Wraith.Content.publish_post(p)
  # back-date so the feed has a spread of dates
  at = DateTime.utc_now() |> DateTime.add(-days_ago, :day) |> DateTime.to_iso8601()
  {:ok, _} = Wraith.Content.update_post(p, %{published_at: at})
  p
end

publish.(
  %{
    type: "page",
    title: "About",
    slug: "about",
    markdown: "The Daily Spectre is a small publication about building software that lasts.\n\nIt is written by one person and read by a few more."
  },
  40
)

publish.(
  %{
    title: "Writing at 2 a.m.",
    markdown: """
    There is a particular kind of quiet that settles over a codebase at 2 a.m. Not the absence of sound, but the presence of attention. Everything you touch, you touch deliberately.

    ## Live widgets

    A blog post should not be a dead document. Below is a counter every reader shares.

    {{widget counter label="Readers who agree" id=agree}}

    And a poll, because we never did settle this:

    {{widget poll question="Tabs or spaces?" options="Tabs|Spaces|Whatever the formatter says" id=tabs}}

    > The best code is the code you didn't have to write.

    ## On ghosts

    Every system carries the ghosts of the decisions that made it. Thanks for reading.
    """,
    tags: "essays, elixir",
    custom_excerpt: "On attention, live documents, and the ghosts every system carries.",
    feature_image: "/images/demo/night.svg",
    featured: true
  },
  1
)

publish.(
  %{
    title: "The database that remembers everything",
    markdown: "Single-table design sounds like a constraint. It is a discipline.\n\n## One table, many shapes\n\nEvery entity shares a key schema; access patterns are designed first, data second.\n\n## What you give up\n\nAd-hoc queries. What you get back is predictability.",
    tags: "systems, databases",
    custom_excerpt: "Single-table design is less a constraint than a discipline.",
    feature_image: "/images/demo/sea.svg"
  },
  3
)

publish.(
  %{
    title: "Countdown to the launch",
    markdown: "We ship on New Year's Day.\n\n{{widget countdown to=2027-01-01 label=\"Launch day\"}}\n\nSee you there.",
    tags: "news",
    feature_image: "/images/demo/ember.svg"
  },
  5
)

publish.(
  %{
    title: "A field guide to haunted builds",
    markdown: "Flaky tests. Phantom cache hits. The CI job that passes only on Tuesdays.\n\nHere is how to exorcise each one.",
    tags: "systems, essays",
    custom_excerpt: "Flaky tests, phantom caches, and the CI job that only passes on Tuesdays.",
    feature_image: "/images/demo/moss.svg"
  },
  9
)

publish.(
  %{
    title: "For members only",
    markdown: "Here is the public opening anyone can read.\n\n<!--members-only-->\n\nAnd here is the part reserved for members who signed up.",
    tags: "essays",
    visibility: "members",
    feature_image: "/images/demo/dusk.svg"
  },
  12
)

publish.(
  %{
    title: "Notes from a quiet week",
    markdown: "Nothing broke. I wrote this down because it felt worth recording.",
    tags: "notes",
    feature_image: "/images/demo/sand.svg"
  },
  18
)

:ok = Wraith.Search.rebuild()
IO.puts("seeded")
