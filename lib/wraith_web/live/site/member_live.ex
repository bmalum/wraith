defmodule WraithWeb.Site.MemberLive do
  @moduledoc "A member's account: sign in by mail, newsletter on/off, plan, sign out."
  use WraithWeb, :live_view
  alias Wraith.{Members, Newsletter}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Account",
       sent: false,
       form: to_form(%{"email" => ""})
     )}
  end

  @impl true
  def handle_event("request-link", %{"email" => email}, socket) do
    # limited per address and per client; the answer never says whether the address is known
    with :ok <-
           Wraith.RateLimit.check(
             :magic_link,
             socket.assigns[:client_ip] || socket.assigns[:visitor]
           ),
         :ok <- Wraith.RateLimit.check(:magic_link, String.downcase(email)) do
      case Members.get_by_email(email) do
        %{} = member -> Newsletter.send_login_link(member)
        nil -> :ok
      end

      {:noreply, assign(socket, sent: true)}
    else
      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Too many sign-in links requested. Check your inbox, or wait a few minutes."
         )}
    end
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
        assigns={WraithWeb.SiteComponents.page_assigns(assigns)}
      />
    </Layouts.site>
    """
  end
end
