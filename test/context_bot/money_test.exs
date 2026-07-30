defmodule ContextBot.MoneyTest do
  use ExUnit.Case, async: true

  alias ContextBot.Money

  test "parses canonical decimal USD directly into integer microdollars" do
    assert {:ok, 0} = Money.parse_usd("0")
    assert {:ok, 1} = Money.parse_usd("0.000001")
    assert {:ok, 1_200_000} = Money.parse_usd("1.2")
    assert {:ok, 12_345_678} = Money.parse_usd("12.345678")
  end

  test "rejects values that cannot be represented exactly as microdollars" do
    assert {:error, :invalid_usd} = Money.parse_usd("1.0000001")
    assert {:error, :invalid_usd} = Money.parse_usd("1e-6")
    assert {:error, :invalid_usd} = Money.parse_usd("01.00")
    assert {:error, :invalid_usd} = Money.parse_usd(1.25)
  end
end
