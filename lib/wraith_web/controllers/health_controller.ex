defmodule WraithWeb.HealthController do
  @moduledoc "`/health` (readiness: the store answers) and `/health/live` (the VM is up)."
  use WraithWeb, :controller

  def ready(conn, _params) do
    store =
      try do
        {pk, sk} = Wraith.Store.Keys.site()
        _ = Wraith.Store.get(pk, sk)
        "ok"
      rescue
        e -> "error: " <> Exception.message(e)
      catch
        :exit, reason -> "error: " <> inspect(reason)
      end

    body = %{
      "status" => if(store == "ok", do: "ok", else: "degraded"),
      "store" => store,
      "version" => to_string(Application.spec(:wraith, :vsn)),
      "node" => to_string(node())
    }

    conn |> put_status(if(store == "ok", do: 200, else: 503)) |> json(body)
  end

  def live(conn, _params), do: text(conn, "ok")
end
