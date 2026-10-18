defmodule WraithWeb.Admin.SetupLive do
  @moduledoc """
  First run: name the site, create the owner. On success the same form is
  posted (`phx-trigger-action`) to `/admin/login`, which sets the cookie.
  """
  use WraithWeb, :live_view

  alias Wraith.{Accounts, Settings}

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.any_users?() do
      {:ok, push_navigate(socket, to: ~p"/admin/login")}
    else
      {:ok,
       assign(socket,
         form: user_form(%{}),
         errors: %{},
         page_title: "Set up your site",
         trigger: false
       )}
    end
  end

  defp user_form(params, errors \\ %{}) do
    to_form(params,
      as: :user,
      errors: Enum.map(errors, fn {k, v} -> {String.to_atom(k), {v, []}} end),
      action: :validate
    )
  end

  @impl true
  def handle_event("save", %{"user" => params}, socket) do
    with {:ok, _site} <- site(params),
         {:ok, _owner} <- Accounts.setup_owner(Map.take(params, ~w(name email password))) do
      {:noreply, assign(socket, trigger: true, form: user_form(params))}
    else
      {:error, errors} ->
        {:noreply, assign(socket, form: user_form(params, errors), errors: errors)}
    end
  end

  defp site(%{"title" => t}) when is_binary(t) and t != "", do: Settings.update(%{title: t})
  defp site(_), do: {:error, %{"title" => "can't be blank"}}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.plain flash={@flash}>
      <div class="plain-brand"><span class="admin-brand-mark">W</span></div>
      <h1 class="plain-title">Welcome to Wraith</h1>
      <p class="plain-lede">
        Name the site and create the owner account. You can change all of this later.
      </p>

      <.form
        for={@form}
        id="setup-form"
        phx-submit="save"
        class="plain-form"
        phx-trigger-action={@trigger}
        action={~p"/admin/login"}
        method="post"
      >
        <.input field={@form[:title]} label="Site title" placeholder="The Daily Spectre" />
        <.input field={@form[:name]} label="Your name" placeholder="Ada" />
        <.input field={@form[:email]} type="email" label="Email" placeholder="ada@example.com" />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          placeholder="At least 10 characters"
        />
        <p :if={@errors["base"]} class="form-error">{@errors["base"]}</p>
        <button type="submit" class="btn-accent is-wide">Create site</button>
      </.form>
    </Layouts.plain>
    """
  end
end
