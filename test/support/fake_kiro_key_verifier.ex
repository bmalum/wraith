defmodule Wraith.FakeKiroKeyVerifier do
  @moduledoc "Tests: any well-formed key is live unless it ends in `dead`."
  @behaviour Wraith.Kiro.Key

  @impl true
  def verify(key) do
    if String.ends_with?(key, "dead"), do: {:error, :invalid}, else: {:ok, %{"plan" => "fake"}}
  end
end
