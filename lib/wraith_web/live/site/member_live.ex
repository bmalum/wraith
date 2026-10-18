defmodule WraithWeb.Site.MemberLive do
  @moduledoc "A member's account: sign in by mail, newsletter on/off, plan, sign out."
  use WraithWeb, :live_view
  alias WraithWeb.Themes
  alias Wraith.{Members, Newsletter, Settings}

  @impl true
  def mount(_params, _session, socket) do
    site = Settings.get()

    {:ok,
     assign(socket,
       site: site,
       theme: Themes.get(site["theme"]),
       page_title: "Account",
       sent: false,
       form: to_form(%{"email" => ""})
     )}
  end

  @impl true
  def handle_event("request-link", %{"email" => email}, socket) do
    # the same answer whether or not the address is known: no member enumeration
    case Members.get_by_email(email) do
      %{} = member -> Newsletter.send_login_link(member)
      nil -> :ok
    end

    {:noreply, assign(socket, sent: true)}
  end

  def handle_event("toggle-newsletter", _params, %{assigns: %{current_member: %{} = m}} = socket) do
    {:ok, m} = Members.update(m, %{subscribed: not m["subscribed"]})
    {:noreply, assign(socket, current_member: m)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
        page={:member}
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
