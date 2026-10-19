defmodule Wraith.ImagesTest do
  use Wraith.StoreCase, async: false

  alias Wraith.{Images, Uploads}

  setup do
    File.rm_rf!(Uploads.Local.root())
    # a 1200×800 PNG made by libvips itself — a real raster, not a fixture file
    {:ok, img} = Image.new(1200, 800, color: :blue)
    {:ok, png} = Image.write(img, :memory, suffix: ".png")
    {:ok, png: png}
  end

  test "dimensions of a raster", %{png: png} do
    assert %{width: 1200, height: 800} = Images.dimensions(png)
    assert Images.dimensions("not an image") == nil
  end

  test "store_image returns the URL and dimensions; variants land beside it", %{png: png} do
    assert {:ok, url, %{width: 1200, height: 800}} = Uploads.store_image(png, "image/png")
    assert String.starts_with?(url, "/uploads/")
    key = String.trim_leading(url, "/uploads/")

    # variants are written off the request path; wait for the task
    Task.Supervisor.children(Wraith.TaskSupervisor)
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
    end)

    # 480 and 960 are below the 1200 source; 1600 is not, so it isn't written
    assert File.exists?(Path.join(Uploads.Local.root(), key <> ".w480.webp"))
    assert File.exists?(Path.join(Uploads.Local.root(), key <> ".w960.webp"))
    refute File.exists?(Path.join(Uploads.Local.root(), key <> ".w1600.webp"))

    # and they really are smaller
    {:ok, small} = File.read(Path.join(Uploads.Local.root(), key <> ".w480.webp"))
    assert %{width: 480} = Images.dimensions(small)
  end

  test "srcset is derived from our URLs only" do
    assert Images.srcset("/uploads/2026/10/x.jpg") ==
             "/uploads/2026/10/x.jpg.w480.webp 480w, /uploads/2026/10/x.jpg.w960.webp 960w, /uploads/2026/10/x.jpg.w1600.webp 1600w"

    assert Images.srcset("/uploads/2026/10/x.svg") == nil
    assert Images.srcset("/uploads/2026/10/x.gif") == nil
    assert Images.srcset("https://elsewhere.example/pic.jpg") == nil
    assert Images.srcset("/images/demo/night.svg") == nil
    assert Images.srcset(nil) == nil
  end

  test "svg uploads are left alone" do
    svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"/>)
    assert {:ok, _url, nil} = Uploads.store_image(svg, "image/svg+xml")
    assert Task.Supervisor.children(Wraith.TaskSupervisor) == []
  end
end

defmodule Wraith.UploadsLibraryTest do
  use Wraith.StoreCase, async: false

  alias Wraith.Uploads

  setup do
    File.rm_rf!(Uploads.Local.root())
    :ok
  end

  test "the library lists originals only, newest first" do
    {:ok, img} = Image.new(900, 600, color: :red)
    {:ok, png} = Image.write(img, :memory, suffix: ".png")

    {:ok, url1} = Uploads.store(png, "image/png", name: "first")
    {:ok, url2} = Uploads.store(png, "image/png", name: "second")
    {:ok, _pdf} = Uploads.store("%PDF-1.4", "application/pdf", name: "doc")

    # let the variant tasks finish so variants exist on disk to be filtered out
    Task.Supervisor.children(Wraith.TaskSupervisor)
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
    end)

    list = Uploads.list()
    urls = Enum.map(list, & &1.url)
    assert urls == [url2, url1]
    refute Enum.any?(list, &Uploads.variant_key?(&1.key))
    refute Enum.any?(urls, &String.ends_with?(&1, ".pdf"))
    assert Uploads.list(limit: 1) |> length() == 1
  end
end
