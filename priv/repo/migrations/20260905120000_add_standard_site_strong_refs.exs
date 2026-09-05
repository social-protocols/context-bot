defmodule ContextBot.Repo.Migrations.AddStandardSiteStrongRefs do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :standard_site_document_cid, :text
      add :standard_site_publication_uri, :text
      add :standard_site_publication_cid, :text
    end
  end
end
