defmodule WraithWeb.NotFound do
  @moduledoc "Raised by a LiveView when the URL names nothing; Plug turns it into a 404."
  defexception [:message, plug_status: 404]
end
