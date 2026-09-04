defmodule ContextBot.Repo.Migrations.AddFollowerPostFields do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :follower_post_rkey, :text
      add :follower_post_record, :map
      add :follower_post_uri, :text
      add :follower_post_cid, :text
    end

    create unique_index(:invocations, [:follower_post_rkey])
  end
end
