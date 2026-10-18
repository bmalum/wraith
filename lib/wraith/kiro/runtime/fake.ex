defmodule Wraith.Kiro.Runtime.Fake do
  @moduledoc """
  Offline runtime: VMs are rows in an Agent, nothing is launched. `attach/2`
  returns a `fake://` URL that `Wraith.Kiro.ACP.Fake` understands. Used in
  tests and in dev when no MicroVM image is configured.
  """
  @behaviour Wraith.Kiro.Runtime

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start(payload) do
    id = "fake-" <> Integer.to_string(System.unique_integer([:positive]))
    Agent.update(__MODULE__, &Map.put(&1, id, %{state: :running, payload: payload}))
    {:ok, %{id: id, endpoint: "#{id}.fake.local"}}
  end

  @impl true
  def status(id) do
    case Agent.get(__MODULE__, &Map.get(&1, id)) do
      nil -> {:ok, :terminated}
      %{state: s} -> {:ok, s}
    end
  end

  @impl true
  def attach(id, endpoint),
    do: {:ok, %{url: "fake://#{endpoint}/#{id}", protocols: [], expires_at: nil}}

  @impl true
  def attach_bridge(id, endpoint, opts \\ []) do
    case {get_in(payload(id) || %{}, [:bridge_key]), opts[:key]} do
      {nil, _} -> {:ok, %{url: "fake://#{endpoint}/#{id}/bridge", protocols: [], expires_at: nil}}
      {k, k} -> {:ok, %{url: "fake://#{endpoint}/#{id}/bridge", protocols: [], expires_at: nil}}
      _ -> {:error, {:upgrade, 403, "bridge is bound to another studio"}}
    end
  end

  @impl true
  def suspend(id), do: set(id, :suspended)
  @impl true
  def resume(id), do: set(id, :running)
  @impl true
  def terminate(id), do: set(id, :terminated)

  defp set(id, state) do
    Agent.update(__MODULE__, fn vms ->
      Map.update(vms, id, %{state: state}, &%{&1 | state: state})
    end)

    :ok
  end

  @impl true
  def list do
    vms = Agent.get(__MODULE__, & &1)
    {:ok, for({id, %{state: s}} <- vms, s != :terminated, do: %{id: id, state: s})}
  end

  @doc "What payload a fake VM was started with (tests)."
  def payload(id), do: Agent.get(__MODULE__, &get_in(&1, [id, :payload]))
end
