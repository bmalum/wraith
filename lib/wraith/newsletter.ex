defmodule Wraith.Newsletter do
  @moduledoc """
  Everything that goes out by mail, built with Swoosh and sent through
  `Wraith.Mailer`:

    * `send_welcome/1` — when a member signs up
    * `send_login_link/1` — a magic sign-in link (`Wraith.Tokens` `:member_login`)
    * `send_post/2` — a published post to every subscribed member, in
      batches of 50 with a per-member unsubscribe link; records the send on
      the post (`NEWSLETTER` item) so it goes out once
    * `send_password_reset/1` — for authors (`Wraith.Accounts`)

  Mail is plain HTML built here (no template engine): the post body is the
  rendered Markdown with widgets replaced by a link to the live page.
  """
  import Swoosh.Email
  alias Wraith.{Accounts, Mailer, Markdown, Members, Settings, Store, Tokens}
  alias Wraith.Store.Keys

  @batch 50

  # ---- members -----------------------------------------------------------------------

  def send_welcome(%{"email" => email} = member) do
    site = Settings.get()

    mail(email, member["name"], "Welcome to #{site["title"]}", """
    <p>Thanks for subscribing to <strong>#{esc(site["title"])}</strong>. New posts will land in this inbox.</p>
    <p><a href="#{url("/")}">Visit the site</a> · <a href="#{login_url(member)}">Sign in</a></p>
    #{footer(member)}
    """)
    |> deliver()
  end

  @doc "Double opt-in: the link that turns a sign-up into a subscriber."
  def send_confirmation(%{"email" => email} = member) do
    site = Settings.get()

    mail(email, member["name"], "Confirm your subscription to #{site["title"]}", """
    <p>One click and you are in: confirm that you want new posts from <strong>#{esc(site["title"])}</strong> in this inbox.</p>
    <p><a href="#{confirm_url(member)}" style="display:inline-block;padding:.6em 1.1em;background:#111;color:#fff;border-radius:6px;text-decoration:none">Confirm subscription</a></p>
    <p style="color:#777">If you did not sign up, ignore this mail and nothing happens.</p>
    """)
    |> deliver()
  end

  def confirm_url(%{"id" => id}), do: url("/members/confirm/" <> Tokens.sign(:confirm, id))

  def send_login_link(%{"email" => email} = member) do
    site = Settings.get()

    mail(email, member["name"], "Sign in to #{site["title"]}", """
    <p>Click to sign in to <strong>#{esc(site["title"])}</strong>. The link is good for an hour.</p>
    <p><a href="#{login_url(member)}" style="display:inline-block;padding:.6em 1.1em;background:#111;color:#fff;border-radius:6px;text-decoration:none">Sign in</a></p>
    <p style="color:#777">If you did not ask for this, ignore it — nobody can sign in without this mail.</p>
    """)
    |> deliver()
  end

  def login_url(%{"id" => id}), do: url("/members/login/" <> Tokens.sign(:member_login, id))

  def unsubscribe_url(%{"id" => id}),
    do: url("/members/unsubscribe/" <> Tokens.sign(:unsubscribe, id))

  # ---- posts ----------------------------------------------------------------------------

  @doc "Has this post gone out as a newsletter?"
  def sent?(%{"id" => id}) do
    {pk, sk} = Keys.newsletter_send(id)
    match?({:ok, _}, Store.get(pk, sk))
  end

  def send_record(%{"id" => id}) do
    {pk, sk} = Keys.newsletter_send(id)

    case Store.get(pk, sk) do
      {:ok, r} -> r
      :error -> nil
    end
  end

  @doc """
  Mail a published post to every subscribed member who may read it (paid
  posts go to paid members only). Returns `{:ok, count}`; `{:error, :already_sent}`
  the second time unless `force: true`.
  """
  def send_post(post, opts \\ [])

  def send_post(%{"status" => "published", "id" => id} = post, opts) do
    # Claim first, send second. A conditional put of the send record is the
    # lock: two nodes (or a retry) racing to send the same post can't both
    # win it, so members never get a newsletter twice. `force` re-sends on
    # purpose and re-claims unconditionally.
    case claim(id, Keyword.get(opts, :force, false)) do
      :ok -> {:ok, deliver_to_members(post)}
      :already_sent -> {:error, :already_sent}
    end
  end

  def send_post(_post, _opts), do: {:error, :not_published}

  defp claim(id, force?) do
    {pk, sk} = Keys.newsletter_send(id)

    record = %{
      "pk" => pk,
      "sk" => sk,
      "post_id" => id,
      "sent_at" => Store.now(),
      "recipients" => 0,
      "status" => "sending"
    }

    if force? do
      :ok = Store.put(record)
      :ok
    else
      case Store.put(record, condition: :not_exists) do
        :ok -> :ok
        {:error, :exists} -> :already_sent
      end
    end
  end

  defp deliver_to_members(post) do
    recipients = Members.subscribed() |> Enum.filter(&Members.can_read?(&1, post["visibility"]))
    site = Settings.get()
    author = post["author_id"] && Accounts.get_user(post["author_id"])
    body = body_html(post)

    sent =
      recipients
      |> Enum.chunk_every(@batch)
      |> Enum.map(fn batch ->
        batch
        |> Enum.map(fn m ->
          mail(m["email"], m["name"], post["title"], """
          <p style="color:#777;font-size:.9em">#{esc(site["title"])}#{if author, do: " · " <> esc(author["name"]), else: ""}</p>
          <h1 style="font-size:1.8em;line-height:1.15;margin:.2em 0 .6em"><a href="#{url("/" <> post["slug"])}" style="color:#111;text-decoration:none">#{esc(post["title"])}</a></h1>
          #{if post["custom_excerpt"], do: "<p style=\"font-size:1.1em;color:#555\">#{esc(post["custom_excerpt"])}</p>", else: ""}
          #{if post["feature_image"], do: "<p><img src=\"#{esc(absolute(post["feature_image"]))}\" alt=\"\" style=\"max-width:100%;border-radius:8px\"></p>", else: ""}
          #{body}
          <p><a href="#{url("/" <> post["slug"])}">Read on the site →</a></p>
          #{footer(m)}
          """)
          |> deliver()
        end)
        |> Enum.count(&match?({:ok, _}, &1))
      end)
      |> Enum.sum()

    {pk, sk} = Keys.newsletter_send(post["id"])

    {:ok, _} =
      Store.update(pk, sk, fn r ->
        Map.merge(r || %{"pk" => pk, "sk" => sk, "post_id" => post["id"]}, %{
          "sent_at" => Store.now(),
          "recipients" => sent,
          "status" => "sent"
        })
      end)

    sent
  end

  @doc "Someone replied to a member's comment."
  def send_reply_notice(%{"email" => email} = member, post, reply) do
    link = url("/" <> post["slug"] <> "#comment-" <> reply["id"])

    mail(
      email,
      member["name"],
      "#{reply["member_name"]} replied to your comment on “#{post["title"]}”",
      """
      <p><strong>#{esc(reply["member_name"])}</strong> replied to your comment on <a href="#{link}">#{esc(post["title"])}</a>:</p>
      <blockquote style="border-left:3px solid #ddd;margin:0;padding:.2em 1em;color:#444">#{esc(reply["body"])}</blockquote>
      <p><a href="#{link}">Read and reply →</a></p>
      #{footer(member)}
      """
    )
    |> deliver()
  end

  @doc "Mail a post (any status) to one author as a test; nothing is recorded."
  def send_test(post, %{"email" => email, "name" => name}) do
    site = Settings.get()

    mail(email, name, "[Test] " <> to_string(post["title"]), """
    <p style="color:#777;font-size:.9em">#{esc(site["title"])} · test send</p>
    <h1 style="font-size:1.8em;line-height:1.15;margin:.2em 0 .6em">#{esc(post["title"])}</h1>
    #{body_html(post)}
    """)
    |> deliver()
  end

  # widgets cannot live in mail: a pointer to the page instead
  defp body_html(post) do
    post["markdown"]
    |> Markdown.strip_paywall()
    |> Markdown.segments(post["id"])
    |> Enum.map_join("\n", fn
      {:html, html} ->
        html

      {:widget, slug, _, _} ->
        ~s(<p style="color:#777"><em>[Interactive #{esc(slug)} — <a href="#{url("/" <> post["slug"])}">open the post</a>]</em></p>)
    end)
  end

  # ---- authors ---------------------------------------------------------------------------

  def send_password_reset(%{"email" => email, "id" => id} = user) do
    site = Settings.get()

    link =
      url("/admin/reset/" <> Tokens.sign(:password_reset, {id, Accounts.reset_binding(user)}))

    mail(email, user["name"], "Reset your #{site["title"]} password", """
    <p>Someone (hopefully you) asked to reset the password for <strong>#{esc(email)}</strong> on #{esc(site["title"])}.</p>
    <p><a href="#{link}" style="display:inline-block;padding:.6em 1.1em;background:#111;color:#fff;border-radius:6px;text-decoration:none">Choose a new password</a></p>
    <p style="color:#777">The link is good for an hour. If you did not ask, ignore this mail.</p>
    """)
    |> deliver()
  end

  # ---- plumbing --------------------------------------------------------------------------

  def mail(to_email, to_name, subject, html) do
    text =
      html
      |> String.replace(~r/<[^>]+>/, "")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    # names and subjects come from readers (the subscribe form, comments);
    # a CR/LF there would start a new mail header
    new()
    |> to({header_safe(to_name), to_email})
    |> from(Mailer.from())
    |> subject(header_safe(subject))
    |> html_body(
      ~s(<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:40em;margin:0 auto;padding:1.5em;color:#111;line-height:1.55">#{html}</div>)
    )
    |> text_body(text)
  end

  def deliver(email), do: Mailer.deliver(email)

  defp footer(member) do
    site = Settings.get()

    ~s(<hr style="border:0;border-top:1px solid #eee;margin:2em 0"><p style="color:#999;font-size:.85em">#{esc(site["title"])} · <a href="#{unsubscribe_url(member)}" style="color:#999">Unsubscribe</a> · <a href="#{url("/members")}" style="color:#999">Manage</a></p>)
  end

  defp url(path), do: WraithWeb.Endpoint.url() <> path
  defp absolute("/" <> _ = path), do: url(path)
  defp absolute(other), do: other
  defp esc(s), do: s |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # one line, no control characters, bounded — safe inside an RFC 5322 header
  defp header_safe(nil), do: ""

  defp header_safe(v) when is_binary(v),
    do:
      v
      |> String.replace(~r/[\r\n\t\x00-\x1f\x7f]+/, " ")
      |> String.trim()
      |> String.slice(0, 200)

  defp header_safe(v), do: header_safe(to_string(v))
end
