defmodule ContextBot.Repo.Migrations.AddFullResponseAndStandardSite do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :full_response, :text
      add :standard_site_document_uri, :text
      add :standard_site_document_rkey, :text
    end
  end
end
