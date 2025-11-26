defmodule IpaWeb.Router do
  use IpaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IpaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", IpaWeb do
    pipe_through :browser

    # Dashboard - main entry point
    live "/", DashboardLive, :index

    # Pod detail view
    live "/pods/:task_id", Pod.TaskLive, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", IpaWeb do
  #   pipe_through :api
  # end

  if Application.compile_env(:ipa, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: IpaWeb.Telemetry
    end
  end
end
