# Download the precompiled NIFs that elixir_make would fetch from GitHub
# Releases (vix, lazy_html) into its cache, with curl.
#
# Why: GitHub's release-download redirect answers with ~10.8 KB of headers
# and OTP's :httpc, which elixir_make downloads with, stops at 10 KB
# ({:header_too_long, {:max, 10240}}). Without this a fresh checkout falls
# back to building the NIFs from source. Lumis and MDEx are configured to use
# their mirrors instead (config/config.exs), so they don't need this.
#
# Run after `mix deps.get`:   elixir .github/scripts/prefetch_nifs.exs
# Each archive is checked against the checksum.exs the Hex package ships.

defmodule PrefetchNifs do
  @urls %{
    "vix" => "https://github.com/akash-akya/vix/releases/download/v@{version}/@{file}",
    "lazy_html" => "https://github.com/dashbitco/lazy_html/releases/download/v@{version}/@{file}"
  }

  def run do
    cache = cache_dir()
    File.mkdir_p!(cache)
    target = target()
    nif = nif_version()
    IO.puts("elixir_make cache: #{cache} (target #{target}, NIF #{nif})")

    for {app, template} <- @urls, File.exists?("deps/#{app}/checksum.exs") do
      version = hex_version(app)
      {checksums, _} = Code.eval_file("deps/#{app}/checksum.exs")

      case pick(checksums, app, target, version, nif) do
        nil ->
          IO.puts("  #{app}: no precompiled NIF for #{target}; it will build from source")

        {file, "sha256:" <> sha} ->
          path = Path.join(cache, file)

          if File.exists?(path) and sha256(path) == sha do
            IO.puts("  #{app}: #{file} already cached")
          else
            url = template |> String.replace("@{version}", version) |> String.replace("@{file}", file)
            {_, 0} = System.cmd("curl", ["-fsSL", "--retry", "3", "-o", path, url])
            if sha256(path) != sha, do: raise("#{file}: checksum mismatch")
            IO.puts("  #{app}: #{file} downloaded, checksum ok")
          end
      end
    end
  end

  # the newest NIF version the archive exists for that this VM can load
  # (same rule as elixir_make's fallback: same major, minor <= ours)
  defp pick(checksums, app, target, version, nif) do
    {major, minor} = parse(nif)
    re = ~r/^#{Regex.escape(app)}-nif-(\d+\.\d+)-#{Regex.escape(target)}-#{Regex.escape(version)}\.tar\.gz$/

    checksums
    |> Enum.flat_map(fn {file, sum} ->
      case Regex.run(re, file) do
        [_, v] ->
          case parse(v) do
            {^major, m} when m <= minor -> [{m, {file, sum}}]
            _ -> []
          end

        nil ->
          []
      end
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> then(&(&1 && elem(&1, 1)))
  end

  # the version mix fetched, from the package's own metadata
  defp hex_version(app) do
    {:ok, meta} = :file.consult(~c"deps/#{app}/hex_metadata.config")
    {_, version} = List.keyfind(meta, "version", 0)
    version
  end

  defp parse(v), do: v |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

  defp nif_version, do: to_string(:erlang.system_info(:nif_version))

  defp cache_dir do
    System.get_env("ELIXIR_MAKE_CACHE_DIR") ||
      :filename.basedir(:user_cache, "elixir_make", if(System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}))
  end

  # cc_precompiler's naming: <arch>-linux-gnu, <arch>-apple-darwin
  defp target do
    arch =
      case :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd() do
        "arm64" -> "aarch64"
        a -> a
      end

    case :os.type() do
      {:unix, :darwin} -> "#{arch}-apple-darwin"
      {:unix, :linux} -> "#{arch}-linux-gnu"
      other -> raise "unsupported OS #{inspect(other)}"
    end
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end

PrefetchNifs.run()
