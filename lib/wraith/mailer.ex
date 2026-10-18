defmodule Wraith.Mailer do
  @moduledoc "Outgoing mail (Swoosh). Local mailbox in dev (`/dev/mailbox`), Test adapter in tests, SES in prod."
  use Swoosh.Mailer, otp_app: :wraith

  @doc "The From address: `MAIL_FROM` or `noreply@<host>`."
  def from do
    site = Wraith.Settings.get()

    {site["title"],
     Application.get_env(:wraith, :mail_from) ||
       "noreply@" <>
         (Application.get_env(:wraith, WraithWeb.Endpoint)[:url][:host] || "localhost")}
  end
end
