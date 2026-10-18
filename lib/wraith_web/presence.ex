defmodule WraithWeb.Presence do
  @moduledoc "Who is on which page: one topic per page (`page:<scope>`), tracked by visitor id."
  use Phoenix.Presence, otp_app: :wraith, pubsub_server: Wraith.PubSub
end
