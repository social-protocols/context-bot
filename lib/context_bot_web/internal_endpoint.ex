defmodule ContextBotWeb.InternalEndpoint do
  @moduledoc """
  Internal operator endpoint bound to Fly's 6PN private network.

  This endpoint serves operator tools and dashboards that should never be
  exposed to the public internet. In production, it binds to the 6PN interface
  and is accessible only from other Fly machines in the organization.
  In development and test, it binds to localhost.
  """

  use Phoenix.Endpoint, otp_app: :context_bot

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :internal_endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug ContextBotWeb.InternalRouter
end
