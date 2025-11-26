defmodule IpaWeb.PageControllerTest do
  use IpaWeb.ConnCase

  test "GET / renders the dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "IPA Dashboard"
  end
end
