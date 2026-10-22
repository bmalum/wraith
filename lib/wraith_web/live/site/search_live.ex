defmodule WraithWeb.Site.SearchLive do
  @moduledoc "Site search, as you type."
  use WraithWeb, :live_view
  alias WraithWeb.Themes
  alias Wraith.{Accounts, Search, Settings}

  @impl true
  def mount(_params, _session, socket) do
    site = Settings.get()

    {:ok,
     assign(socket,
       site: site,
       theme: Themes.get(site["theme"]),
       page_title: "Search",
       authors: Accounts.list_users() |> Map.new(&{&1["id"], &1})
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = params["q"] || ""

    # 60 searches a minute per visitor (or IP); the index is a CPU cost per query
    results =
      case Wraith.RateLimit.check(:search, socket.assigns[:visitor] || socket.assigns[:client_ip]) do
        :ok -> Search.search(q, 20)
        {:error, _} -> []
      end

    {:noreply, assign(socket, q: q, results: results)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/search?q=#{q}", replace: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.site
      flash={@flash}
      site={@site}
      theme={@theme}
      current_user={@current_user}
      current_member={assigns[:current_member]}
    >
      <WraithWeb.SiteComponents.theme_page
        theme={@theme}
        page={:search}
        assigns={page_assigns(assigns)}
      />
    </Layouts.site>
    """
  end

  defp page_assigns(assigns),
    do:
      Map.drop(assigns, [
        :flash,
        :theme,
        :socket,
        :__changed__,
        :live_action,
        :streams,
        :uploads,
        :myself
      ])
end
