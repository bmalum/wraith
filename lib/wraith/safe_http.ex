defmodule Wraith.SafeHTTP do
  @moduledoc """
  Outbound HTTP on behalf of untrusted input — a widget's `wraith.fetch`, an
  agent's `upload_from_url`, an embed URL in a post. The one place the rules
  live, so no fetch can be pointed at the inside of the network:

    * `http`/`https` only, with a hostname;
    * the hostname is resolved **here**, and every address it resolves to must
      be public — loopback, RFC 1918, link-local (169.254.x: cloud metadata),
      CGNAT, multicast, unspecified and their IPv6 counterparts are refused;
    * redirects are followed by hand, at most `max_redirects`, and each hop is
      checked again (a public host that 302s to 127.0.0.1 is the classic);
    * optional host allowlist (`allow:` list of exact names / `*.suffix`);
    * the body is streamed and cut at `max_bytes` — a 10 GB response never
      lands in memory before someone checks its size;
    * a total deadline, not just an idle timeout.

  Returns `{:ok, %{status, headers, body, url}}` (final URL after redirects)
  or `{:error, reason}` with a reason safe to show a user.
  """

  @defaults [max_bytes: 1_048_576, max_redirects: 3, timeout_ms: 10_000, allow: nil]

  @type opt ::
          {:max_bytes, pos_integer()}
          | {:max_redirects, non_neg_integer()}
          | {:timeout_ms, pos_integer()}
          | {:allow, [String.t()] | nil}
          | {:headers, [{String.t(), String.t()}]}

  @spec get(String.t(), [opt()]) ::
          {:ok, %{status: pos_integer(), headers: map(), body: binary(), url: String.t()}}
          | {:error, String.t()}
  def get(url, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    deadline = System.monotonic_time(:millisecond) + opts[:timeout_ms]
    follow(url, opts, opts[:max_redirects], deadline)
  end

  @doc "Is this URL one we would fetch at all? (scheme, host, allowlist, public address.)"
  @spec check(String.t(), [opt()]) :: :ok | {:error, String.t()}
  def check(url, opts \\ []) do
    with {:ok, uri} <- parse(url),
         :ok <- allowed_host(uri.host, Keyword.get(opts, :allow)),
         :ok <- public_host(uri.host) do
      :ok
    end
  end

  # ---- the loop --------------------------------------------------------------------

  defp follow(url, opts, hops_left, deadline) do
    with {:ok, uri} <- parse(url),
         :ok <- allowed_host(uri.host, opts[:allow]),
         :ok <- public_host(uri.host),
         :ok <- time_left(deadline),
         {:ok, resp} <- request(url, opts, deadline) do
      case resp do
        %{status: s, headers: h} when s in [301, 302, 303, 307, 308] ->
          case location(h, uri) do
            nil -> {:error, "redirect without a location"}
            _next when hops_left == 0 -> {:error, "too many redirects"}
            next -> follow(next, opts, hops_left - 1, deadline)
          end

        %{status: s, headers: h, body: body} ->
          {:ok, %{status: s, headers: h, body: body, url: url}}
      end
    end
  end

  defp request(url, opts, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)
    max = opts[:max_bytes]

    # stream into an accumulator and stop reading past the cap
    into = fn {:data, chunk}, {req, resp} ->
      acc = Map.get(resp.private, :acc, <<>>)
      size = byte_size(acc) + byte_size(chunk)

      if size > max do
        {:halt,
         {req,
          put_in(resp.private[:acc], binary_part(acc <> chunk, 0, max))
          |> put_in([Access.key(:private), :truncated], true)}}
      else
        {:cont, {req, put_in(resp.private[:acc], acc <> chunk)}}
      end
    end

    case Req.get(url,
           redirect: false,
           retry: false,
           receive_timeout: remaining,
           connect_options: [timeout: min(remaining, 5_000)],
           headers: Keyword.get(opts, :headers, [{"user-agent", "Wraith"}]),
           into: into
         ) do
      {:ok, %Req.Response{} = r} ->
        body = Map.get(r.private, :acc, r.body || <<>>)
        body = if is_binary(body), do: body, else: <<>>

        if r.private[:truncated],
          do: {:error, "response larger than #{div(max, 1024)} KB"},
          else: {:ok, %{status: r.status, headers: r.headers, body: body}}

      {:error, %{__exception__: true} = e} ->
        {:error, "fetch failed: " <> Exception.message(e)}

      {:error, other} ->
        {:error, "fetch failed: " <> inspect(other)}
    end
  end

  defp location(headers, base) do
    case Map.get(headers, "location") do
      [loc | _] when is_binary(loc) -> base |> URI.merge(loc) |> URI.to_string()
      loc when is_binary(loc) -> base |> URI.merge(loc) |> URI.to_string()
      _ -> nil
    end
  end

  defp time_left(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, "fetch timed out"}
  end

  # ---- the rules -------------------------------------------------------------------

  defp parse(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: s, host: h} = uri}
      when s in ["http", "https"] and is_binary(h) and h != "" ->
        {:ok, %{uri | host: String.trim_trailing(h, ".")}}

      _ ->
        {:error, "not an http(s) URL"}
    end
  end

  defp parse(_), do: {:error, "not an http(s) URL"}

  defp allowed_host(_host, nil), do: :ok

  defp allowed_host(host, patterns) when is_list(patterns) do
    if Enum.any?(patterns, &host_matches?(String.downcase(host), String.downcase(&1))),
      do: :ok,
      else: {:error, "#{host} is not in the allowlist"}
  end

  defp host_matches?(host, "*." <> suffix),
    do: String.ends_with?(host, "." <> suffix) or host == suffix

  defp host_matches?(host, pattern), do: host == pattern

  @doc false
  def public_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      # a literal IP: check it directly
      {:ok, ip} ->
        if public_ip?(ip), do: :ok, else: {:error, "#{host} is not a public address"}

      # a name: every address it resolves to must be public (A and AAAA)
      {:error, _} ->
        addrs =
          for fam <- [:inet, :inet6],
              {:ok, {:hostent, _, _, _, _, list}} <- [
                :inet.gethostbyname(String.to_charlist(host), fam)
              ],
              a <- list,
              do: a

        cond do
          addrs == [] -> {:error, "#{host} does not resolve"}
          Enum.all?(addrs, &public_ip?/1) -> :ok
          true -> {:error, "#{host} resolves to a private address"}
        end
    end
  end

  @doc false
  # IPv4
  def public_ip?({10, _, _, _}), do: false
  def public_ip?({127, _, _, _}), do: false
  def public_ip?({0, _, _, _}), do: false
  def public_ip?({169, 254, _, _}), do: false
  def public_ip?({172, b, _, _}) when b in 16..31, do: false
  def public_ip?({192, 168, _, _}), do: false
  def public_ip?({100, b, _, _}) when b in 64..127, do: false
  def public_ip?({a, _, _, _}) when a >= 224, do: false
  def public_ip?({_, _, _, _}), do: true
  # IPv6
  def public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  def public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  def public_ip?({0xFE80, _, _, _, _, _, _, _}), do: false
  def public_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: false
  def public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: false
  # IPv4-mapped IPv6 (::ffff:a.b.c.d)
  def public_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: public_ip?({hi |> div(256), hi |> rem(256), lo |> div(256), lo |> rem(256)})

  def public_ip?({_, _, _, _, _, _, _, _}), do: true
  def public_ip?(_), do: false
end
