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
end
