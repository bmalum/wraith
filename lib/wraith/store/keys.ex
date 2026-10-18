defmodule Wraith.Store.Keys do
  @moduledoc """
  Where every entity lives in the one table. All keys are built here so the
  layout is readable in one place.

  | entity | pk | sk | gsi1pk | gsi1sk |
  |---|---|---|---|---|
  | site settings | `SITE` | `SETTINGS` | | |
  | user (author) | `USER#id` | `USER` | `USERS` | `email` |
  | user by email | `EMAIL#email` | `USER` | | |
  | auth session | `TOKEN#hash` | `SESSION` | `SESSIONS#user_id` | `created_at` |
  | post | `POST#id` | `POST` | `POSTS#status` | `sort_at#id` |
  | post by slug | `SLUG#slug` | `POST` | | |
  | post revision | `POST#id` | `REV#at` | | |
  | post in tag | `TAG#slug` | `POST#sort_at#id` | | |
  | post by author | `AUTHOR#user_id` | `POST#sort_at#id` | | |
  | tag | `TAG#slug` | `TAG` | `TAGS` | `name` |
  | member | `MEMBER#id` | `MEMBER` | `MEMBERS` | `created_at#id` |
  | member by email | `MEMBER_EMAIL#email` | `MEMBER` | | |
  | widget | `WIDGET#slug` | `WIDGET` | `WIDGETS` | `name` |
  | widget version | `WIDGET#slug` | `VER#n` | | |
  | widget state | `WSTATE#widget#instance` | `STATE` | | |
  | studio session | `STUDIO` | `SESSION#id` | | |
  | studio transcript | `STUDIO#session_id` | `MSG#at#seq` | | |
  """

  def site, do: {"SITE", "SETTINGS"}

  def user(id), do: {"USER#" <> id, "USER"}
  def user_email(email), do: {"EMAIL#" <> String.downcase(email), "USER"}
  def users_index, do: "USERS"

  def session(token_hash), do: {"TOKEN#" <> token_hash, "SESSION"}
  def sessions_index(user_id), do: "SESSIONS#" <> user_id

  def post(id), do: {"POST#" <> id, "POST"}
  def post_slug(slug), do: {"SLUG#" <> slug, "POST"}
  def post_revision(id, at), do: {"POST#" <> id, "REV#" <> at}
  def post_revisions_prefix, do: "REV#"
  def posts_index(status), do: "POSTS#" <> to_string(status)
  def post_sort(sort_at, id), do: sort_at <> "#" <> id

  def tag(slug), do: {"TAG#" <> slug, "TAG"}
  def tags_index, do: "TAGS"
  def tag_post(tag_slug, sort_at, id), do: {"TAG#" <> tag_slug, "POST#" <> post_sort(sort_at, id)}
  def tag_posts_prefix, do: "POST#"

  def author_post(user_id, sort_at, id),
    do: {"AUTHOR#" <> user_id, "POST#" <> post_sort(sort_at, id)}

  def author_posts_pk(user_id), do: "AUTHOR#" <> user_id

  def member(id), do: {"MEMBER#" <> id, "MEMBER"}
  def member_session(token_hash), do: {"MTOKEN#" <> token_hash, "SESSION"}
  def stripe_customer(customer_id), do: {"STRIPE#" <> customer_id, "MEMBER"}
  def member_email(email), do: {"MEMBER_EMAIL#" <> String.downcase(email), "MEMBER"}
  def members_index, do: "MEMBERS"

  def widget(slug), do: {"WIDGET#" <> slug, "WIDGET"}
  def widget_version(slug, n), do: {"WIDGET#" <> slug, "VER#" <> pad(n)}
  def widget_versions_prefix, do: "VER#"
  def widgets_index, do: "WIDGETS"
  def widget_state(widget, instance), do: {"WSTATE#" <> widget <> "#" <> instance, "STATE"}

  def comment(post_id, sort), do: {"POST#" <> post_id, "COMMENT#" <> sort}
  def comments_prefix, do: "COMMENT#"
  def comments_index(status), do: "COMMENTS#" <> status
  def api_key(id), do: {"APIKEY#" <> id, "KEY"}
  def api_keys_index, do: "APIKEYS"
  def newsletter_send(post_id), do: {"POST#" <> post_id, "NEWSLETTER"}

  def studio_session(id), do: {"STUDIO", "SESSION#" <> id}
  def studio_sessions_prefix, do: "SESSION#"

  def studio_message(session_id, at, seq),
    do: {"STUDIO#" <> session_id, "MSG#" <> at <> "#" <> pad(seq)}

  def studio_messages_pk(session_id), do: "STUDIO#" <> session_id

  @doc "Zero-padded so lexical order is numeric order."
  def pad(n) when is_integer(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")
end
