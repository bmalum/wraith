defmodule Mix.Tasks.Wraith.Table do
  @shortdoc "Create the DynamoDB single table (idempotent)"
  @moduledoc """
  Creates the `wraith` table (keys `pk`/`sk`, GSI `gsi1` on `gsi1pk`/`gsi1sk`,
  on-demand capacity) unless it exists.

      WRAITH_STORE=dynamo WRAITH_TABLE=wraith AWS_PROFILE=me mix wraith.table
      DYNAMO_ENDPOINT=http://localhost:8000 mix wraith.table      # DynamoDB Local
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ex_aws)
    {:ok, _} = Application.ensure_all_started(:req)

    case Wraith.Store.Dynamo.ensure_table!() do
      :created -> Mix.shell().info("created table #{Wraith.Store.Dynamo.table()}")
      :exists -> Mix.shell().info("table #{Wraith.Store.Dynamo.table()} already exists")
    end
  end
end
