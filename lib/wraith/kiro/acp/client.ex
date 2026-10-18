defmodule Wraith.Kiro.ACP.Client do
  @moduledoc """
  What `Wraith.Studio.Server` needs from an ACP client. `Wraith.Kiro.ACP`
  speaks to a real Kiro Agent Server over a WebSocket; `Wraith.Kiro.ACP.Fake`
  is the scripted agent tests (and the offline dev studio) run against.

  The owner (the process that called `connect/2`) receives everything the
  agent sends that is not a reply:

      {:acp, pid, {:notification, method, params}}
      {:acp, pid, {:request, id, method, params}}   # answer with respond/3 or reject/4
      {:acp, pid, {:closed, reason}}
  """

  @type conn :: pid()

  @callback connect(String.t(), keyword()) :: {:ok, conn()} | {:error, term()}
  @callback initialize(conn()) :: {:ok, map()} | {:error, term()}
  @callback ensure_session(conn(), String.t(), String.t(), list(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback load_session(conn(), String.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback close_session(conn(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback set_mode(conn(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback prompt(conn(), String.t(), String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  @callback cancel(conn(), String.t()) :: :ok
  @callback steer(conn(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback permit(conn(), String.t(), String.t()) :: :ok | {:ok, map()} | {:error, term()}
  @callback answer_question(conn(), String.t(), String.t() | nil) ::
              :ok | {:ok, map()} | {:error, term()}
  @callback respond(conn(), term(), map()) :: :ok
  @callback reject(conn(), term(), integer(), String.t()) :: :ok
  @callback close(conn()) :: :ok
  @doc "May MCP bridge requests (`bridge/http`) arrive on the ACP channel? Only the fake does that."
  @callback bridge_on_acp?() :: boolean()
end
