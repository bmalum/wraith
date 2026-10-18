defmodule WraithWeb.Forbidden do
  @moduledoc "Raised when a role may not do what the request asks; Plug turns it into a 403."
  defexception [:message, plug_status: 403]
end
