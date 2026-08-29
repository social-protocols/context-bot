defmodule ContextBot.StandardSite.TitlePrompt do
  @moduledoc """
  Dedicated Reader title-completion prompt.

  Kept separate from `CONTEXT_BOT_SYSTEM_V5` so the dual-format research prompt
  hash and published prompt document stay unchanged.
  """

  @id "READER_TITLE_V1"

  @prompt """
  READER_TITLE_V1

  Write one Standard Reader page title for the Bluesky invocation below.

  Requirements:
  - A Title Case headline of the topic or question, typically 2 to 8 words
  - Summarize what the page is about; do not narrate the mention or greeting
  - Match this style:
    - Context Bot Launch
    - What Is That Bird?
    - The Story on the Yosemite Land Deal
    - 'The Range of Acceptable Opinion' on Bluesky
    - Planned Explosion?
  - Do not copy the invocation verbatim
  - Do not take the first six words of the invocation
  - Do not strip @mentions and leave punctuation holes such as "launched . Mention"
  - Do not use a TID, rkey, or a title that starts with "Context on"
  - Do not copy the compact Bluesky reply
  - Do not include @handles unless the handle itself is the subject
  - No trailing period unless it is part of an abbreviation
  - Return only the headline: no quotes, labels, markdown, or preamble
  """

  @spec id() :: String.t()
  def id, do: @id

  @spec prompt() :: String.t()
  def prompt, do: @prompt

  @doc "User turn that supplies the raw invoking-post text, mentions included."
  @spec user_message(String.t()) :: String.t()
  def user_message(invocation_text) when is_binary(invocation_text) do
    """
    Invocation (as written):

    #{String.trim(invocation_text)}
    """
  end
end
