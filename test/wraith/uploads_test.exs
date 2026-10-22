defmodule Wraith.UploadsTest do
  use WraithWeb.ConnCase, async: false
  alias Wraith.Uploads

  setup do
    File.rm_rf!(Uploads.Local.root())
    :ok
  end

  test "stores an image under a dated key and serves it from /uploads" do
    png = WraithWeb.ConnCase.png_fixture()

    assert {:ok, "/uploads/" <> key = url} =
             Uploads.store(png, "image/png", name: "My Photo.PNG", variants: false)

    assert key =~ ~r"^\d{4}/\d{2}/my-photo-[0-9a-f]{8}\.png$"
    assert File.read!(Path.join(Uploads.Local.root(), key)) == png
    conn = build_conn() |> get(url)
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "image/png"
    :ok = Uploads.delete(key)
    refute File.exists?(Path.join(Uploads.Local.root(), key))
  end

  test "refuses wrong types and oversize files" do
    assert {:error, msg} = Uploads.store("x", "application/x-sh")
    assert msg =~ "not an accepted type"

    assert {:error, msg} =
             Uploads.store(:binary.copy(<<0>>, Uploads.max_bytes() + 1), "image/png")

    assert msg =~ "larger than"
  end
end
