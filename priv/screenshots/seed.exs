# Seed used by the screenshot run. One owner, a members-only post, a public
# post with live widgets, a second post, so every public view has content.
# THEME selects the active theme; MEMBERS/COMMENTS are on.
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
    navigation: [%{"label" => "Home", "url" => "/"}, %{"label" => "Essays", "url" => "/tag/essays"}]
  })

{:ok, _} =
  Wraith.Accounts.update_profile(owner, %{
    bio: "Mathematician. Wrote the first algorithm. Occasionally haunts a compiler.",
    location: "London",
    website: "https://example.com",
    twitter: "ada"
  })

Wraith.Widgets.seed_builtins()

essay = """
There is a particular kind of quiet that settles over a codebase at 2 a.m. Not the absence of sound, but the presence of attention. Everything you touch, you touch deliberately.

## Live widgets

A blog post should not be a dead document. Below is a counter every reader shares.

{{widget counter label="Readers who agree" id=agree}}

And a poll, because we never did settle this:

{{widget poll question="Tabs or spaces?" options="Tabs|Spaces|Whatever the formatter says" id=tabs}}

> The best code is the code you didn't have to write.

## On ghosts

Every system carries the ghosts of the decisions that made it. Thanks for reading.
"""

{:ok, p1} =
  Wraith.Content.create_post(%{
    title: "Writing at 2 a.m.",
    markdown: essay,
    author_id: owner["id"],
    tags: "essays, elixir",
    custom_excerpt: "On attention, live documents, and the ghosts every system carries.",
    featured: true
  })

{:ok, _} = Wraith.Content.publish_post(p1)

{:ok, p2} =
  Wraith.Content.create_post(%{
    title: "Countdown to the launch",
    markdown: "We ship on New Year's Day.\n\n{{widget countdown to=2027-01-01 label=\"Launch day\"}}\n\nSee you there.",
    author_id: owner["id"],
    tags: "news"
  })

{:ok, _} = Wraith.Content.publish_post(p2)

{:ok, p3} =
  Wraith.Content.create_post(%{
    title: "For members only",
    markdown: "Here is the public opening anyone can read.\n\n<!--members-only-->\n\nAnd here is the part reserved for members who signed up.",
    author_id: owner["id"],
    tags: "essays",
    visibility: "members"
  })

{:ok, _} = Wraith.Content.publish_post(p3)

:ok = Wraith.Search.rebuild()
IO.puts("seeded")
