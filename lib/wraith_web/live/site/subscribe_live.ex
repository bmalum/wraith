defmodule WraithWeb.Site.SubscribeLive do
  @moduledoc "A reader signs up as a member."
  use WraithWeb, :live_view

  alias Wraith.{Members, Settings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       site: Settings.get(),
       form: to_form(%{"email" => "", "name" => ""}),
       done: false,
       page_title: "Subscribe"
     )}
  end

  @impl true
  def handle_event("subscribe", %{"email" => email, "name" => name}, socket) do
    case Members.create(%{email: email, name: name}) do
      {:ok, _} ->
        {:noreply, assign(socket, done: true)}

      {:error, %{"email" => "is already a member"}} ->
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
    <Layouts.site flash={@flash} site={@site} current_user={@current_user}>
      <section class="lead is-small">
        <h1 class="lead-title">Subscribe to {@site["title"]}</h1>
        <p class="lead-desc">New posts in your inbox. No spam, leave whenever.</p>
      </section>

      <div :if={@done} class="subscribe-done" role="status">
        <.icon name="hero-check-circle" class="size-6" />
        <p>You're in. Thanks for reading.</p>
      </div>

      <.form
        :if={not @done}
        for={@form}
        phx-submit="subscribe"
        class="subscribe-form"
        id="subscribe-form"
      >
        <.input field={@form[:name]} label="Name" placeholder="Optional" />
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          required
          placeholder="you@example.com"
        />
        <button class="btn-accent" type="submit">Subscribe</button>
      </.form>
    </Layouts.site>
    """
  end
end
