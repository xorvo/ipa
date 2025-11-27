defmodule Ipa.Pod.State.Projector do
  @moduledoc """
  Applies events to state. Routes events to specific projection modules.

  The Projector is the central point for event → state transformation.
  It delegates to specialized projection modules for each domain.
  """

  alias Ipa.Pod.State
  alias Ipa.Pod.Event

  alias Ipa.Pod.State.Projections.{
    TaskProjection,
    PhaseProjection,
    WorkstreamProjection,
    CommunicationProjection,
    AgentProjection
  }

  @doc """
  Applies a single event to state, returning updated state.

  Accepts both typed event structs and raw event maps (from EventStore).
  """
  @spec apply(State.t(), struct() | map()) :: State.t()
  def apply(state, %{event_type: _, data: _} = raw_event) do
    # Convert raw event to typed struct
    typed_event = Event.decode(raw_event)
    apply_typed(state, typed_event, raw_event)
  end

  def apply(state, typed_event) when is_struct(typed_event) do
    apply_typed(state, typed_event, nil)
  end

  @doc """
  Replays a list of events to build state from scratch.
  """
  @spec replay([struct() | map()], State.t()) :: State.t()
  def replay(events, initial_state) do
    Enum.reduce(events, initial_state, &__MODULE__.apply(&2, &1))
  end

  # Apply typed event and update metadata
  defp apply_typed(state, event, raw_event) do
    state
    |> apply_to_projection(event)
    |> update_metadata(raw_event)
  end

  # Route events to appropriate projection
  defp apply_to_projection(state, event) do
    cond do
      task_event?(event) -> TaskProjection.apply(state, event)
      phase_event?(event) -> PhaseProjection.apply(state, event)
      workstream_event?(event) -> WorkstreamProjection.apply(state, event)
      communication_event?(event) -> CommunicationProjection.apply(state, event)
      agent_event?(event) -> AgentProjection.apply(state, event)
      true -> state
    end
  end

  defp update_metadata(state, nil), do: state

  defp update_metadata(state, %{version: v, inserted_at: t}) do
    %{state | version: v, updated_at: t}
  end

  defp update_metadata(state, _), do: state

  # Event type checks
  defp task_event?(%Ipa.Pod.Events.TaskCreated{}), do: true
  defp task_event?(%Ipa.Pod.Events.SpecUpdated{}), do: true
  defp task_event?(%Ipa.Pod.Events.SpecApproved{}), do: true
  defp task_event?(%Ipa.Pod.Events.PlanCreated{}), do: true
  defp task_event?(%Ipa.Pod.Events.PlanUpdated{}), do: true
  defp task_event?(%Ipa.Pod.Events.PlanApproved{}), do: true
  defp task_event?(_), do: false

  defp phase_event?(%Ipa.Pod.Events.TransitionRequested{}), do: true
  defp phase_event?(%Ipa.Pod.Events.TransitionApproved{}), do: true
  defp phase_event?(%Ipa.Pod.Events.PhaseChanged{}), do: true
  defp phase_event?(_), do: false

  defp workstream_event?(%Ipa.Pod.Events.WorkstreamCreated{}), do: true
  defp workstream_event?(%Ipa.Pod.Events.WorkstreamStarted{}), do: true
  defp workstream_event?(%Ipa.Pod.Events.WorkstreamAgentStarted{}), do: true
  defp workstream_event?(%Ipa.Pod.Events.WorkstreamCompleted{}), do: true
  defp workstream_event?(%Ipa.Pod.Events.WorkstreamFailed{}), do: true
  defp workstream_event?(_), do: false

  defp communication_event?(%Ipa.Pod.Events.MessagePosted{}), do: true
  defp communication_event?(%Ipa.Pod.Events.ApprovalRequested{}), do: true
  defp communication_event?(%Ipa.Pod.Events.ApprovalGiven{}), do: true
  defp communication_event?(%Ipa.Pod.Events.NotificationCreated{}), do: true
  defp communication_event?(%Ipa.Pod.Events.NotificationRead{}), do: true
  defp communication_event?(_), do: false

  defp agent_event?(%Ipa.Pod.Events.AgentStarted{}), do: true
  defp agent_event?(%Ipa.Pod.Events.AgentCompleted{}), do: true
  defp agent_event?(%Ipa.Pod.Events.AgentFailed{}), do: true
  defp agent_event?(_), do: false
end
