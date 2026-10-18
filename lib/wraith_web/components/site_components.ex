defmodule WraithWeb.SiteComponents do
  @moduledoc "The public site's pieces: post cards, the rendered body with live widgets, bylines."
  use Phoenix.Component
  use WraithWeb, :verified_routes
  import WraithWeb.CoreComponents, only: [icon: 1]

  alias Wraith.Markdown

  @doc "Render one of the theme's templates (`:index`, `:post`, …) with these assigns."
  attr :theme, :atom, required: true
  attr :page, :atom, required: true
  attr :assigns, :map, required: true

  def theme_page(%{theme: theme, page: page, assigns: page_assigns}) do
    # a function component is a function: the theme's template, called with the page's assigns
    apply(theme, page, [Map.put(page_assigns, :__changed__, nil)])
  end

  @doc "The theme's layout around the page."
  attr :theme, :atom, required: true
  attr :site, :map, required: true
  attr :current_user, :map, default: nil
  attr :current_member, :map, default: nil
  slot :inner_block, required: true

  def theme_layout(%{theme: theme} = assigns) do
    apply(theme, :layout, [Map.delete(assigns, :theme)])
  end

  attr :post, :map, required: true
  attr :authors, :map, default: %{}
  attr :featured, :boolean, default: false

  def post_card(assigns) do
    ~H"""
    <article class={["post-card", @featured && "is-featured"]}>
      <a :if={@post["feature_image"]} href={~p"/#{@post["slug"]}"} class="post-card-image">
        <img src={@post["feature_image"]} alt="" loading="lazy" />
      </a>
      <div class="post-card-body">
        <div class="post-card-tags">
          <.link :for={tag <- Enum.take(@post["tags"] || [], 2)} navigate={~p"/tag/#{tag}"}>{tag}</.link>
        </div>
        <h2 class="post-card-title">
          <.link navigate={~p"/#{@post["slug"]}"}>{@post["title"]}</.link>
        </h2>
        <p class="post-card-excerpt">{@post["excerpt"]}</p>
        <.byline post={@post} authors={@authors} />
      </div>
    </article>
    """
  end

  attr :post, :map, required: true
  attr :authors, :map, default: %{}

  def byline(assigns) do
    author = assigns.authors[assigns.post["author_id"]]
    assigns = assign(assigns, :author, author)

    ~H"""
    <div class="byline">
      <.link :if={@author} navigate={~p"/author/#{@author["slug"]}"} class="byline-author">{@author[
        "name"
      ]}</.link>
      <time :if={@post["published_at"]} datetime={@post["published_at"]}>{date(@post["published_at"])}</time>
      <span class="byline-sep" aria-hidden="true">·</span>
      <span>{Markdown.reading_minutes(@post["markdown"])} min read</span>
    </div>
    """
  end

  @doc "A table of contents from `Wraith.Markdown.toc/1`."
  attr :toc, :list, required: true

  def toc(assigns) do
    ~H"""
    <nav :if={@toc != []} class="toc" aria-label="Contents">
      <span class="toc-title">Contents</span>
      <ol>
        <li :for={h <- @toc} class={"is-h#{h["level"]}"}><a href={"#" <> h["id"]}>{h["text"]}</a></li>
      </ol>
    </nav>
    """
  end

  @doc "Related posts under an article."
  attr :posts, :list, required: true
  attr :authors, :map, default: %{}

  def related(assigns) do
    ~H"""
    <aside :if={@posts != []} class="related" aria-label="Read next">
      <h2 class="related-title">Read next</h2>
      <div class="feed is-related">
        <.post_card :for={p <- @posts} post={p} authors={@authors} />
      </div>
    </aside>
    """
  end

  @doc """
  Comments under a post. `@comments` is `Wraith.Comments.for_post/1`'s tree;
  `@current_member` decides whether the form shows. Events: `comment`
  (`body`, optional `parent_id`), `comment-delete` (`id`), `reply-to` (`id`).
  """
  attr :comments, :list, required: true
  attr :current_member, :map, default: nil
  attr :current_user, :map, default: nil
  attr :reply_to, :string, default: nil
  attr :enabled, :boolean, default: true

  def comments(assigns) do
    ~H"""
    <section :if={@enabled} class="comments" id="comments">
      <h2 class="comments-title">
        {case length(@comments),
          do: (
            0 -> "Comments"
            1 -> "1 comment"
            n -> "#{n} comments"
          )}
      </h2>

      <div
        :for={%{comment: c, replies: replies} <- @comments}
        class="comment"
        id={"comment-" <> c["id"]}
      >
        <.comment_body c={c} current_member={@current_member} current_user={@current_user} />
        <div :if={replies != []} class="comment-replies">
          <div :for={r <- replies} class="comment is-reply" id={"comment-" <> r["id"]}>
            <.comment_body
              c={r}
              current_member={@current_member}
              current_user={@current_user}
              reply={false}
            />
          </div>
        </div>
        <form
          :if={@reply_to == c["id"] and @current_member}
          phx-submit="comment"
          class="comment-form is-reply"
          id={"reply-form-" <> c["id"]}
        >
          <input type="hidden" name="parent_id" value={c["id"]} />
          <textarea name="body" rows="2" placeholder={"Reply to " <> c["member_name"]} required></textarea>
          <div class="comment-form-actions">
            <button type="button" phx-click="reply-to" phx-value-id="" class="btn-ghost is-small">Cancel</button>
            <button type="submit" class="btn-accent is-small">Reply</button>
          </div>
        </form>
      </div>

      <form :if={@current_member} phx-submit="comment" class="comment-form" id="comment-form">
        <textarea name="body" rows="3" placeholder="Join the conversation" required></textarea>
        <div class="comment-form-actions">
          <span class="row-sub">Commenting as {@current_member["name"] || @current_member["email"]}</span>
          <button type="submit" class="btn-accent is-small">Comment</button>
        </div>
      </form>
      <p :if={is_nil(@current_member)} class="comments-signin">
        <.link navigate={~p"/members"}>Sign in</.link> to join the conversation.
      </p>
    </section>
    """
  end

  attr :c, :map, required: true
  attr :current_member, :map, default: nil
  attr :current_user, :map, default: nil
  attr :reply, :boolean, default: true

  defp comment_body(assigns) do
    mine =
      assigns.current_member != nil and assigns.current_member["id"] == assigns.c["member_id"]

    assigns = assign(assigns, :can_remove, mine or assigns.current_user != nil)

    ~H"""
    <div class="comment-head">
      <span class="comment-avatar">{String.first(@c["member_name"] || "?")}</span>
      <span class="comment-author">{@c["member_name"]}</span>
      <time class="comment-time" datetime={@c["created_at"]}>{date(@c["created_at"])}</time>
    </div>
    <p :if={@c["body"] != ""} class="comment-text">{@c["body"]}</p>
    <p :if={@c["body"] == ""} class="comment-text is-removed">[removed]</p>
    <div class="comment-actions">
      <button
        :if={@reply and @current_member}
        phx-click="reply-to"
        phx-value-id={@c["id"]}
        class="link-btn"
      >Reply</button>
      <button
        :if={@can_remove}
        phx-click="comment-delete"
        phx-value-id={@c["id"]}
        data-confirm="Remove this comment?"
        class="link-btn is-danger"
      >Remove</button>
    </div>
    """
  end

  @doc "The rendered post body: HTML segments raw, widget segments live."
  attr :segments, :list, required: true
  attr :widgets, :map, required: true

  def body(assigns) do
    ~H"""
    <div class="prose-wraith">
      <%= for segment <- @segments do %>
        <%= case segment do %>
          <% {:html, html} -> %>
            {Phoenix.HTML.raw(html)}
          <% {:widget, slug, _props, instance} -> %>
            <.widget_frame slug={slug} instance={instance} entry={@widgets[instance]} />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :slug, :string, required: true
  attr :instance, :string, required: true
  attr :entry, :map, default: nil

  def widget_frame(assigns) do
    ~H"""
    <div
      class="widget"
      data-widget={@slug}
      data-instance={@instance}
      id={"widget-" <> dom_id(@instance)}
    >
      <%= case @entry && @entry.html do %>
        <% {:ok, html} -> %>
          {Phoenix.HTML.raw(html)}
        <% {:error, why} -> %>
          <div class="widget-error" role="alert">
            <.icon name="hero-exclamation-triangle" class="size-4" /> {why}
          </div>
        <% _ -> %>
          <div class="widget-loading">…</div>
      <% end %>
    </div>
    """
  end

  attr :page, :integer, required: true
  attr :has_next, :boolean, required: true
  attr :path, :any, required: true, doc: "fn page -> path"

  def pager(assigns) do
    ~H"""
    <nav :if={@page > 1 or @has_next} class="pager" aria-label="Pages">
      <.link :if={@page > 1} navigate={@path.(@page - 1)} class="pager-link">← Newer</.link>
      <span class="pager-page">Page {@page}</span>
      <.link :if={@has_next} navigate={@path.(@page + 1)} class="pager-link">Older →</.link>
    </nav>
    """
  end

  def dom_id(instance), do: instance |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")

  def date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %-d, %Y")
      _ -> iso
    end
  end

  def date(_), do: ""
end
