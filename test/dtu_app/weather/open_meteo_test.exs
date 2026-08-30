defmodule DtuApp.Weather.OpenMeteoTest do
  @moduledoc """
  Pins the contract for `DtuApp.Weather.OpenMeteo.hourly_cloud_cover/3`:

    * URL shape: `https://api.open-meteo.com/v1/forecast` with
      `latitude`, `longitude`, `hourly=cloud_cover`, `past_days`, and
      `forecast_days` query params. No `apikey` (free tier).
    * Response decode: `%{hourly: %{time: [DateTime.t()], cloud_cover: [integer()]}}`.
    * Nil lat/lon → `nil`, no HTTP call.
    * HTTP 4xx/5xx → `{:error, %{status: integer(), body: String.t()}}`.

  HTTP calls are intercepted via `Req.Test` — the test config wires
  `plug: {Req.Test, DtuApp.Weather.OpenMeteo}` so real network
  traffic never happens in :test.
  """

  use ExUnit.Case, async: true

  alias DtuApp.Weather.OpenMeteo

  # Build a realistic Open-Meteo response: 48 hourly readings (2 days)
  # starting from yesterday at 00:00 UTC. Cloud cover alternates
  # 0 / 50 / 100 so a test can grep a specific value at a known index.
  defp open_meteo_body do
    base =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(-24 * 3600, :second)
      |> DateTime.to_iso8601()

    times =
      for i <- 0..47 do
        {:ok, base_dt, 0} = DateTime.from_iso8601(base)
        DateTime.add(base_dt, i * 3600, :second) |> DateTime.to_iso8601()
      end

    %{
      "latitude" => 52.52,
      "longitude" => 13.41,
      "hourly" => %{
        "time" => times,
        "cloud_cover" => Enum.map(0..47, fn i -> rem(i, 3) * 50 end)
      }
    }
  end

  # Install a stub that captures the inbound conn into the test
  # process via `send/2`, so subsequent tests can assert on the URL
  # that was actually requested. Returns the request PID for
  # `Req.Test.allow/3` style assertions if needed.
  defp stub_open_meteo(status \\ 200) do
    test_pid = self()

    Req.Test.stub(OpenMeteo, fn conn ->
      send(test_pid, {:open_meteo_request, conn})

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(open_meteo_body()))
    end)
  end

  defp assert_url_query(expected) do
    assert_received {:open_meteo_request, conn}
    assert URI.decode_query(conn.query_string) == expected
  end

  describe "hourly_cloud_cover/3" do
    test "decodes a valid 200 response into %{hourly: %{time, cloud_cover}}" do
      stub_open_meteo()

      assert {:ok, %{hourly: hourly}} =
               OpenMeteo.hourly_cloud_cover(52.52, 13.41, past_days: 1)

      assert length(hourly.time) == 48
      assert hd(hourly.time) |> is_struct(DateTime)
      assert length(hourly.cloud_cover) == 48
      assert Enum.all?(hourly.cloud_cover, &(is_integer(&1) and &1 >= 0 and &1 <= 100))
    end

    test "pins the request URL: host, path, and query params" do
      stub_open_meteo()

      OpenMeteo.hourly_cloud_cover(52.52, 13.41, past_days: 1)

      assert_received {:open_meteo_request, conn}
      assert conn.scheme == :https
      assert conn.host == "api.open-meteo.com"
      assert conn.request_path == "/v1/forecast"

      assert URI.decode_query(conn.query_string) == %{
               "latitude" => "52.52",
               "longitude" => "13.41",
               "hourly" => "cloud_cover",
               "past_days" => "1",
               "forecast_days" => "1"
             }
    end

    test "nil latitude short-circuits to nil without making an HTTP call" do
      assert OpenMeteo.hourly_cloud_cover(nil, 13.41, past_days: 1) == nil
      refute_received {:open_meteo_request, _}
    end

    test "nil longitude short-circuits to nil without making an HTTP call" do
      assert OpenMeteo.hourly_cloud_cover(52.52, nil, past_days: 1) == nil
      refute_received {:open_meteo_request, _}
    end

    test "HTTP 4xx returns {:error, %{status, body}}" do
      stub_open_meteo(400)

      assert {:error, %{status: 400, body: body}} =
               OpenMeteo.hourly_cloud_cover(52.52, 13.41, past_days: 1)

      assert is_binary(body)
    end

    test "past_days is clamped to Open-Meteo's documented max of 92" do
      stub_open_meteo()

      OpenMeteo.hourly_cloud_cover(52.52, 13.41, past_days: 365)

      assert_url_query(%{
        "latitude" => "52.52",
        "longitude" => "13.41",
        "hourly" => "cloud_cover",
        "past_days" => "92",
        "forecast_days" => "1"
      })
    end

    test "future forecast_days defaults to 1 (we don't need a deep forecast)" do
      stub_open_meteo()

      OpenMeteo.hourly_cloud_cover(52.52, 13.41, past_days: 7)

      assert_url_query(%{
        "latitude" => "52.52",
        "longitude" => "13.41",
        "hourly" => "cloud_cover",
        "past_days" => "7",
        "forecast_days" => "1"
      })
    end
  end
end
