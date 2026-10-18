defmodule WraithWeb.Site.HomeLive do
  @moduledoc "The front page: the newest published posts, the first one large."
  use WraithWeb, :live_view
  alias WraithWeb.Themes

  alias Wraith.{Accounts, Content, Settings}

  @impl true
  def mount(_params, _session, socket) do
    site = Settings.get()

    if not site["setup_done"] and not Accounts.any_users?() do
      {:ok, push_navigate(socket, to: ~p"/admin/setup")}
    else
      if connected?(socket), do: Content.subscribe()

      {:ok,
       assign(socket,
         site: site,
         theme: Themes.get(site["theme"]),
         authors: authors(),
         page_title: nil,
         meta_description: site["description"]
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page =
      case Integer.parse(Map.get(params, "page", "1")) do
        {n, _} when n >= 1 -> n
        _ -> 1
      end

    {:noreply, load(socket, page)}
  end

  defp load(socket, page) do
    per = socket.assigns.site["posts_per_page"]

    %{posts: posts, has_next: has_next} =
      Content.page(&Content.list_posts("published", Keyword.put(&1, :type, "post")), page, per)

    assign(socket, posts: posts, page: page, has_next: has_next)
  end

  @impl true
  def handle_info({:content, _event, _post}, socket),
    do: {:noreply, load(socket, socket.assigns.page)}

  defp authors, do: Accounts.list_users() |> Map.new(&{&1["id"], &1})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.site flash={@flash} site={@site} theme={@theme} current_user={@current_user}>
      <WraithWeb.SiteComponents.theme_page
        theme={@theme}
        page={:index}
        assigns={page_assigns(assigns)}
      />
    </Layouts.site>
    """
  end

  # what the theme's template sees: everything but LiveView's own bookkeeping
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
