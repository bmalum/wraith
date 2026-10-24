defmodule Wraith.Store.SQL.Token do
  @moduledoc """
  Aurora DSQL authenticates with an IAM token: a SigV4-presigned
  `GET https://<endpoint>/?Action=DbConnectAdmin` with the scheme stripped,
  used as the connection password. Credentials come from ex_aws's chain
  (the same one the DynamoDB store and the MicroVM runtime use). Ported
  from shadow_corp's `Repo.IamToken`, on top of ExAws's presigned-URL signer.
  """

  @default_expires 15 * 60

  @spec generate!(String.t(), String.t(), keyword()) :: String.t()
  def generate!(endpoint, region, opts \\ []) do
    action = Keyword.get(opts, :action, "DbConnectAdmin")
    # ex_aws has no `:dsql` service entry; the config only lends us credentials and
    # the region, the signature itself names `dsql` (the `service` argument below)
    config = ExAws.Config.new(:sts, region: region)

    {:ok, url} =
      ExAws.Auth.presigned_url(
        :get,
        "https://#{endpoint}/",
        :dsql,
        :calendar.universal_time(),
        config,
        Keyword.get(opts, :expires_in, @default_expires),
        [{"Action", action}]
      )

    String.replace_prefix(url, "https://", "")
  end
end
