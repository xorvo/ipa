defmodule Ipa.Pod.Machine.Guards do
  @moduledoc """
  Guards that must pass for a phase transition to occur.

  Guards check business rules that go beyond the simple state machine transitions.
  For example, you can only move to planning if the spec is approved.
  """

  alias Ipa.Pod.State
  alias Ipa.Pod.Machine

  @type guard_result :: :ok | {:error, String.t()}

  @doc """
  Checks if a transition can occur given current state.

  Returns `:ok` if allowed, `{:error, reason}` if not.
  """
  @spec check_transition(State.t(), atom(), atom()) :: guard_result()
  def check_transition(state, from, to) do
    with :ok <- check_machine_allows(from, to),
         :ok <- check_current_phase(state, from),
         :ok <- check_phase_guards(state, from, to) do
      :ok
    end
  end

  @doc """
  Checks all guards without verifying the from phase matches current.
  Useful for checking if a transition would be valid.
  """
  @spec check_guards(State.t(), atom(), atom()) :: guard_result()
  def check_guards(state, from, to) do
    with :ok <- check_machine_allows(from, to),
         :ok <- check_phase_guards(state, from, to) do
      :ok
    end
  end

  # Check that the state machine allows this transition
  defp check_machine_allows(from, to) do
    if Machine.can_transition?(from, to) do
      :ok
    else
      {:error, "Invalid transition from #{from} to #{to}"}
    end
  end

  # Check that we're actually in the expected phase
  defp check_current_phase(state, from) do
    if state.phase == from do
      :ok
    else
      {:error, "Expected to be in phase #{from}, but currently in #{state.phase}"}
    end
  end

  # Phase-specific guards
  defp check_phase_guards(state, :spec_clarification, :planning) do
    if State.spec_approved?(state) do
      :ok
    else
      {:error, "Spec must be approved before moving to planning"}
    end
  end

  defp check_phase_guards(state, :planning, :workstream_execution) do
    cond do
      state.plan == nil ->
        {:error, "Plan must exist before moving to execution"}

      not State.plan_approved?(state) ->
        {:error, "Plan must be approved before moving to execution"}

      map_size(state.workstreams) == 0 ->
        {:error, "At least one workstream must be created before execution"}

      true ->
        :ok
    end
  end

  defp check_phase_guards(state, :workstream_execution, :review) do
    workstreams = Map.values(state.workstreams)

    all_terminal? =
      Enum.all?(workstreams, fn ws ->
        ws.status in [:completed, :failed]
      end)

    if all_terminal? do
      :ok
    else
      {:error, "All workstreams must be completed or failed before review"}
    end
  end

  defp check_phase_guards(state, :workstream_execution, :planning) do
    # Allow going back to planning if we need to replan
    running_agents = State.running_agent_count(state)

    if running_agents == 0 do
      :ok
    else
      {:error, "Cannot go back to planning while #{running_agents} agents are still running"}
    end
  end

  defp check_phase_guards(state, :review, :workstream_execution) do
    # Allow going back to execution if review finds issues
    running_agents = State.running_agent_count(state)

    if running_agents == 0 do
      :ok
    else
      {:error, "Cannot go back to execution while agents are running"}
    end
  end

  # Cancellation is always allowed from any non-terminal state
  defp check_phase_guards(_state, _from, :cancelled), do: :ok

  # Default: allow if machine allows
  defp check_phase_guards(_state, _from, _to), do: :ok
end
