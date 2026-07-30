defmodule ContextBot.ATProto.ReqClient do
  @moduledoc """
  Req-backed ATProto/XRPC boundary with explicit authentication retry semantics.
  """

  @behaviour ContextBot.ATProto.Client

  @appview_url "https://api.bsky.app"
  @plc_directory_url "https://plc.directory"
  @default_timeout 15_000
  @plc_did_regex ~r/\Adid:plc:[a-z2-7]{24}\z/
  @hostname_label_regex ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  @impl true
  def list_notifications(cursor) when is_binary(cursor) or is_nil(cursor) do
    params = [reasons: "mention", priority: false, limit: 100]
    params = if cursor, do: Keyword.put(params, :cursor, cursor), else: params

    authenticated_request(
      method: :get,
      url: pds_url() <> "/xrpc/app.bsky.notification.listNotifications",
      params: params
    )
  end

  @impl true
  def get_post_thread(uri, parent_height)
      when is_binary(uri) and is_integer(parent_height) and parent_height > 0 do
    authenticated_request(
      method: :get,
      url: pds_url() <> "/xrpc/app.bsky.feed.getPostThread",
      params: [uri: uri, depth: 0, parentHeight: parent_height]
    )
  end

  @impl true
  def get_profile(actor, labeler_did) when is_binary(actor) and is_binary(labeler_did) do
    request(
      method: :get,
      url: @appview_url <> "/xrpc/app.bsky.actor.getProfile",
      params: [actor: actor],
      headers: [{"atproto-accept-labelers", labeler_did}]
    )
  end

  @impl true
  def resolve_handle(handle) when is_binary(handle) do
    request(
      method: :get,
      url: @appview_url <> "/xrpc/com.atproto.identity.resolveHandle",
      params: [handle: handle]
    )
  end

  @impl true
  def resolve_did("did:plc:" <> _identifier = did) do
    if Regex.match?(@plc_did_regex, did) do
      request(method: :get, url: @plc_directory_url <> "/" <> did)
    else
      {:error, {:permanent, 400}}
    end
  end

  def resolve_did("did:web:" <> hostname) do
    if valid_web_hostname?(hostname) do
      request(method: :get, url: "https://#{hostname}/.well-known/did.json")
    else
      {:error, {:permanent, 400}}
    end
  end

  def resolve_did(_did), do: {:error, {:permanent, 400}}

  @impl true
  def get_record(repo, collection, rkey)
      when is_binary(repo) and is_binary(collection) and is_binary(rkey) do
    authenticated_request(
      method: :get,
      url: pds_url() <> "/xrpc/com.atproto.repo.getRecord",
      params: [repo: repo, collection: collection, rkey: rkey]
    )
  end

  @impl true
  def put_record(repo, collection, rkey, record)
      when is_binary(repo) and is_binary(collection) and is_binary(rkey) and is_map(record) do
    authenticated_request(
      method: :post,
      url: pds_url() <> "/xrpc/com.atproto.repo.putRecord",
      json: %{
        "repo" => repo,
        "collection" => collection,
        "rkey" => rkey,
        "record" => record,
        "validate" => true,
        "swapRecord" => nil
      }
    )
  end

  defp authenticated_request(request_options) do
    session = config()[:session] || ContextBot.ATProto.Session

    case session.access_token() do
      {:ok, access_token} -> authorized_request(session, request_options, access_token)
      {:error, _reason} -> {:error, :session_unavailable}
    end
  end

  defp authorized_request(session, request_options, access_token) do
    case request_with_token(request_options, access_token) do
      {:error, :unauthorized} -> refresh_and_retry(session, request_options, access_token)
      result -> result
    end
  end

  defp refresh_and_retry(session, request_options, rejected_access_token) do
    case session.refresh(rejected_access_token) do
      {:ok, refreshed_token} -> request_with_token(request_options, refreshed_token)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_with_token(request_options, access_token) do
    headers = Keyword.get(request_options, :headers, [])

    request_options
    |> Keyword.put(:headers, [{"authorization", "Bearer #{access_token}"} | headers])
    |> request()
  end

  defp request(request_options) do
    timeout = config()[:timeout] || @default_timeout

    common_options = [
      finch: [
        name: ContextBot.Finch,
        pool_timeout: 5_000,
        receive_timeout: timeout,
        request_timeout: timeout + 5_000
      ],
      retry: false
    ]

    options = Keyword.merge(config()[:req_options] || [], common_options)

    Req.new(options)
    |> Req.request(request_options)
    |> normalize_response()
  end

  defp normalize_response({:ok, %Req.Response{status: status, headers: headers, body: body}})
       when status in 200..299 do
    {:ok, status, headers, body}
  end

  defp normalize_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}

  defp normalize_response({:ok, %Req.Response{status: 429, headers: headers}}) do
    {:error, {:rate_limited, first_header(headers, "retry-after")}}
  end

  defp normalize_response({:ok, %Req.Response{status: status}}) when status in 500..599,
    do: {:error, {:transient, status}}

  defp normalize_response({:ok, %Req.Response{body: %{"error" => "RecordNotFound"}}}),
    do: {:error, :record_not_found}

  defp normalize_response({:ok, %Req.Response{body: %{"error" => "InvalidSwap"}}}),
    do: {:error, :invalid_swap}

  defp normalize_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:permanent, status}}

  defp normalize_response({:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, :timeout}

  defp normalize_response({:error, %{reason: :timeout}}), do: {:error, :timeout}
  defp normalize_response({:error, _exception}), do: {:error, {:transient, :transport}}

  defp first_header(headers, name) do
    case Map.get(headers, name, []) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp valid_web_hostname?(hostname) do
    labels = String.split(hostname, ".", trim: false)

    byte_size(hostname) in 1..253 and
      length(labels) >= 2 and
      Enum.all?(labels, fn label ->
        byte_size(label) <= 63 and Regex.match?(@hostname_label_regex, label)
      end) and
      Regex.match?(~r/[a-z]/, List.last(labels))
  end

  defp pds_url do
    settings = Application.fetch_env!(:context_bot, :settings)
    url = config()[:pds_url] || settings.bot_pds_url
    String.trim_trailing(url, "/")
  end

  defp config, do: Application.get_env(:context_bot, __MODULE__, [])
end
