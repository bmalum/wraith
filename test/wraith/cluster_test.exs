defmodule Wraith.ClusterTest do
  use Wraith.StoreCase, async: false

  @moduledoc "Two nodes, one studio: the second node's Studio.Server defers to the first's."

  test "the studio is one per cluster" do
    # this node already runs the studio; a peer that boots the same supervisor must :ignore its own
    assert is_pid(:global.whereis_name(Wraith.Studio.Server))
    assert :ignore = Wraith.Studio.Server.start_link([])
    # calls through the public API still reach the one owner
    assert %{phase: _} = Wraith.Studio.state()
  end

  test "search answers after a rebuild on this node" do
    :ok = Wraith.Search.rebuild()
    assert Wraith.Search.search("anything") == []
  end
end
