defmodule WraithWeb.HealthController do
  @moduledoc "`/health` (readiness: the store answers) and `/health/live` (the VM is up)."
  use WraithWeb, :controller
  require Logger

  def ready(conn, _params) do
    # the detail (what failed, which node, which version) goes to the log; the
    # anonymous caller learns only ok / degraded
    ok? =
      try do
        {pk, sk} = Wraith.Store.Keys.site()
        _ = Wraith.Store.get(pk, sk)
        true
      rescue
        e ->
          Logger.warning("health: store check failed: #{Exception.message(e)}")
          false
      catch
        :exit, reason ->
          Logger.warning("health: store check exited: #{inspect(reason)}")
          false
      end

    conn
    |> put_status(if(ok?, do: 200, else: 503))
    |> json(%{"status" => if(ok?, do: "ok", else: "degraded")})
  end

  def live(conn, _params), do: text(conn, "ok")
end
