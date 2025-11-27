defmodule Ipa.Pod.State.Projections.WorkstreamProjection do
  @moduledoc "Projects workstream events onto state."

  alias Ipa.Pod.State
  alias Ipa.Pod.State.Workstream

  alias Ipa.Pod.Events.{
    WorkstreamCreated,
    WorkstreamStarted,
    WorkstreamAgentStarted,
    WorkstreamCompleted,
    WorkstreamFailed
  }

  @doc "Applies a workstream event to state."
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, %WorkstreamCreated{} = event) do
    workstream = %Workstream{
      workstream_id: event.workstream_id,
      title: event.title,
      spec: event.spec,
      dependencies: event.dependencies || [],
      priority: event.priority || :normal,
      status: :pending,
      blocking_on: calculate_blocking(event.dependencies || [], state.workstreams)
    }

    workstreams = Map.put(state.workstreams, event.workstream_id, workstream)
    %{state | workstreams: workstreams}
  end

  def apply(state, %WorkstreamStarted{} = event) do
    update_workstream(state, event.workstream_id, fn ws ->
      %{
        ws
        | status: :in_progress,
          agent_id: event.agent_id,
          workspace_path: event.workspace_path,
          started_at: System.system_time(:second)
      }
    end)
  end

  def apply(state, %WorkstreamAgentStarted{} = event) do
    update_workstream(state, event.workstream_id, fn ws ->
      %{
        ws
        | status: :in_progress,
          agent_id: event.agent_id,
          workspace_path: event.workspace,
          started_at: System.system_time(:second)
      }
    end)
  end

  def apply(state, %WorkstreamCompleted{} = event) do
    state
    |> update_workstream(event.workstream_id, fn ws ->
      %{
        ws
        | status: :completed,
          completed_at: System.system_time(:second)
      }
    end)
    |> recalculate_all_blocking()
  end

  def apply(state, %WorkstreamFailed{} = event) do
    update_workstream(state, event.workstream_id, fn ws ->
      %{
        ws
        | status: :failed,
          error: event.error,
          completed_at: System.system_time(:second)
      }
    end)
  end

  def apply(state, _event), do: state

  # Helpers

  defp update_workstream(state, workstream_id, update_fn) do
    case Map.get(state.workstreams, workstream_id) do
      nil ->
        state

      ws ->
        updated_ws = update_fn.(ws)
        %{state | workstreams: Map.put(state.workstreams, workstream_id, updated_ws)}
    end
  end

  @doc """
  Calculates which dependencies are still blocking.
  A dependency is blocking if it exists and is not completed.
  """
  @spec calculate_blocking([String.t()], %{String.t() => Workstream.t()}) :: [String.t()]
  def calculate_blocking([], _workstreams), do: []

  def calculate_blocking(dependencies, workstreams) do
    Enum.filter(dependencies, fn dep_id ->
      case Map.get(workstreams, dep_id) do
        nil -> false
        ws -> ws.status != :completed
      end
    end)
  end

  # Recalculate blocking_on for all workstreams
  defp recalculate_all_blocking(state) do
    workstreams =
      Map.new(state.workstreams, fn {id, ws} ->
        blocking = calculate_blocking(ws.dependencies, state.workstreams)
        {id, %{ws | blocking_on: blocking}}
      end)

    %{state | workstreams: workstreams}
  end
end
