defmodule ContextBot.Research.PricingTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Pricing

  test "prices Sonnet usage with rational microdollar rates and one final ceiling" do
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    usage = %{
      "input_tokens" => 3,
      "cache_creation_input_tokens" => 7,
      "cache_creation" => %{
        "ephemeral_5m_input_tokens" => 3,
        "ephemeral_1h_input_tokens" => 4
      },
      "cache_read_input_tokens" => 6,
      "output_tokens" => 2,
      "thinking_tokens" => 99_999,
      "server_tool_use" => %{"web_search_requests" => 1}
    }

    # 3*2 + 3*2.5 + 4*4 + 6*0.2 + 2*10 + 1*10_000 = 10_050.7.
    assert {:ok, 10_051} = Pricing.calculate(usage, pricing)
  end

  test "does not price aggregate cache writes in addition to their duration breakdown" do
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    usage = %{
      input_tokens: 0,
      cache_creation_input_tokens: 2,
      cache_creation: %{
        ephemeral_5m_input_tokens: 1,
        ephemeral_1h_input_tokens: 1
      },
      cache_read_input_tokens: 0,
      output_tokens: 0,
      server_tool_use: %{web_search_requests: 0}
    }

    # One 5-minute write and one one-hour write cost 6.5 microdollars, rounded once.
    assert {:ok, 7} = Pricing.calculate(usage, pricing)
  end

  test "rounds fractional cache-read exposure up to a whole microdollar" do
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    assert {:ok, 1} =
             Pricing.calculate(
               %{
                 input_tokens: 0,
                 cache_creation_input_tokens: 0,
                 cache_creation: %{
                   ephemeral_5m_input_tokens: 0,
                   ephemeral_1h_input_tokens: 0
                 },
                 cache_read_input_tokens: 1,
                 output_tokens: 0,
                 server_tool_use: %{web_search_requests: 0}
               },
               pricing
             )
  end

  test "rejects usage that cannot be priced safely" do
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    assert {:error, :unsafe_usage} =
             Pricing.calculate(%{"input_tokens" => -1, "output_tokens" => 0}, pricing)

    assert {:error, :unsafe_usage} =
             Pricing.calculate(%{"input_tokens" => 1, "output_tokens" => "2"}, pricing)
  end

  test "rejects incomplete billing usage instead of pricing missing fields as zero" do
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    complete = %{
      input_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_creation: %{
        ephemeral_5m_input_tokens: 0,
        ephemeral_1h_input_tokens: 0
      },
      cache_read_input_tokens: 0,
      output_tokens: 0,
      server_tool_use: %{web_search_requests: 0}
    }

    for missing <- [
          :input_tokens,
          :cache_creation_input_tokens,
          :cache_read_input_tokens,
          :output_tokens,
          :server_tool_use
        ] do
      assert {:error, :unsafe_usage} = Pricing.calculate(Map.delete(complete, missing), pricing)
    end

    assert {:error, :unsafe_usage} =
             Pricing.calculate(put_in(complete, [:server_tool_use], %{}), pricing)
  end

  test "rejects unknown pricing versions" do
    assert_raise ArgumentError, ~r/unknown pricing version/, fn ->
      Pricing.fetch!("future-price")
    end
  end

  test "carries a provider-side context ceiling for conservative request exposure" do
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    assert pricing.max_context_tokens == 1_000_000

    assert {:ok, 4_000_000} =
             Pricing.calculate(
               %{
                 input_tokens: 0,
                 cache_creation_input_tokens: pricing.max_context_tokens,
                 cache_creation: %{
                   ephemeral_5m_input_tokens: 0,
                   ephemeral_1h_input_tokens: pricing.max_context_tokens
                 },
                 cache_read_input_tokens: 0,
                 output_tokens: 0,
                 server_tool_use: %{web_search_requests: 0}
               },
               pricing
             )
  end
end
