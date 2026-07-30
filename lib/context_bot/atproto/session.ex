defmodule ContextBot.ATProto.Session do
  @moduledoc """
  In-memory owner for the bot's ATProto access and refresh JWTs.

  Authentication is lazy, so concurrent callers queue behind a single `createSession` request.
  Refresh calls include the rejected access token, allowing queued callers to reuse a token that
  another caller has already refreshed.
  """

  use GenServer

  @create_session_path "/xrpc/com.atproto.server.createSession"
  @refresh_session_path "/xrpc/com.atproto.server.refreshSession"
  @default_timeout 15_000
  @default_reauthentication_cooldown_ms 30_000

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {name, init_options} = Keyword.pop(options, :name, __MODULE__)
    genserver_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_options, genserver_options)
  end

  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, __MODULE__) || __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :transient
    }
  end

  @doc false
  @spec access_token() :: {:ok, String.t()} | {:error, atom()}
  def access_token, do: access_token(__MODULE__)

  @doc false
  @spec access_token(server()) :: {:ok, String.t()} | {:error, atom()}
  def access_token(server), do: GenServer.call(server, :access_token)

  @doc false
  @spec refresh(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def refresh(rejected_access_token), do: refresh(rejected_access_token, __MODULE__)

  @doc false
  @spec refresh(String.t(), server()) :: {:ok, String.t()} | {:error, atom()}
  def refresh(rejected_access_token, server) when is_binary(rejected_access_token) do
    GenServer.call(server, {:refresh, rejected_access_token})
  end

  @spec status() :: {:ok, %{authenticated?: boolean(), did: String.t()}}
  def status, do: status(__MODULE__)

  @spec status(server()) :: {:ok, %{authenticated?: boolean(), did: String.t()}}
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    config = Application.get_env(:context_bot, __MODULE__, [])
    settings = Application.fetch_env!(:context_bot, :settings)

    state = %{
      access_jwt: nil,
      refresh_jwt: nil,
      bot_did: option(options, config, :bot_did, settings.bot_did),
      identifier: option(options, config, :identifier, settings.bot_handle),
      password:
        option(
          options,
          config,
          :password,
          Application.get_env(:context_bot, :bot_app_password)
        ),
      pds_url: option(options, config, :pds_url, settings.bot_pds_url),
      timeout: option(options, config, :timeout, @default_timeout),
      req_options: option(options, config, :req_options, []),
      reauthentication_cooldown_ms:
        option(
          options,
          config,
          :reauthentication_cooldown_ms,
          @default_reauthentication_cooldown_ms
        ),
      reauthenticate_after: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:access_token, _from, %{access_jwt: access_jwt} = state)
      when is_binary(access_jwt) do
    {:reply, {:ok, access_jwt}, state}
  end

  def handle_call(:access_token, _from, state) do
    case create_session(state) do
      {:ok, authenticated} -> {:reply, {:ok, authenticated.access_jwt}, authenticated}
      {:stop, reason} -> {:stop, :normal, {:error, reason}, clear_tokens(state)}
      {:error, _reason} -> {:reply, {:error, :authentication_failed}, state}
    end
  end

  def handle_call({:refresh, rejected}, _from, %{access_jwt: access_jwt} = state)
      when is_binary(access_jwt) and access_jwt != rejected do
    {:reply, {:ok, access_jwt}, state}
  end

  def handle_call({:refresh, _rejected}, _from, %{refresh_jwt: nil} = state) do
    {:reply, {:error, :session_unavailable}, state}
  end

  def handle_call({:refresh, _rejected}, _from, state) do
    case refresh_session(state) do
      {:ok, refreshed} ->
        {:reply, {:ok, refreshed.access_jwt}, refreshed}

      {:invalid_refresh, _reason} ->
        handle_reauthentication(state)

      {:stop, reason} ->
        {:stop, :normal, {:error, reason}, clear_tokens(state)}

      {:error, _reason} ->
        {:reply, {:error, :refresh_failed}, state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{authenticated?: is_binary(state.access_jwt), did: state.bot_did}
    {:reply, {:ok, status}, state}
  end

  defp handle_reauthentication(state) do
    now = System.monotonic_time(:millisecond)

    if state.reauthenticate_after && now < state.reauthenticate_after do
      {:reply, {:error, :reauthentication_rate_limited}, state}
    else
      state = %{
        state
        | reauthenticate_after: now + state.reauthentication_cooldown_ms
      }

      case create_session(state) do
        {:ok, authenticated} -> {:reply, {:ok, authenticated.access_jwt}, authenticated}
        {:stop, reason} -> {:stop, :normal, {:error, reason}, clear_tokens(state)}
        {:error, _reason} -> {:reply, {:error, :authentication_failed}, clear_tokens(state)}
      end
    end
  end

  defp create_session(state) do
    state
    |> request(
      method: :post,
      path: @create_session_path,
      json: %{"identifier" => state.identifier, "password" => state.password}
    )
    |> case do
      {:ok, status, body} when status in 200..299 -> accept_session(body, state)
      {:ok, _status, _body} -> {:error, :authentication_failed}
      {:error, _reason} -> {:error, :authentication_failed}
    end
  end

  defp refresh_session(state) do
    state
    |> request(
      method: :post,
      path: @refresh_session_path,
      headers: [{"authorization", "Bearer #{state.refresh_jwt}"}]
    )
    |> case do
      {:ok, status, body} when status in 200..299 -> accept_session(body, state)
      {:ok, status, _body} when status in 400..499 -> {:invalid_refresh, status}
      {:ok, _status, _body} -> {:error, :provider_unavailable}
      {:error, _reason} -> {:error, :transport}
    end
  end

  defp accept_session(%{"active" => false}, _state), do: {:stop, :inactive_session}

  defp accept_session(%{"did" => did}, %{bot_did: bot_did}) when did != bot_did,
    do: {:stop, :did_mismatch}

  defp accept_session(
         %{"did" => did, "accessJwt" => access_jwt, "refreshJwt" => refresh_jwt},
         state
       )
       when is_binary(did) and is_binary(access_jwt) and access_jwt != "" and
              is_binary(refresh_jwt) and refresh_jwt != "" do
    {:ok, %{state | access_jwt: access_jwt, refresh_jwt: refresh_jwt}}
  end

  defp accept_session(_body, _state), do: {:error, :invalid_session}

  defp request(state, request_options) do
    common_options = [
      finch: [
        name: ContextBot.Finch,
        pool_timeout: 5_000,
        receive_timeout: state.timeout,
        request_timeout: state.timeout + 5_000
      ],
      retry: false
    ]

    options = Keyword.merge(state.req_options, common_options)
    url = String.trim_trailing(state.pds_url, "/") <> request_options[:path]

    request_options
    |> Keyword.delete(:path)
    |> Keyword.put(:url, url)
    |> then(&Req.request(Req.new(options), &1))
    |> case do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, _exception} -> {:error, :transport}
    end
  end

  defp clear_tokens(state), do: %{state | access_jwt: nil, refresh_jwt: nil}

  defp option(options, config, key, default) do
    Keyword.get(options, key, Keyword.get(config, key, default))
  end
end
