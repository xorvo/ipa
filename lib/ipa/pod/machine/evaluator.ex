defmodule Ipa.Pod.Machine.Evaluator do
  @moduledoc """
  Evaluates the current state and determines what actions to take.

  This is the "scheduler" logic that runs periodically. It examines the
  current state and returns a list of actions that should be executed.

  Actions are data structures that describe what should happen - the
  Manager is responsible for actually executing them.
  """

  alias Ipa.Pod.State
  alias Ipa.Pod.State.Workstream

  @type action ::
          {:request_transition, atom(), String.t()}
          | {:start_workstream, String.t()}
          | {:spawn_agent, atom(), map()}
          | :noop

  @doc """
  Evaluates state and returns a list of actions to take.
  """
  @spec evaluate(State.t()) :: [action()]
  def evaluate(state) do
    case state.phase do
      :spec_clarification -> evaluate_spec_phase(state)
      :planning -> evaluate_planning_phase(state)
      :workstream_execution -> evaluate_execution_phase(state)
      :review -> evaluate_review_phase(state)
      _ -> []
    end
  end

  @doc """
  Returns workstreams that are ready to start.
  """
  @spec ready_workstreams(State.t()) :: [Workstream.t()]
  def ready_workstreams(state) do
    state.workstreams
    |> Map.values()
    |> Enum.filter(&Workstream.ready?/1)
  end

  @doc """
  Returns the number of available agent slots.
  """
  @spec available_slots(State.t()) :: non_neg_integer()
  def available_slots(state) do
    max_concurrent = state.config.max_concurrent_agents
    running = State.running_agent_count(state)
    max(0, max_concurrent - running)
  end

  # Phase evaluators

  defp evaluate_spec_phase(state) do
    cond do
      State.spec_approved?(state) and not transition_pending?(state, :planning) ->
        [{:request_transition, :planning, "Spec approved, proceeding to planning"}]

      true ->
        []
    end
  end

  defp evaluate_planning_phase(state) do
    cond do
      # Plan approved and workstreams created, transition to execution
      State.plan_approved?(state) and map_size(state.workstreams) > 0 ->
        if transition_pending?(state, :workstream_execution) do
          []
        else
          [{:request_transition, :workstream_execution, "Plan approved, starting execution"}]
        end

      # Plan approved but workstreams not yet created - create them from plan
      State.plan_approved?(state) and has_plan_workstreams?(state) and
          map_size(state.workstreams) == 0 ->
        [{:create_workstreams_from_plan, state.plan.workstreams}]

      # Already have a planning agent (running or completed) - don't spawn another
      State.has_planning_agent?(state) ->
        []

      # No planning agent exists and no plan, spawn planning agent
      state.plan == nil ->
        [{:spawn_agent, :planning, %{spec: state.spec, title: state.title}}]

      true ->
        []
    end
  end

  defp has_plan_workstreams?(state) do
    state.plan != nil and
      is_list(state.plan[:workstreams] || state.plan["workstreams"]) and
      length(state.plan[:workstreams] || state.plan["workstreams"] || []) > 0
  end

  defp evaluate_execution_phase(state) do
    workstreams = Map.values(state.workstreams)
    completed_count = Enum.count(workstreams, fn ws -> ws.status == :completed end)
    failed_count = Enum.count(workstreams, fn ws -> ws.status == :failed end)
    total = length(workstreams)

    cond do
      # All workstreams completed successfully
      total > 0 and completed_count == total ->
        if transition_pending?(state, :review) do
          []
        else
          [{:request_transition, :review, "All workstreams completed successfully"}]
        end

      # All workstreams terminal (some may have failed)
      total > 0 and completed_count + failed_count == total ->
        if transition_pending?(state, :review) do
          []
        else
          [{:request_transition, :review, "All workstreams finished (#{failed_count} failed)"}]
        end

      # Start ready workstreams if we have slots
      true ->
        slots = available_slots(state)

        if slots > 0 do
          ready_workstreams(state)
          |> Enum.take(slots)
          |> Enum.map(fn ws -> {:start_workstream, ws.workstream_id} end)
        else
          []
        end
    end
  end

  defp evaluate_review_phase(_state) do
    # Review phase logic
    # Could spawn review agent, check for required approvals, etc.
    # For now, this is a manual phase
    []
  end

  # Helpers

  defp transition_pending?(state, to_phase) do
    Enum.any?(state.pending_transitions, fn t -> t.to_phase == to_phase end)
  end
end
