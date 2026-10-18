defmodule Wraith.Kiro.Key do
  @moduledoc """
  The studio's Kiro API key.

  Keys look like `ksk_` followed by 20–64 alphanumerics and are minted at
  app.kiro.dev → API Keys. KAS reads one from `KIRO_API_KEY` at process
  start, so the key lives in the studio VM.

  `verify/1` asks Kiro whether the key is live. The verifier is swappable
  via `config :wraith, :kiro_key_verifier` (tests use
  `Wraith.FakeKiroKeyVerifier`).
  """

  @format ~r/\Aksk_[A-Za-z0-9]{20,64}\z/

  @type verdict :: {:ok, map()} | {:error, :invalid | :unreachable | {:http, integer()}}

  @callback verify(String.t()) :: verdict()

  def valid_format?(key) when is_binary(key), do: Regex.match?(@format, key)
  def valid_format?(_), do: false

  @doc "Trim and strip accidental quotes/`KIRO_API_KEY=` prefixes from a pasted key."
  def normalize(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.replace_prefix("KIRO_API_KEY=", "")
    |> String.trim("\"")
    |> String.trim("'")
  end

  @doc "The last four characters — all we ever show again."
  def hint(key) when is_binary(key), do: "ksk_…" <> String.slice(key, -4, 4)

  @spec verify(String.t()) :: verdict()
  def verify(key) do
    if valid_format?(key), do: verifier().verify(key), else: {:error, :invalid}
  end

  defp verifier, do: Application.get_env(:wraith, :kiro_key_verifier, __MODULE__.Remote)
end
