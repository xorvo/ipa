defmodule Ipa.Repo do
  use Ecto.Repo,
    otp_app: :ipa,
    adapter: Ecto.Adapters.Postgres
end
