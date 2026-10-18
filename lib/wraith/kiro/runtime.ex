defmodule Wraith.Kiro.Runtime do
  @moduledoc """
  Where the studio's Kiro Agent Server runs. Ported from shadow_corp's
  `Kiro.Runtime`: one implementation per environment,
  `config :wraith, :kiro_runtime`.

    * `Wraith.Kiro.Runtime.MicroVM` — a Lambda MicroVM (deployed, or dev
      against AWS with `WRAITH_MICROVM_IMAGE_ARN` set)
    * `Wraith.Kiro.Runtime.Fake` — no network, a scripted agent

  A runtime launches the VM with a `payload` the in-VM shim receives on its
  `/run` hook (the Kiro API key, the bridge key, the journal location),
  reports lifecycle state and tells us how to open the ACP and bridge
  WebSockets.
  """

  @type id :: String.t()
  @type state :: :pending | :running | :suspended | :terminated | :failed
  @type attach :: %{url: String.t(), protocols: [String.t()], expires_at: DateTime.t() | nil}

  @callback start(map()) :: {:ok, %{id: id(), endpoint: String.t()}} | {:error, term()}
  @callback status(id()) :: {:ok, state()} | {:error, term()}
  @callback attach(id(), String.t()) :: {:ok, attach()} | {:error, term()}
  @callback attach_bridge(id(), String.t(), keyword()) :: {:ok, attach()} | {:error, term()}
  @callback suspend(id()) :: :ok | {:error, term()}
  @callback resume(id()) :: :ok | {:error, term()}
  @callback terminate(id()) :: :ok | {:error, term()}
  @callback checkpoint(id(), String.t()) :: :ok | {:error, term()}
  @callback list() :: {:ok, [%{id: id(), state: state()}]} | {:error, term()}
  @optional_callbacks checkpoint: 2, list: 0

  def impl, do: Application.get_env(:wraith, :kiro_runtime, __MODULE__.Fake)

  def start(payload), do: impl().start(payload)
  def status(id), do: impl().status(id)
  def attach(id, endpoint), do: impl().attach(id, endpoint)
  def attach_bridge(id, endpoint, opts \\ []), do: impl().attach_bridge(id, endpoint, opts)
  def suspend(id), do: impl().suspend(id)
  def resume(id), do: impl().resume(id)
  def terminate(id), do: impl().terminate(id)

  def list do
    mod = impl()
    if function_exported?(mod, :list, 0), do: mod.list(), else: {:ok, []}
  end

  def checkpoint(id, endpoint) do
    mod = impl()
    if function_exported?(mod, :checkpoint, 2), do: mod.checkpoint(id, endpoint), else: :ok
  end
end
