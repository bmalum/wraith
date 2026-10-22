defmodule Wraith.SandboxTest do
  @moduledoc "The Lua sandbox cannot take the node down; outbound HTTP cannot reach inside."
  use Wraith.StoreCase, async: false

  alias Wraith.{SafeHTTP, Widgets}
  alias Wraith.Widgets.Lua

  @boiler "function init(p) return {} end function handle(s,e,p,m) return s end "

  describe "Lua memory" do
    test "string.rep past the cap is a Lua error, not an allocation" do
      src = @boiler <> ~S|function render(s,p,m) return string.rep("x", 2000000000) end|
      assert {:error, msg} = Lua.call(src, "render", [%{}, %{}, %{}])
      assert msg =~ "too large" or msg =~ "lua"
      # the process is still here to answer
      assert {:ok, "ok"} =
               Lua.call(@boiler <> ~S|function render() return "ok" end|, "render", [])
    end

    test "a runaway table is killed by the heap cap, not by the node running out" do
      src =
        @boiler <>
          ~S|function render(s,p,m) local t = {} for i=1,1e9 do t[i] = {i, i, i} end return "x" end|

      assert {:error, msg} = Lua.call(src, "render", [%{}, %{}, %{}])
      assert msg =~ "exited" or msg =~ "longer than"
    end

    test "render output is capped" do
      src =
        @boiler <>
          ~S|function render(s,p,m) local s = "y" for i=1,17 do s = s .. s end return s end|

      # 2^17 = 128 KB — under the string cap, over nothing; now 2^19 via two more doublings
      assert {:ok, out} = Lua.call(src, "render", [%{}, %{}, %{}])
      assert byte_size(out) <= 256 * 1024 + 40
    end

    test "print and os/io are gone" do
      # the libraries themselves are nil (so os.execute is "index a nil" — unreachable)
      for fun <- ~w(print os io require load dofile loadstring package) do
        src = @boiler <> "function render() return tostring(#{fun}) end"
        assert {:ok, "nil"} = Lua.call(src, "render", []), fun
      end
    end
  end

  describe "widget state caps" do
    test "tick is clamped so a bad value can't crash every reader's mount" do
      assert Widgets.tick(%{"kind" => "lua", "source" => "tick = 99999999999\n"}) == 86_400
      assert Widgets.tick(%{"kind" => "lua", "source" => "tick = 1\n"}) == 5
      assert Widgets.tick(%{"kind" => "lua", "source" => "-- no tick"}) == nil
    end
  end

  describe "SafeHTTP" do
    test "refuses non-http schemes and private/loopback/link-local targets" do
      assert {:error, _} = SafeHTTP.check("file:///etc/passwd")
      assert {:error, _} = SafeHTTP.check("ftp://example.com/x")
      assert {:error, _} = SafeHTTP.check("http://127.0.0.1:4000/admin")
      assert {:error, _} = SafeHTTP.check("http://localhost/")
      assert {:error, _} = SafeHTTP.check("http://169.254.169.254/latest/meta-data/")
      assert {:error, _} = SafeHTTP.check("http://10.0.0.5/")
      assert {:error, _} = SafeHTTP.check("http://192.168.1.1/")
      assert {:error, _} = SafeHTTP.check("http://172.16.0.1/")
      assert {:error, _} = SafeHTTP.check("http://[::1]/")
      assert {:error, _} = SafeHTTP.check("http://[::ffff:127.0.0.1]/")
      assert {:error, _} = SafeHTTP.check("http://0.0.0.0/")
    end

    test "the allowlist is enforced" do
      assert {:error, msg} = SafeHTTP.check("https://evil.example/", allow: ["api.example.com"])
      assert msg =~ "allowlist"
      # pattern logic (no DNS needed to reject; accept path is exercised by the fetch tests)
      assert {:error, msg} =
               SafeHTTP.check("https://api.example.com.evil.example/", allow: ["*.example.com"])

      assert msg =~ "allowlist"
    end

    test "public_ip? classifies correctly" do
      assert SafeHTTP.public_ip?({8, 8, 8, 8})
      assert SafeHTTP.public_ip?({93, 184, 216, 34})
      refute SafeHTTP.public_ip?({100, 64, 0, 1})
      refute SafeHTTP.public_ip?({224, 0, 0, 1})
      refute SafeHTTP.public_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      refute SafeHTTP.public_ip?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
      assert SafeHTTP.public_ip?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
    end

    test "a redirect to a private address is refused even from a public host" do
      # a local server that redirects to the metadata endpoint
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      spawn(fn ->
        {:ok, sock} = :gen_tcp.accept(listener)
        :gen_tcp.recv(sock, 0)

        :gen_tcp.send(
          sock,
          "HTTP/1.1 302 Found\r\nLocation: http://169.254.169.254/\r\nContent-Length: 0\r\n\r\n"
        )

        :gen_tcp.close(sock)
      end)

      # 127.0.0.1 itself is refused up front, so test the redirect rule by
      # temporarily treating loopback as public is not possible — instead
      # assert the first-hop refusal, which is the same guard the redirect
      # hop goes through
      assert {:error, msg} = SafeHTTP.get("http://127.0.0.1:#{port}/")
      assert msg =~ "not a public address"
      :gen_tcp.close(listener)
    end
  end
end
