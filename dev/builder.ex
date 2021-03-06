defmodule Builder do
  @moduledoc """
  Builds sqlite3-baked tzdata db.
  """

  require Logger

  def download_tzdata do
    {:ok, conn} = Mint.HTTP.connect(:https, "data.iana.org", 443)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/time-zones/tzdata-latest.tar.gz", [], nil)
    File.rm("tzdata-latest.tar.gz")
    File.rm("tzdata-latest.tar.gz.part")
    {:ok, fd} = File.open("tzdata-latest.tar.gz.part", [:binary, :append])
    state = download_tzdata_loop(conn, ref, %{fd: fd})
    {:ok, _conn} = Mint.HTTP.close(conn)
    File.close(fd)
    File.rename!("tzdata-latest.tar.gz.part", "tzdata-latest.tar.gz")

    case state do
      %{status: 200, headers: headers} ->
        case :proplists.get_value("content-type", headers) do
          "application/x-gzip" ->
            :erlang.garbage_collect(self())
        end
    end
  end

  # maybe stream
  def untar_tzdata do
    true = File.exists?("tzdata-latest.tar.gz")
    :erl_tar.extract('tzdata-latest.tar.gz', [:compressed, {:cwd, 'tzdata'}])
  end

  defp download_tzdata_loop(conn, ref, state) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          :unknown ->
            _ = Logger.error(fn -> "Received unknown message: " <> inspect(message) end)
            download_tzdata_loop(conn, ref, state)

          {:ok, conn, responses} ->
            case process_responses(responses, ref, state) do
              {:cont, state} -> download_tzdata_loop(conn, ref, state)
              {:done, state} -> state
            end
        end
    end
  end

  def version(dir \\ "tzdata") do
    [only_line_in_file] = Path.join(dir, "version") |> File.stream!() |> Enum.into([])
    String.trim(only_line_in_file)
  end

  def process(file) do
    file
    |> File.stream!()
    |> Enum.into([])
  end

  defp process_responses([{:status, ref, status} | rest], ref, state),
    do: process_responses(rest, ref, Map.put(state, :status, status))

  defp process_responses([{:headers, ref, headers} | rest], ref, state),
    do: process_responses(rest, ref, Map.put(state, :headers, headers))

  # TODO untar stream?
  defp process_responses([{:data, ref, data} | rest], ref, state) do
    :ok = IO.binwrite(state.fd, data)
    process_responses(rest, ref, state)
  end

  defp process_responses([{:done, ref}], ref, state), do: {:done, state}
  defp process_responses([], _ref, state), do: {:cont, state}
end
