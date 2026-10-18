defmodule Mix.Tasks.Wraith.Table do
  @shortdoc "Create the single table for the configured store (idempotent)"
  @moduledoc """
  Creates the one table every item lives in, for whichever store
  `WRAITH_STORE` names: DynamoDB (keys `pk`/`sk`, GSI `gsi1`, on-demand),
  PostgreSQL or Aurora DSQL (`items` with its index).

      WRAITH_STORE=dynamo WRAITH_TABLE=wraith AWS_PROFILE=me mix wraith.table
      DYNAMO_ENDPOINT=http://127.0.0.1:8000 WRAITH_STORE=dynamo mix wraith.table
      WRAITH_STORE=postgres DATABASE_URL=postgres://postgres:postgres@127.0.0.1/wraith mix wraith.table
      WRAITH_STORE=dsql DSQL_ENDPOINT=<cluster>.dsql.eu-central-1.on.aws AWS_PROFILE=me mix wraith.table
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ex_aws)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    {store, table} =
      case Wraith.Store.impl() do
        Wraith.Store.SQL ->
          {:ok, _} = Wraith.Store.SQL.start_link()
          {Wraith.Store.SQL, Wraith.Store.SQL.table()}

        Wraith.Store.Memory ->
          Mix.raise("WRAITH_STORE=memory has no table to create")

        _ ->
          {Wraith.Store.Dynamo, Wraith.Store.Dynamo.table()}
      end

    case store.ensure_table!() do
      :created -> Mix.shell().info("created table #{table} (#{inspect(store)})")
      :exists -> Mix.shell().info("table #{table} already exists (#{inspect(store)})")
    end
  end
end
