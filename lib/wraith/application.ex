defmodule Wraith.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    WraithWeb.Themes.register()
    # code-block highlighting parsers, compiled once off the first request
    Lumis.Languages.async_load(
      ~w(elixir erlang html css javascript typescript json yaml bash python go rust sql markdown)
    )

    children =
      [
        WraithWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:wraith, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Wraith.PubSub},
        WraithWeb.Presence,
        Wraith.RateLimit
      ] ++
        store_children() ++
        [{Task, &Wraith.Widgets.seed_builtins/0}, Wraith.Search] ++
        runtime_children() ++
        [Wraith.Studio.Server] ++
        clock_children() ++
        [
          WraithWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Wraith.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # the ETS store is a process, so is the SQL pool; DynamoDB is not
  defp store_children do
    case Wraith.Store.impl() do
      Wraith.Store.Memory -> [Wraith.Store.Memory]
      Wraith.Store.SQL -> [Wraith.Store.SQL]
      _ -> []
    end
  end

  defp clock_children do
    if Application.get_env(:wraith, :clock, true), do: [Wraith.Clock, Wraith.Janitor], else: []
  end

  # the offline runtime keeps its VMs in an Agent
  defp runtime_children do
    if Wraith.Kiro.Runtime.impl() == Wraith.Kiro.Runtime.Fake,
      do: [Wraith.Kiro.Runtime.Fake],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WraithWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
