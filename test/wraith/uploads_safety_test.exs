defmodule Wraith.UploadsSafetyTest do
  @moduledoc "Uploads are checked against their declared type; served documents are sandboxed."
  use WraithWeb.ConnCase, async: false

  alias Wraith.Uploads

  setup do
    File.rm_rf!(Uploads.Local.root())
    :ok
  end

  test "the declared type must match the bytes" do
    {:ok, img} = Image.new(40, 30, color: :red)
    {:ok, png} = Image.write(img, :memory, suffix: ".png")

    assert {:ok, _} = Uploads.store(png, "image/png")
    # PNG bytes dressed as a JPEG, an SVG, a PDF — all refused
    assert {:error, msg} = Uploads.store(png, "image/jpeg")
    assert msg =~ "don't look like"
    assert {:error, _} = Uploads.store(png, "image/svg+xml")
    assert {:error, _} = Uploads.store(png, "application/pdf")
    # and HTML dressed as an image
    assert {:error, _} = Uploads.store("<html><script>alert(1)</script></html>", "image/png")
  end

  test "SVG: inert ones pass, scripted ones are refused" do
    assert {:ok, _} =
             Uploads.store(
               ~s(<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>),
               "image/svg+xml"
             )

    for bad <- [
          ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|,
          ~s|<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>|,
          ~s|<svg xmlns="http://www.w3.org/2000/svg"><a href="javascript:alert(1)"><text>x</text></a></svg>|,
          ~s|<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><body xmlns="http://www.w3.org/1999/xhtml">x</body></foreignObject></svg>|,
          ~s|<svg xmlns="http://www.w3.org/2000/svg"><image href="https://evil.example/x.png"/></svg>|
        ] do
      assert {:error, msg} = Uploads.store(bad, "image/svg+xml"), bad
      assert msg =~ "SVG", bad
    end
  end

  test "uploads are served with nosniff and a sandboxing CSP", %{conn: conn} do
    {:ok, url} =
      Uploads.store(~s(<svg xmlns="http://www.w3.org/2000/svg"/>), "image/svg+xml",
        variants: false
      )

    res = get(conn, url)
    assert res.status == 200
    assert get_resp_header(res, "x-content-type-options") == ["nosniff"]
    assert [csp] = get_resp_header(res, "content-security-policy")
    assert csp =~ "sandbox" and csp =~ "default-src 'none'"
  end
end
