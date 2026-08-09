defmodule ContextBot.Repo.Migrations.AddDryRunInvocations do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :target_uri, :text
      add :invocation_text, :text

      add :dry_run, :boolean,
        null: false,
        default: false,
        check: %{
          name: "dry_run_input_check",
          expr:
            "dry_run = 0 OR (target_uri IS NOT NULL AND length(target_uri) > 0 AND " <>
              "invocation_text IS NOT NULL AND length(invocation_text) > 0)"
        }
    end
  end
end
