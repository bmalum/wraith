defmodule Wraith.StoreCase do
  @moduledoc """
  Tests that touch the store: the in-memory table is emptied before each
  test. Tests are `async: false` because the ETS table is shared.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Wraith.Store
      import Wraith.StoreCase
    end
  end

  setup do
    reset()
    :ok
  end

  @doc "Empty the store: ETS directly, DynamoDB Local by deleting what the tests wrote."
  def reset do
    case Wraith.Store.impl() do
      Wraith.Store.Memory ->
        Wraith.Store.Memory.reset()

      Wraith.Store.Dynamo ->
        {:ok, %{"Items" => items}} =
          ExAws.Dynamo.scan(Wraith.Store.Dynamo.table(), projection_expression: "pk, sk")
          |> ExAws.request()

        items
        |> Enum.map(&Wraith.Store.Dynamo.decode/1)
        |> Enum.each(&Wraith.Store.delete(&1["pk"], &1["sk"]))
    end
  end
end
