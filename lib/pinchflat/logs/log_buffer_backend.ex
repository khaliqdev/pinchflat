defmodule Pinchflat.Logs.LogBufferBackend do
  @moduledoc """
  The classic Logger gen_event backend feeding `Pinchflat.Logs.LogBuffer`.

  Lives separately from the buffer module because the two roles need
  conflicting callback returns: a gen_event handler must return {:ok, state}
  from handle_info/2, while the table-owning GenServer must return
  {:noreply, state}. Sharing one module crashed the handler the first time
  Logger delivered a management message (Level update_counter) to its mailbox.

  All failures are swallowed here - logging infrastructure can never take the
  app down. The log-buffer tests cover the hostile-input cases.
  """

  @behaviour :gen_event

  alias Pinchflat.Logs.LogBuffer

  def init(_opts) do
    # Ensure the table exists even if the child process has not started yet
    LogBuffer.ensure_table()

    {:ok, %{}}
  end

  # Logger invokes backend callbacks in the process that emitted the log, so
  # this runs on hot paths. The event is the classic backend shape
  # {level, gl, {Logger, msg, ts, md}}.
  def handle_event({level, _gl, {Logger, message, timestamp, metadata}}, state) do
    LogBuffer.record_from_event(level, message, timestamp, metadata)

    {:ok, state}
  end

  def handle_event(:flush, state), do: {:ok, state}

  def handle_event(_event, state), do: {:ok, state}

  # gen_event arity - NOT the GenServer handle_call/3
  def handle_call(_message, state), do: {:ok, :ok, state}

  # gen_event arity - must be {:ok, state}, never {:noreply, state}
  def handle_info(_message, state), do: {:ok, state}

  def terminate(_reason, _state), do: :ok
end
