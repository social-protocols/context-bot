defmodule ContextBot.Repo.Migrations.AddReplyPart3Fields do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :reply_part3_rkey, :text
      add :reply_part3_record, :map
      add :reply_part3_uri, :text
      add :reply_part3_cid, :text
    end
  end
end
