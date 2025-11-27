defmodule Ipa.Pod.Commands.PhaseCommands do
  @moduledoc """
  Commands for phase transitions.

  These commands handle moving between phases in the pod lifecycle.
  """

  alias Ipa.Pod.State
  alias Ipa.Pod.Machine
  alias Ipa.Pod.Machine.Guards

  alias Ipa.Pod.Events.{
    TransitionRequested,
    TransitionApproved,
    PhaseChanged
  }

  @type result :: {:ok, [struct()]} | {:error, atom() | String.t()}

  @doc """
  Requests a phase transition.

  This creates a pending transition that may need approval.
  """
  @spec request_transition(State.t(), atom(), String.t(), String.t() | nil) :: result()
  def request_transition(state, to_phase, reason, requested_by \\ nil) do
    case Guards.check_transition(state, state.phase, to_phase) do
      :ok ->
        event = %TransitionRequested{
          task_id: state.task_id,
          from_phase: state.phase,
          to_phase: to_phase,
          reason: reason,
          requested_by: requested_by
        }

        {:ok, [event]}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Approves a pending transition.

  This actually moves the pod to the new phase.
  """
  @spec approve_transition(State.t(), atom(), String.t()) :: result()
  def approve_transition(state, to_phase, approved_by) do
    if transition_pending?(state, to_phase) do
      event = %TransitionApproved{
        task_id: state.task_id,
        to_phase: to_phase,
        approved_by: approved_by
      }

      {:ok, [event]}
    else
      {:error, :no_pending_transition}
    end
  end

  @doc """
  Directly changes phase without requiring approval.

  Use this for system-initiated transitions (e.g., auto-transitions).
  Still validates that the transition is allowed.
  """
  @spec change_phase(State.t(), atom()) :: result()
  def change_phase(state, to_phase) do
    if Machine.can_transition?(state.phase, to_phase) do
      event = %PhaseChanged{
        task_id: state.task_id,
        from_phase: state.phase,
        to_phase: to_phase,
        changed_at: System.system_time(:second)
      }

      {:ok, [event]}
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Cancels the task.

  This is a special transition that's always allowed from non-terminal phases.
  """
  @spec cancel(State.t(), String.t(), String.t() | nil) :: result()
  def cancel(state, _cancelled_by, _reason \\ nil) do
    if Machine.terminal?(state.phase) do
      {:error, :already_terminal}
    else
      event = %PhaseChanged{
        task_id: state.task_id,
        from_phase: state.phase,
        to_phase: :cancelled,
        changed_at: System.system_time(:second)
      }

      # Could also emit a TaskCancelled event with more details
      {:ok, [event]}
    end
  end

  # Helpers

  defp transition_pending?(state, to_phase) do
    Enum.any?(state.pending_transitions, fn t -> t.to_phase == to_phase end)
  end
end
