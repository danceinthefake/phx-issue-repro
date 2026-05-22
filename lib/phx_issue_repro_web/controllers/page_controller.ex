defmodule PhxIssueReproWeb.PageController do
  use PhxIssueReproWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
