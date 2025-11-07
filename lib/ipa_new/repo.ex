defmodule IpaNew.Repo do
  use Ecto.Repo,
    otp_app: :ipa_new,
    adapter: Ecto.Adapters.Postgres
end
