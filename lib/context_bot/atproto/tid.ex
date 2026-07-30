defmodule ContextBot.ATProto.TID do
  @moduledoc """
  Encodes timestamps as sortable, 13-character ATProto record keys.
  """

  import Bitwise

  @alphabet "234567abcdefghijklmnopqrstuvwxyz"
  @clock_id_bits 10
  @clock_id_range 1 <<< @clock_id_bits
  @max_timestamp (1 <<< 53) - 1
  @tid_length 13

  @spec generate(integer()) :: binary()
  def generate(timestamp_us)
      when is_integer(timestamp_us) and timestamp_us >= 0 and timestamp_us <= @max_timestamp do
    timestamp_us
    |> bsl(@clock_id_bits)
    |> bor(clock_id())
    |> encode()
  end

  defp clock_id do
    System.unique_integer([:positive, :monotonic])
    |> rem(@clock_id_range)
  end

  defp encode(value) do
    value
    |> Integer.digits(32)
    |> Enum.map_join(&encode_digit/1)
    |> String.pad_leading(@tid_length, "2")
  end

  defp encode_digit(index), do: String.at(@alphabet, index)
end
