defmodule ContextBot.StandardSite.TitlePrompt do
  @moduledoc """
  Reader title style used by the structured research JSON schema and the
  title-only rewrite call.

  Title guidance lives in the structure-phase JSON schema, the structure
  prompt, and the cheap title-rewrite Messages request. This module is the
  shared wording. A blank structure-phase `title` may trigger one title-only
  Haiku call; it is not a compact-reply rewrite.
  """

  @id "READER_TITLE_V2"

  @schema_description """
  Standard Reader page title. Write in the same language as the invoking mention. A Title Case headline of the topic or question, typically 2 to 8 words and at most 80 Unicode grapheme clusters. Summarize what the page is about; do not narrate the mention or greeting. Match this style: Context Bot Launch; What Is That Bird?; The Story on the Yosemite Land Deal; 'The Range of Acceptable Opinion' on Bluesky; Planned Explosion? Do not copy the invocation verbatim, take the first six words, strip @mentions and leave punctuation holes, use a TID or a title that starts with "Context on", copy the compact Bluesky reply, or include @handles unless the handle itself is the subject. No trailing period unless it is part of an abbreviation.
  """

  @prompt """
  READER_TITLE_V2

  Write one Standard Reader page title for the Bluesky invocation below.

  Requirements:
  - Write the title in the same language as the invoking mention
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

  @spec schema_description() :: String.t()
  def schema_description, do: String.trim(@schema_description)

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

  @doc """
  Title-rewrite user turn: invocation plus the page body so the headline is
  about the research, not the mention greeting.
  """
  @spec user_message(String.t(), String.t(), String.t()) :: String.t()
  def user_message(invocation_text, compact_reply, full_response)
      when is_binary(invocation_text) and is_binary(compact_reply) and is_binary(full_response) do
    """
    #{user_message(invocation_text)}
    Compact Bluesky reply:

    #{String.trim(compact_reply)}

    Full research writeup:

    #{String.trim(full_response)}
    """
  end
end
