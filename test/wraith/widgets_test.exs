defmodule Wraith.WidgetsTest do
  use Wraith.StoreCase, async: false
  alias Wraith.{Markdown, Widgets}

  setup do
    :ok = Widgets.seed_builtins()
    :ok
  end

  test "built-ins are seeded once" do
    slugs = Widgets.list() |> Enum.map(& &1["slug"]) |> Enum.sort()
    assert slugs == ["countdown", "counter", "live-visitors", "poll", "reactions"]
    :ok = Widgets.seed_builtins()
    assert length(Widgets.list()) == 5
    assert Widgets.get("counter")["rev"] == 1
    assert [%{"rev" => 1}] = Widgets.versions("counter")
  end

  test "counter: init, render, dispatch, broadcast" do
    w = Widgets.get("counter")
    assert %{"count" => 0} = Widgets.state(w, "i1", %{"label" => "Hi"})
    {:ok, html} = Widgets.render(w, "i1", %{"label" => "Hi <b>"}, %{"count" => 1234}, %{})
    assert html =~ "1,234"
    assert html =~ "Hi &lt;b&gt;"
    assert html =~ ~s(phx-value-instance="i1")
    assert html =~ ~s(phx-value-event="inc")

    Widgets.subscribe("i1")
    {:ok, %{"count" => 1}} = Widgets.dispatch(w, "i1", %{}, "inc", %{}, %{})
    assert_receive {:widget, "counter", "i1", %{"count" => 1}}
    {:ok, %{"count" => 2}} = Widgets.dispatch(w, "i1", %{}, "inc", %{}, %{})
    assert %{"count" => 2} = Widgets.state(w, "i1", %{})
    # unknown events leave the state alone
    {:ok, %{"count" => 2}} = Widgets.dispatch(w, "i1", %{}, "nope", %{}, %{})
  end

  test "poll: one vote per visitor, percentages" do
    w = Widgets.get("poll")
    props = %{"question" => "Tabs?", "options" => "Tabs|Spaces"}
    {:ok, s} = Widgets.dispatch(w, "p", props, "vote", %{"option" => "Tabs"}, %{visitor: "v1"})
    assert s["votes"] == %{"Tabs" => 1}
    {:ok, s} = Widgets.dispatch(w, "p", props, "vote", %{"option" => "Spaces"}, %{visitor: "v1"})
    assert s["votes"] == %{"Tabs" => 1}, "second vote by the same visitor is ignored"
    {:ok, s} = Widgets.dispatch(w, "p", props, "vote", %{"option" => "Spaces"}, %{visitor: "v2"})
    assert s["votes"] == %{"Tabs" => 1, "Spaces" => 1}

    {:ok, html} = Widgets.render(w, "p", props, s, %{visitor: "v1"})
    assert html =~ "50%"
    assert html =~ "is-mine"
    refute html =~ "w-poll-choice"
    {:ok, html} = Widgets.render(w, "p", props, s, %{visitor: "v3"})
    assert html =~ "w-poll-choice"
  end

  test "reactions toggle" do
    w = Widgets.get("reactions")
    {:ok, s} = Widgets.dispatch(w, "r", %{}, "toggle", %{"emoji" => "🔥"}, %{visitor: "a"})
    assert s["counts"]["🔥"] == 1
    {:ok, s} = Widgets.dispatch(w, "r", %{}, "toggle", %{"emoji" => "🔥"}, %{visitor: "a"})
    assert s["counts"]["🔥"] == 0
  end

  test "elixir widgets: countdown and live visitors" do
    {:ok, html} =
      Widgets.render(
        Widgets.get("countdown"),
        "c",
        %{"to" => "2999-01-01", "label" => "Y3K"},
        %{},
        %{}
      )

    assert html =~ "Y3K"
    assert html =~ "days"
    {:ok, html} = Widgets.render(Widgets.get("countdown"), "c", %{"to" => "2000-01-01"}, %{}, %{})
    assert html =~ "It's here"
    {:ok, html} = Widgets.render(Widgets.get("live-visitors"), "v", %{}, %{}, %{presence: 7})
    assert html =~ "<b>7</b>"
  end

  test "lua sandbox: bad source refused, os removed, runtime errors reported, timeouts cut" do
    assert {:error, %{"source" => "missing function(s): render, handle"}} =
             Widgets.save(%{slug: "x", name: "X", source: "function init() return {} end"})

    assert {:error, %{"source" => msg}} =
             Widgets.save(%{slug: "x", name: "X", source: "function ("})

    assert msg =~ "syntax error"

    ok =
      "function init(p) return {} end function render(s,p,m) return os.time() end function handle(s,e,p,m) return s end"

    assert {:ok, w} = Widgets.save(%{slug: "x", name: "X", source: ok})
    assert {:error, msg} = Widgets.render(w, "i", %{}, %{}, %{})
    assert msg =~ "lua error"

    loop =
      "function init(p) return {} end function render(s,p,m) while true do end end function handle(s,e,p,m) return s end"

    {:ok, w} = Widgets.save(%{slug: "x", name: "X", source: loop})
    assert {:error, msg} = Widgets.render(w, "i", %{}, %{}, %{})
    assert msg =~ "longer than"

    refuse =
      "function init(p) return {} end function render(s,p,m) return '' end function handle(s,e,p,m) error('no') end"

    {:ok, w} = Widgets.save(%{slug: "x", name: "X", source: refuse})
    assert {:error, msg} = Widgets.dispatch(w, "i", %{}, "e", %{}, %{})
    assert msg =~ "no"
  end

  test "versions and rollback" do
    v1 =
      "function init(p) return {} end function render(s,p,m) return 'one' end function handle(s,e,p,m) return s end"

    v2 = String.replace(v1, "one", "two")
    {:ok, w} = Widgets.save(%{slug: "v", name: "V", source: v1})
    assert w["rev"] == 1
    {:ok, w} = Widgets.save(%{slug: "v", name: "V renamed", source: v1})
    assert w["rev"] == 1, "a rename without a source change is not a new version"
    {:ok, w} = Widgets.save(%{slug: "v", name: "V", source: v2})
    assert w["rev"] == 2
    assert Enum.map(Widgets.versions("v"), & &1["rev"]) == [2, 1]
    {:ok, w} = Widgets.rollback("v", 1)
    assert w["rev"] == 3
    assert {:ok, "one"} = Widgets.render(w, "i", %{}, %{}, %{})
    {:ok, w} = Widgets.set_enabled("v", false)
    assert {:error, _} = Widgets.render(w, "i", %{}, %{}, %{})
  end

  test "embeds: youtube/vimeo players, bookmark cards, captions; text strips them" do
    html =
      Markdown.to_html(~s({{embed https://www.youtube.com/watch?v=dQw4w9WgXcQ "Never gonna"}}))

    assert html =~ ~s(youtube-nocookie.com/embed/dQw4w9WgXcQ) and
             html =~ "<figcaption>Never gonna</figcaption>" and html =~ "<iframe"

    assert Markdown.to_html("{{embed https://youtu.be/abc123}}") =~ "embed/abc123"

    assert Markdown.to_html("{{embed https://vimeo.com/76979871}}") =~
             "player.vimeo.com/video/76979871"

    assert Markdown.to_html("{{embed https://x.com/jack/status/20}}") =~ "View post on X"
    # a generic URL becomes a bookmark card even when the page cannot be fetched
    card = Markdown.to_html("{{embed https://nonexistent.invalid/page}}")
    assert card =~ ~s(class="embed is-bookmark") and card =~ "nonexistent.invalid"
    refute card =~ "<script"
    assert Markdown.to_text("Hi\n\n{{embed https://youtu.be/x}}\n\nthere") == "Hi there"
  end

  test "markdown segments and shortcode args" do
    md = """
    # Title

    Some **bold** text.

    {{widget poll question="Tabs or spaces?" options='A|B' id=my-poll}}

    More text <script>alert(1)</script> here.

    {{widget counter}}
    {{widget countdown to=2027-01-01 live}}
    """

    segs = Markdown.segments(md, "post1")

    assert [
             {:html, h1},
             {:widget, "poll", poll, "my-poll"},
             {:html, h2},
             {:widget, "counter", %{}, "post1:1"},
             {:widget, "countdown", cd, "post1:2"}
           ] = segs

    assert h1 =~ "<h1"
    assert h1 =~ "<strong>bold</strong>"
    refute h2 =~ "<script"
    assert poll == %{"question" => "Tabs or spaces?", "options" => "A|B", "id" => "my-poll"}
    assert cd == %{"to" => "2027-01-01", "live" => true}
    assert Markdown.widgets_in(md) |> Enum.map(&elem(&1, 0)) == ["poll", "counter", "countdown"]
    assert Markdown.to_text("# Hi\n\n{{widget counter}}\n\nthere *you*") == "Hi there you"
    assert Markdown.reading_minutes("word") == 1
  end

  test "private per-reader state, tick, fetch allowlist, state cap" do
    src = """
    tick = 10
    function init(p) return { total = 0 } end
    function render(s, p, m)
      local mine = m.private.count or 0
      return "total=" .. s.total .. " mine=" .. mine .. " t=" .. (wraith.now() > 0 and "ok" or "no")
    end
    function handle(s, e, p, m)
      local priv = m.private
      if e == "big" then s.blob = string.rep("x", 70000) return s end
      priv.count = (priv.count or 0) + 1
      s.total = s.total + 1
      return s, priv
    end
    """

    {:ok, w} = Widgets.save(%{slug: "priv", name: "Priv", source: src})
    assert Widgets.tick(w) == 10
    {:ok, _} = Widgets.dispatch(w, "i", %{}, "go", %{}, %{visitor: "a"})
    {:ok, _} = Widgets.dispatch(w, "i", %{}, "go", %{}, %{visitor: "a"})
    {:ok, s} = Widgets.dispatch(w, "i", %{}, "go", %{}, %{visitor: "b"})
    assert s["total"] == 3
    assert {:ok, "total=3 mine=2 t=ok"} = Widgets.render(w, "i", %{}, s, %{visitor: "a"})
    assert {:ok, "total=3 mine=1 t=ok"} = Widgets.render(w, "i", %{}, s, %{visitor: "b"})
    assert {:ok, "total=3 mine=0 t=ok"} = Widgets.render(w, "i", %{}, s, %{visitor: nil})
    assert {:error, msg} = Widgets.dispatch(w, "i", %{}, "big", %{}, %{visitor: "a"})
    assert msg =~ "64 KB"

    assert {:error, msg} = Wraith.Widgets.Fetch.get("https://api.example.com/x")
    assert msg =~ "allowlist"
    assert {:error, "not an http(s) URL"} = Wraith.Widgets.Fetch.get("ftp://x")
    {:ok, _} = Wraith.Settings.update(%{widget_fetch_hosts: "*.example.com"})

    # allowed now; the request itself fails here (no network in tests) but is attempted, not refused
    assert {:error, msg} = Wraith.Widgets.Fetch.get("https://api.example.com/x")
    refute msg =~ "allowlist"
  end

  test "widget html is sanitised: scripts and handlers go, phx/data/style stay" do
    html =
      ~S|<div class="w-x" style="color:red" onclick="x()"><button phx-click="widget" phx-value-event="go" data-n="1" aria-label="go">go</button><script>alert(1)</script><img src="x" onerror="alert(1)"><a href="javascript:alert(1)">l</a></div>|

    out = Widgets.sanitize(html)

    assert out =~ ~s(phx-click="widget") and out =~ ~s(phx-value-event="go") and
             out =~ ~s(data-n="1") and out =~ ~s(style="color:red")

    refute out =~ "onclick" or out =~ "<script" or out =~ "onerror" or out =~ "javascript:"

    src =
      "function init(p) return {} end function render(s,p,m) return '<b onmouseover=\"evil()\">hi</b><script>bad()</script>' end function handle(s,e,p,m) return s end"

    {:ok, w} = Widgets.save(%{slug: "evil", name: "Evil", source: src})
    {:ok, rendered} = Widgets.render(w, "i", %{}, %{}, %{})
    assert rendered == "<b>hi</b>"
  end

  test "janitor drops expired sessions" do
    {:ok, user} =
      Wraith.Accounts.create_user(%{email: "j@x.io", name: "J", password: "a very long password"})

    {:ok, member} = Wraith.Members.create(%{email: "m@x.io"})
    live_tok = Wraith.Accounts.create_session(user)
    dead_tok = Wraith.Accounts.create_session(user)
    mdead_tok = Wraith.Members.create_session(member)

    # age two of them past their expiry
    for tok <- [dead_tok, mdead_tok] do
      {pk, sk} =
        if tok == dead_tok,
          do: Wraith.Store.Keys.session(hash(tok)),
          else: Wraith.Store.Keys.member_session(hash(tok))

      {:ok, _} =
        Wraith.Store.update(
          pk,
          sk,
          &Map.merge(&1, %{
            "expires_at" => "2000-01-01T00:00:00.000Z",
            "gsi1sk" => "2000-01-01T00:00:00.000Z#" <> hash(tok)
          })
        )
    end

    assert Wraith.Janitor.sweep() == 2
    assert Wraith.Accounts.user_by_session(live_tok)

    assert Wraith.Store.get(elem(Wraith.Store.Keys.session(hash(dead_tok)), 0), "SESSION") ==
             :error

    assert Wraith.Store.get(elem(Wraith.Store.Keys.member_session(hash(mdead_tok)), 0), "SESSION") ==
             :error

    assert Wraith.Janitor.sweep() == 0
  end

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
end
