defmodule WraithWeb.Admin.PostController do
  @moduledoc "`/admin/posts/new`: create an empty draft and open it in the editor."
  use WraithWeb, :controller

  alias Wraith.Content

  def new(conn, params) do
    {:ok, post} =
      Content.create_post(%{
        title: "",
        type: if(params["type"] == "page", do: "page", else: "post"),
        author_id: conn.assigns.current_user["id"]
      })

    redirect(conn, to: ~p"/admin/posts/#{post["id"]}")
  end
end
