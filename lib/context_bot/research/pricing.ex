defmodule ContextBot.Research.Pricing do
  @moduledoc """
  Versioned Anthropic pricing using integer rational arithmetic.

  `output_tokens` already includes thinking tokens, so separately reported thinking fields are
  intentionally not added. The aggregate cache-write count is validated against, but never added
  to, the duration-specific counts.
  """

  @version "sonnet-5-2026-07-28"

  @enforce_keys [
    :version,
    :input,
    :cache_write_5m,
    :cache_write_1h,
    :cache_read,
    :output,
    :web_search,
    :max_context_tokens
  ]
  defstruct [
    :version,
    :input,
    :cache_write_5m,
    :cache_write_1h,
    :cache_read,
    :output,
    :web_search,
    :max_context_tokens
  ]

  @type rate :: {pos_integer(), pos_integer()}
  @type t :: %__MODULE__{
          version: String.t(),
          input: rate(),
          cache_write_5m: rate(),
          cache_write_1h: rate(),
          cache_read: rate(),
          output: rate(),
          web_search: rate(),
          max_context_tokens: pos_integer()
        }

  @spec current() :: t()
  def current do
    %__MODULE__{
      version: @version,
      input: {2, 1},
      cache_write_5m: {5, 2},
      cache_write_1h: {4, 1},
      cache_read: {1, 5},
      output: {10, 1},
      web_search: {10_000, 1},
      max_context_tokens: 1_000_000
    }
  end

  @spec fetch(String.t()) :: {:ok, t()} | {:error, :unknown_pricing_version}
  def fetch(@version), do: {:ok, current()}
  def fetch(_version), do: {:error, :unknown_pricing_version}

  @spec fetch!(String.t()) :: t()
  def fetch!(version) do
    case fetch(version) do
      {:ok, pricing} ->
        pricing

      {:error, :unknown_pricing_version} ->
        raise ArgumentError, "unknown pricing version: #{inspect(version)}"
    end
  end

  @spec calculate(map(), t()) :: {:ok, non_neg_integer()} | {:error, :unsafe_usage}
  def calculate(usage, %__MODULE__{} = pricing) when is_map(usage) do
    with {:ok, input} <- required_count(usage, :input_tokens),
         {:ok, output} <- required_count(usage, :output_tokens),
         {:ok, cache_read} <- required_count(usage, :cache_read_input_tokens),
         {:ok, cache_write_aggregate} <-
           required_count(usage, :cache_creation_input_tokens),
         {:ok, cache_creation} <- child_map(usage, :cache_creation),
         {:ok, cache_write_5m} <- count(cache_creation, :ephemeral_5m_input_tokens),
         {:ok, cache_write_1h} <- count(cache_creation, :ephemeral_1h_input_tokens),
         :ok <-
           validate_cache_aggregate(
             cache_write_aggregate,
             cache_write_5m + cache_write_1h
           ),
         {:ok, web_search} <- web_search_requests(usage) do
      cost =
        {0, 1}
        |> add_cost(input, pricing.input)
        |> add_cost(cache_write_5m, pricing.cache_write_5m)
        |> add_cost(cache_write_1h, pricing.cache_write_1h)
        |> add_cost(cache_read, pricing.cache_read)
        |> add_cost(output, pricing.output)
        |> add_cost(web_search, pricing.web_search)

      {:ok, ceil_rational(cost)}
    else
      _unsafe -> {:error, :unsafe_usage}
    end
  end

  def calculate(_usage, %__MODULE__{}), do: {:error, :unsafe_usage}

  @spec maximum_cost(map(), t()) :: {:ok, non_neg_integer()} | {:error, :unsafe_usage}
  def maximum_cost(maximum_usage, pricing), do: calculate(maximum_usage, pricing)

  defp count(map, key) do
    case fetch(map, key, 0) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _unsafe -> {:error, :unsafe_usage}
    end
  end

  defp required_count(map, key) do
    case fetch_required(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _unsafe -> {:error, :unsafe_usage}
    end
  end

  defp child_map(map, key) do
    case fetch(map, key, %{}) do
      value when is_map(value) -> {:ok, value}
      _unsafe -> {:error, :unsafe_usage}
    end
  end

  defp web_search_requests(usage) do
    case fetch(usage, :server_tool_use, nil) do
      nil ->
        {:ok, 0}

      server_tool_use when is_map(server_tool_use) ->
        required_count(server_tool_use, :web_search_requests)

      _unsafe ->
        {:error, :unsafe_usage}
    end
  end

  defp validate_cache_aggregate(aggregate, duration_total) when aggregate == duration_total,
    do: :ok

  defp validate_cache_aggregate(_aggregate, _duration_total), do: {:error, :unsafe_usage}

  defp add_cost({numerator, denominator}, count, {rate_numerator, rate_denominator}) do
    normalize({
      numerator * rate_denominator + count * rate_numerator * denominator,
      denominator * rate_denominator
    })
  end

  defp normalize({numerator, denominator}) do
    divisor = Integer.gcd(numerator, denominator)
    {div(numerator, divisor), div(denominator, divisor)}
  end

  defp ceil_rational({numerator, denominator}),
    do: div(numerator + denominator - 1, denominator)

  defp fetch(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_required(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end
end
