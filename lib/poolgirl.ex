defmodule Poolgirl do
  use GenServer

  @timeout 5000
  @moduledoc """
  Documentation for Poolgirl.
  """
  def start(pool_args, worker_args) do
    start_pool(&GenServer.start/3, pool_args, worker_args)
  end

  def start_link(pool_args, worker_args) do
    start_pool(&GenServer.start_link/3, pool_args, worker_args)
  end

  def start_pool(start_fun, pool_args, worker_args) do
    case Keyword.fetch(pool_args, :name) do
      {:ok, name} ->
        start_fun.(name, __MODULE__, {pool_args, worker_args}, [])
        _ ->
        start_fun.(__MODULE__, {pool_args, worker_args}, [])
    end
  end

  def init({pool_args, worker_args}) do
    Process.flag(:trap_exit, true)
    waiting = :queue.new()
    monitors = :ets.new(:monitors, [:private])
    # init(pool_args, worker_args)
  end

  @doc """
  the pool of workers will be started when the application starts
  takes two arguments: name of the pool, and pool configuration.
  """
  @spec child_spec(term, list, list) :: tuple
  def child_spec(pool_id, pool_args, worker_args \\ []) do
    {pool_id,
      {:poolboy, :start_link,
        [pool_args, worker_args]}, :permanent, 5000, :worker, [:poolboy]}
  end


  @doc """
  will return :full if block is set to true
  """
  def checkout(pool_name, block \\true, timeout \\ @timeout) do
    cref = make_ref()
    try do
      GenServer.call(pool_name, {:checkout, cref, block}, timeout)
    catch
      reason ->
        GenServer.cast(pool_name, {:cancel_waiting, cref})
        raise(reason, :erlang.get_stacktrace())
    end
  end


  def handle_call({:checkout, c_ref, block}, {from_pid, _} = from,
    %{
      supervisor: sup,
      workers: workers,
      monitors: monitors,
      overflow: overflow, max_overflow: max_overflow } = state) do
        case workers do
          [pid | tail] ->
            m_ref = Process.monitor(from_pid)
            true = :ets.insert(monitors, {pid, c_ref, m_ref})
            {:reply, pid, Map.put(state, :workers, tail)}

          [] when max_overflow >0 and overflow < max_overflow ->
            {pid, m_ref} = new_worker(sup, from_pid)
            true = :ets.insert(monitors, {pid, c_ref, m_ref})
            {:reply, pid, Map.put(state, :overflow, overflow+1)}

          [] when block == false -> {:reply, :full, state}

          [] ->
            m_ref = Process.monitor(from_pid)
            waiting = :queue.in({from, c_ref, m_ref}, state.waiting)
            {:noreply, Map.put(state, :waiting, waiting)}
        end
  end

  def check_in(pool_name, worker_pid) when is_pid(worker_pid) do
    GenServer.cast(pool_name, {:checkin, worker_pid})
  end

  def handle_cast({:check_in, worker_pid}, %{monitors: monitors} = state) do
    case :ets.lookup(monitors, worker_pid) do
      [{pid, _, m_ref}] ->
        true = Process.demonitor(m_ref)
        true = :ets.delete(monitors, pid)
        new_state = handle_checkin(pid, state)
        {:noreply, new_state}
      [] ->
        {:noreply, state}
    end
  end

  def handle_checkin(pid, %{supervisor: sup, waiting: waiting, monitors: monitors,
                            overflow: overflow, strategy: strategy } = state) do
        case :queue.out(waiting) do
          { {value, {from, c_ref, m_ref} }, tail} ->
            true = :ets.insert(monitors, {pid, c_ref, m_ref})
            GenServer.reply(from, pid)
            Map.put(state, :waiting, tail)
          {:empty, empty} when overflow > 0 ->
            # :ok = dismiss_worker(sup, pid)
            Map.put(state, :waiting, :empty)
            Map.put(state, :overflow, overflow - 1)
          {:empty, empty} ->
            workers = case strategy do
              :lifo -> [pid | state.workers]
              :fifo -> state.workers ++ pid
            end
            Map.merge(state, %{ workers: workers,
              waiting: :empty,
              overflow: 0,
            })
        end
  end

  def status(pool_name) do
    GenServer.call(pool_name, :status)
  end
  def handle_call(:status, _from,
                  %{workers: workers, monitors: monitors, overflow: overflow} = state) do
    state_name = get_state_name(state)
    {:reply, {state_name, Enum.count(workers), overflow, :ets.info(monitors, :size)}, state}
  end

  def get_state_name(%{max_overflow: max_overflow,
                      workers: workers, overflow: overflow}) when overflow < 1 do
      case Enum.count(workers) do
        0 when max_overflow < 1 -> :full
        0 -> true
        _ -> :ready
      end
  end

  def get_state_name(%{max_overflow: max_overflow, overflow: overflow}) do
    :full
  end
  def get_state_name(_state) do
    :overflow
  end

  def stop(pool_name) do
    GenServer.call(pool_name, :stop)
  end
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def new_worker(sup) do
    {:ok, pid} = Supervisor.start_child(sup, [])
    true = Process.link(pid)
    pid
  end
  def new_worker(sup, from_pid) do
    pid = new_worker(sup)
    ref = Process.monitor(from_pid)
    {pid, ref}
  end

end
