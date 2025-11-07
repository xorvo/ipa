defmodule IpaWeb.PageController do
  use IpaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
