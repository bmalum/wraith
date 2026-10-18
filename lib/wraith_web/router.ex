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

  # ---- the public site -----------------------------------------------------------

  scope "/", WraithWeb do
    pipe_through :browser

    live_session :site,
      on_mount: [
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
    end

    get "/members/login/:token", MemberController, :login
    get "/members/unsubscribe/:token", MemberController, :unsubscribe
    get "/members/logout", MemberController, :logout
    get "/members/upgrade", MemberController, :upgrade
  end

  scope "/webhooks", WraithWeb do
    pipe_through :api
    post "/stripe", WebhookController, :stripe
  end

  scope "/", WraithWeb do
    pipe_through :feed
    get "/rss", FeedController, :rss
    get "/feed.json", FeedController, :json
    get "/sitemap.xml", FeedController, :sitemap
  end

  # ---- signing in -------------------------------------------------------------------

  scope "/admin", WraithWeb.Admin do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :auth, on_mount: [{WraithWeb.UserAuth, :mount_current_user}] do
      live "/setup", SetupLive, :new
      live "/login", LoginLive, :new
    end

    post "/login", SessionController, :create
  end

  scope "/admin", WraithWeb.Admin do
    pipe_through :browser
    delete "/logout", SessionController, :delete
    get "/logout", SessionController, :delete
  end

  # ---- the admin --------------------------------------------------------------------

  scope "/admin", WraithWeb.Admin do
    pipe_through [:browser, :require_authenticated_user]

    get "/posts/new", PostController, :new

    live_session :admin, on_mount: [{WraithWeb.UserAuth, :require_authenticated_user}] do
      live "/", DashboardLive, :index
      live "/posts", PostsLive, :index
      live "/posts/:id", EditorLive, :edit
      live "/pages", PostsLive, :pages
      live "/tags", TagsLive, :index
      live "/members", MembersLive, :index
      live "/comments", CommentsLive, :index
      live "/widgets", WidgetsLive, :index
      live "/widgets/new", WidgetEditorLive, :new
      live "/widgets/:slug", WidgetEditorLive, :edit
      live "/studio", StudioLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  if Application.compile_env(:wraith, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: WraithWeb.Telemetry
    end
  end

  # last: a post or page by slug
  scope "/", WraithWeb do
    pipe_through :browser

    live_session :post,
      on_mount: [
        {WraithWeb.UserAuth, :mount_current_user},
        {WraithWeb.UserAuth, :mount_visitor},
        {WraithWeb.MemberAuth, :mount_current_member}
      ] do
      live "/:slug", Site.PostLive, :show
    end
  end
end
