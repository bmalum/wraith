defmodule Wraith.Policy do
  @moduledoc """
  Who may do what, Ghost's staff roles:

    * `owner` — everything, including settings, billing, API keys and staff
    * `admin` — everything but transferring ownership
    * `editor` — every post, tags, members, comments; not settings or staff
    * `author` — their own posts (create, edit, publish, delete), their profile
    * `contributor` — their own drafts; cannot publish or delete published work

  `can?(user, action, subject)` answers it; LiveViews call it before writing
  and the rail hides what a role may not reach.
  """

  @roles ~w(owner admin editor author contributor)
  def roles, do: @roles

  @type action ::
          :manage_settings
          | :manage_staff
          | :manage_members
          | :manage_comments
          | :manage_widgets
          | :manage_tags
          | :use_studio
          | :manage_keys
          | :edit_post
          | :publish_post
          | :delete_post
          | :create_post
          | :send_newsletter

  @spec can?(map() | nil, action(), map() | nil) :: boolean()
  def can?(nil, _action, _subject), do: false

  def can?(%{"role" => role}, action, _subject)
      when role in ["owner", "admin"] and action != :transfer_ownership, do: true

  def can?(%{"role" => "owner"}, :transfer_ownership, _), do: true

  def can?(%{"role" => "editor"}, action, _subject),
    do:
      action in [
        :edit_post,
        :publish_post,
        :delete_post,
        :create_post,
        :send_newsletter,
        :manage_tags,
        :manage_members,
        :manage_comments,
        :manage_widgets,
        :use_studio
      ]

  def can?(%{"role" => "author"} = u, action, post)
      when action in [:edit_post, :publish_post, :delete_post, :send_newsletter],
      do: own?(u, post)

  def can?(%{"role" => "author"}, action, _), do: action in [:create_post, :manage_widgets]

  def can?(%{"role" => "contributor"} = u, :edit_post, post),
    do: own?(u, post) and post["status"] == "draft"

  def can?(%{"role" => "contributor"} = u, :delete_post, post),
    do: own?(u, post) and post["status"] == "draft"

  def can?(%{"role" => "contributor"}, :create_post, _), do: true
  def can?(%{"role" => "contributor"}, _action, _), do: false

  def can?(_user, _action, _subject), do: false

  defp own?(%{"id" => uid}, %{} = post),
    do: post["author_id"] == uid or uid in (post["authors"] || [])

  defp own?(_, _), do: false

  @doc "The roles a user may assign: owners hand out anything but owner; admins the same."
  def assignable(%{"role" => r}) when r in ["owner", "admin"],
    do: ~w(admin editor author contributor)

  def assignable(_), do: []
end
