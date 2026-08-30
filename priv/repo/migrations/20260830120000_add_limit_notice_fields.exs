defmodule ContextBot.Repo.Migrations.AddLimitNoticeFields do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :limit_notice_kind, :text
      add :limit_notice_uri, :text
      add :limit_notice_cid, :text
      add :limit_notice_posted_at, :utc_datetime_usec
    end
  end
end
