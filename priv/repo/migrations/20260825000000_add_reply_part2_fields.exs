defmodule ContextBot.Repo.Migrations.AddReplyPart2Fields do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :reply_part2_rkey, :text
      add :reply_part2_record, :map
      add :reply_part2_uri, :text
      add :reply_part2_cid, :text
    end
  end
end
