defmodule ContextBot.Money do
  @moduledoc """
  Exact conversion between canonical decimal USD strings and integer microdollars.
  """

  @microdollars_per_dollar 1_000_000
  @usd_pattern ~r/\A(0|[1-9]\d*)(?:\.(\d{1,6}))?\z/

  @spec parse_usd(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_usd}
  def parse_usd(value) when is_binary(value) do
    case Regex.run(@usd_pattern, value, capture: :all_but_first) do
      [dollars] ->
        {:ok, String.to_integer(dollars) * @microdollars_per_dollar}

      [dollars, fractional] ->
        microdollars = fractional |> String.pad_trailing(6, "0") |> String.to_integer()
        {:ok, String.to_integer(dollars) * @microdollars_per_dollar + microdollars}

      nil ->
        {:error, :invalid_usd}
    end
  end

  def parse_usd(_value), do: {:error, :invalid_usd}

  @spec parse_usd!(term(), String.t()) :: non_neg_integer()
  def parse_usd!(value, name \\ "USD amount") do
    case parse_usd(value) do
      {:ok, microdollars} -> microdollars
      {:error, :invalid_usd} -> raise ArgumentError, "#{name} must be a decimal USD amount"
    end
  end
end
