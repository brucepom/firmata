defmodule Firmata.Board do
  use GenServer
  use Firmata.Protocol.Mixin

  @initial_state [
    subscriptions: [],
    pins: [],
    outbox: [],
    parser: {},
    serial: nil,
    connected: false
  ]

  @doc """
  {:ok, board} = Firmata.Board.start_link "/dev/cu.usbmodem1421"
  """
  def start_link(tty, baudrate, opts \\ []) do
    GenServer.start_link(__MODULE__, [tty, baudrate], opts)
  end

  def connect(board) do
    GenServer.call(board, :connect, 10000)
    block_until_connected(board)
    :ok
  end

  defp block_until_connected(board) do
    unless connected?(board), do: block_until_connected(board)
  end

  def connected?(board) do
    get(board, :connected)
  end

  def get(board, key) do
    GenServer.call(board, {:get, key})
  end

  def set(board, key, value) do
    GenServer.call(board, {:set, key, value})
  end

  def report_analog_pin(board, pin, value) do
    GenServer.call(board, {:report_analog_pin, pin, value})
  end

  def subscribe(board, {message, pin}) do
    GenServer.call(board, {:subscribe, self, {message, pin}})
  end

  def unsubscribe(board, sub) do
    GenServer.call(board, {:unsubscribe, sub})
  end

  ## Server Callbacks

  def init([tty, baudrate]) do
    {:ok, serial} = Serial.start_link
    Serial.open(serial, tty)
    Serial.set_speed(serial, baudrate)
    board = self
    spawn_link(fn()-> process_outbox(board) end)
    {:ok, @initial_state |> Keyword.put(:serial, serial)}
  end

  defp process_outbox(board) do
    outbox = get(board, :outbox)
    if Enum.count(outbox) > 0 do
      [message | tail] = outbox
      set(board, :outbox, tail)
      send(board, message)
    end
    process_outbox(board)
  end

  def handle_call({:get, key}, _from, state) do
    {:reply, Keyword.get(state, key), state}
  end

  def handle_call({:set, key, value}, _from, state) do
    {:reply, :ok, Keyword.put(state, key, value)}
  end

  def handle_call(:connect, _from, state) do
    Keyword.get(state, :serial) |> Serial.connect
    {:reply, :ok, state}
  end

  @doc """
  Subscribe a process to analog pin value changes
  """
  def handle_call({:subscribe, pid, {:analog_read, pin}}, _from, state) do
    sub = {pid, :analog_read, pin}
    subs = state[:subscriptions]
    subs = [sub | subs] |> Enum.uniq
    {:reply, {:ok, sub}, Keyword.put(state, :subscriptions, subs)}
  end

  def handle_call({:unsubscribe, sub}, _from, state) do
    subs = state[:subscriptions]
    |> Enum.reject(fn(chk_sub)-> chk_sub == sub end)
    ### TODO urgent
    # If there are no subs for that given thing
    # then just stop polling for that particular thing
    # e.g. Firmata.Board.report_analog_pin(board, pin, 0)
    {:reply, :ok, Keyword.put(state, :subscriptions, subs)}
  end

  def handle_call({:report_analog_pin, pin, value}, _from, state) do
    Serial.send_data(state[:serial], <<@report_analog ||| pin, value>>)
    {:reply, :ok, state}
  end

  def handle_info({:report_version, major, minor }, state) do
    Serial.send_data(state[:serial], <<@start_sysex, @capability_query, @end_sysex>>)
    {:noreply, Keyword.put(state, :version, {major, minor})}
  end

  def handle_info({:firmware_name, name }, state) do
    {:noreply, Keyword.put(state, :firmware_name, name)}
  end

  def handle_info({:capability_response, pins }, state) do
    state = Keyword.put(state, :pins, pins)
    Serial.send_data(state[:serial], <<@start_sysex, @analog_mapping_query, @end_sysex>>)
    {:noreply, state}
  end

  def handle_info({:analog_mapping_response, mapping }, state) do
    pins = Enum.zip(state[:pins], mapping)
    |> Enum.map(fn({pin, map})-> Keyword.merge(pin, map) end)
    state = Keyword.put(state, :pins, pins)
    |> Keyword.put(:connected, true)
    {:noreply, state}
  end

  def handle_info({:analog_read, pin, value }, state) do
    # find who is intrested in this, and send the info
    state[:subscriptions]
    |> Enum.filter(fn({_pid, name, sub_pin}) ->
      sub_pin == pin && name == :analog_read
    end)
    |> Enum.each(fn({pid, :analog_read, pin}) ->
      send(pid, {:analog_read, pin, value})
    end)
    {:noreply, state}
  end

  def handle_info({:elixir_serial, _serial, data}, state) do
    acc = Firmata.Protocol.State.unpack(state)
    acc = Enum.reduce(data, acc, &Firmata.Protocol.parse(&2, &1))
    state = Firmata.Protocol.State.pack(acc, state)
    {:noreply, state}
  end
end
