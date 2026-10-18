defmodule WraithWeb.Site.SubscribeLive do
  @moduledoc "A reader signs up as a member."
  use WraithWeb, :live_view
  alias WraithWeb.Themes

  alias Wraith.{Members, Settings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       site: Settings.get(),
       theme: Themes.current(),
       form: to_form(%{"email" => "", "name" => ""}),
       done: false,
       page_title: "Subscribe"
     )}
  end

  @impl true
  def handle_event("subscribe", %{"email" => email, "name" => name}, socket) do
    with :ok <-
           Wraith.RateLimit.check(
             :subscribe,
             socket.assigns[:client_ip] || socket.assigns[:visitor]
           ),
         {:ok, member} <- Members.create(%{email: email, name: name, subscribed: false}) do
      # double opt-in: the welcome comes once the confirmation link is opened
      Wraith.Newsletter.send_confirmation(member)
      {:noreply, assign(socket, done: true)}
    else
      {:error, retry_ms} when is_integer(retry_ms) ->
        {:noreply,
         put_flash(socket, :error, "Too many sign-ups from here; try again in a few minutes.")}

      {:error, %{"email" => "is already a member"}} ->
        # the same answer as a fresh sign-up (no enumeration); a pending member gets the link again
        if m = Members.get_by_email(email),
          do: if(m["subscribed"], do: :ok, else: Wraith.Newsletter.send_confirmation(m))

        {:noreply, assign(socket, done: true)}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           form:
             to_form(%{"email" => email, "name" => name},
               errors: Enum.map(errors, fn {k, v} -> {String.to_atom(k), {v, []}} end)
             )
         )}
    end
  end

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
        page={:subscribe}
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
