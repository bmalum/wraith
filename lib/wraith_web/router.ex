defmodule WraithWeb.Router do
  use WraithWeb, :router

  import WraithWeb.UserAuth
  import WraithWeb.MemberAuth, only: [fetch_current_member: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WraithWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
    plug :fetch_visitor
    plug :fetch_current_member
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :feed do
    plug :accepts, ["xml", "json"]
  end

  pipeline :public_cache do
    plug WraithWeb.PublicCache
    plug WraithWeb.Locale
  end

  # ---- the public site -----------------------------------------------------------

  scope "/", WraithWeb do
    pipe_through [:browser, :public_cache]

    live_session :site,
      on_mount: [
        {WraithWeb.Locale, :put_locale},
        {WraithWeb.UserAuth, :mount_current_user},
        {WraithWeb.UserAuth, :mount_visitor},
        {WraithWeb.MemberAuth, :mount_current_member}
      ] do
      live "/", Site.HomeLive, :index
      live "/page/:page", Site.HomeLive, :page
      live "/tag/:slug", Site.TagLive, :show
      live "/author/:slug", Site.AuthorLive, :show
      live "/subscribe", Site.SubscribeLive, :new
      live "/members", Site.MemberLive, :account
      live "/search", Site.SearchLive, :index
    end

    get "/members/login/:token", MemberController, :login
    get "/members/confirm/:token", MemberController, :confirm
    get "/members/unsubscribe/:token", MemberController, :unsubscribe
    post "/members/logout", MemberController, :logout
    delete "/members/logout", MemberController, :logout
    get "/members/upgrade", MemberController, :upgrade
    get "/members/portal", MemberController, :portal
    post "/members/delete", MemberController, :delete_account
  end

  # ---- the JSON APIs (Ghost-shaped) ------------------------------------------------

  pipeline :content_api do
    plug :accepts, ["json"]
    plug WraithWeb.RateLimitPlug, scope: :api
    plug WraithWeb.ApiAuth, :content
  end

  pipeline :admin_api do
    plug :accepts, ["json"]
    plug WraithWeb.RateLimitPlug, scope: :api
    plug :fetch_session
    plug :fetch_current_user
    plug WraithWeb.ApiAuth, :admin
  end

  scope "/api/content", WraithWeb.Api do
    pipe_through :content_api
    get "/posts", ContentController, :posts
    get "/posts/:slug", ContentController, :post
    get "/pages", ContentController, :pages
    get "/pages/:slug", ContentController, :post
    get "/tags", ContentController, :tags
    get "/tags/:slug", ContentController, :tag
    get "/authors", ContentController, :authors
    get "/authors/:slug", ContentController, :author
    get "/settings", ContentController, :settings
    get "/members/count", ContentController, :members_count
  end

  scope "/api/admin", WraithWeb.Api do
    pipe_through :admin_api
    get "/posts", AdminController, :posts
    post "/posts", AdminController, :create_post
    get "/posts/:id", AdminController, :post
    put "/posts/:id", AdminController, :update_post
    delete "/posts/:id", AdminController, :delete_post
    get "/tags", AdminController, :tags
    put "/tags/:slug", AdminController, :upsert_tag
    delete "/tags/:slug", AdminController, :delete_tag
    get "/members", AdminController, :members
    get "/members.csv", AdminController, :members_csv
    post "/members", AdminController, :create_member
    post "/members/import", AdminController, :import_members
    get "/widgets", AdminController, :widgets
    put "/widgets", AdminController, :upsert_widget
    get "/settings", AdminController, :settings
    put "/settings", AdminController, :update_settings
    get "/users", AdminController, :users
    get "/db", AdminController, :export
    post "/db", AdminController, :import
  end

  # the MCP server for any agent (Kiro CLI, Claude, Cursor, …)
  pipeline :mcp do
    plug :accepts, ["json"]
    plug WraithWeb.RateLimitPlug, scope: :api
  end

  scope "/mcp", WraithWeb do
    pipe_through :mcp
    post "/", McpController, :handle
    get "/", McpController, :not_allowed
    delete "/", McpController, :close
  end

  scope "/health", WraithWeb do
    get "/", HealthController, :ready
    get "/live", HealthController, :live
  end

  scope "/webhooks", WraithWeb do
    pipe_through :api
    post "/stripe", WebhookController, :stripe
  end

  scope "/", WraithWeb do
    pipe_through :feed
    get "/rss", FeedController, :rss
    get "/tag/:tag/rss", FeedController, :rss
    get "/author/:author/rss", FeedController, :rss
    get "/feed.json", FeedController, :json
    get "/sitemap.xml", FeedController, :sitemap
  end

  # ---- signing in -------------------------------------------------------------------

  pipeline :login_limit do
    plug WraithWeb.RateLimitPlug, scope: :login
  end

  scope "/admin", WraithWeb.Admin do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :auth,
      on_mount: [{WraithWeb.UserAuth, :mount_current_user}, {WraithWeb.UserAuth, :mount_visitor}] do
      live "/setup", SetupLive, :new
      live "/login", LoginLive, :new
      live "/forgot", ResetLive, :forgot
      live "/reset/:token", ResetLive, :reset
    end
  end

  # only the attempt is rate-limited, not viewing the form
  scope "/admin", WraithWeb.Admin do
    pipe_through [:browser, :redirect_if_user_is_authenticated, :login_limit]
    post "/login", SessionController, :create
  end

  # state changes are never GETs: a prefetcher, a link scanner or any site
  # that can make a staff browser navigate must not be able to sign them out
  scope "/admin", WraithWeb.Admin do
    pipe_through :browser
    delete "/logout", SessionController, :delete
    post "/logout", SessionController, :delete
  end

  # ---- the admin --------------------------------------------------------------------

  scope "/admin", WraithWeb.Admin do
    pipe_through [:browser, :require_authenticated_user]

    # creates a draft — a POST, so a crawled or prefetched link can't litter drafts
    post "/posts/new", PostController, :new

    live_session :admin, on_mount: [{WraithWeb.UserAuth, :require_authenticated_user}] do
      live "/", DashboardLive, :index
      live "/posts", PostsLive, :index
      live "/posts/:id", EditorLive, :edit
      live "/pages", PostsLive, :pages
      live "/profile", ProfileLive, :index
    end

    live_session :admin_content,
      on_mount: [
        {WraithWeb.UserAuth, :require_authenticated_user},
        {WraithWeb.UserAuth, {:can, :manage_tags}}
      ] do
      live "/tags", TagsLive, :index
      live "/members", MembersLive, :index
      live "/comments", CommentsLive, :index
      live "/widgets", WidgetsLive, :index
      live "/widgets/new", WidgetEditorLive, :new
      live "/widgets/:slug", WidgetEditorLive, :edit
      live "/studio", StudioLive, :index
    end

    live_session :admin_settings,
      on_mount: [
        {WraithWeb.UserAuth, :require_authenticated_user},
        {WraithWeb.UserAuth, {:can, :manage_settings}}
      ] do
      live "/settings", SettingsLive, :index
      live "/integrations", IntegrationsLive, :index
    end
  end

  if Application.compile_env(:wraith, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: WraithWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # last: a post or page by slug
  scope "/", WraithWeb do
    pipe_through [:browser, :public_cache]

    live_session :post,
      on_mount: [
        {WraithWeb.Locale, :put_locale},
        {WraithWeb.UserAuth, :mount_current_user},
        {WraithWeb.UserAuth, :mount_visitor},
        {WraithWeb.MemberAuth, :mount_current_member}
      ] do
      # a shareable draft preview: anyone with the token, any status
      live "/preview/:token", Site.PostLive, :preview
      live "/:slug", Site.PostLive, :show
    end
  end
end
