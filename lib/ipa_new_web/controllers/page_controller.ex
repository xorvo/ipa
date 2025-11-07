defmodule IpaNewWeb.PageController do
  use IpaNewWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
