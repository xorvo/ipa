defmodule Ipa.Pod.State.Projections.PhaseProjection do
  @moduledoc "Projects phase transition events onto state."

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    TransitionRequested,
    TransitionApproved,
    PhaseChanged
  }

  @doc "Applies a phase event to state."
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, %TransitionRequested{} = event) do
    # Don't add duplicate pending transitions
    if transition_pending?(state, event.to_phase) do
      state
    else
      transition = %{
        to_phase: event.to_phase,
        from_phase: event.from_phase,
        reason: event.reason,
        requested_by: event.requested_by,
        requested_at: System.system_time(:second)
      }

      %{state | pending_transitions: [transition | state.pending_transitions]}
    end
  end

  def apply(state, %TransitionApproved{} = event) do
    %{
      state
      | phase: event.to_phase,
        pending_transitions: []
    }
  end

  def apply(state, %PhaseChanged{} = event) do
    %{
      state
      | phase: event.to_phase,
        pending_transitions: []
    }
  end

  def apply(state, _event), do: state

  defp transition_pending?(state, to_phase) do
    Enum.any?(state.pending_transitions, fn t -> t.to_phase == to_phase end)
  end
end
