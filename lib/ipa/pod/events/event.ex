defmodule Ipa.Pod.Event do
  @moduledoc """
  Protocol for all pod events.

  Every event must implement:
  - `event_type/0` - Returns the string type for storage
  - `to_map/1` - Serializes struct to map for EventStore
  - `from_map/1` - Deserializes from EventStore data to struct
  """

  @callback event_type() :: String.t()
  @callback to_map(struct()) :: map()
  @callback from_map(map()) :: struct()

  @doc """
  Converts a stored event (from EventStore) to a typed struct.

  Note: stream_id is automatically added to data as task_id (if not already present)
  since most events need to know their task context.
  """
  @spec decode(%{event_type: String.t(), data: map()}) :: struct()
  def decode(%{event_type: type, data: data, stream_id: stream_id}) do
    module = type_to_module(type)
    # Ensure task_id is available in data (stream_id == task_id in our architecture)
    data_with_task_id = Map.put_new(data, :task_id, stream_id)
    module.from_map(data_with_task_id)
  end

  def decode(%{event_type: type, data: data}) do
    module = type_to_module(type)
    module.from_map(data)
  end

  @doc """
  Converts a typed event struct to EventStore format.
  """
  @spec encode(struct()) :: %{event_type: String.t(), data: map()}
  def encode(event) do
    module = event.__struct__

    %{
      event_type: module.event_type(),
      data: module.to_map(event)
    }
  end

  # Event type to module mapping
  defp type_to_module("task_created"), do: Ipa.Pod.Events.TaskCreated
  defp type_to_module("spec_updated"), do: Ipa.Pod.Events.SpecUpdated
  defp type_to_module("spec_approved"), do: Ipa.Pod.Events.SpecApproved
  defp type_to_module("plan_created"), do: Ipa.Pod.Events.PlanCreated
  defp type_to_module("plan_updated"), do: Ipa.Pod.Events.PlanUpdated
  defp type_to_module("plan_approved"), do: Ipa.Pod.Events.PlanApproved
  defp type_to_module("transition_requested"), do: Ipa.Pod.Events.TransitionRequested
  defp type_to_module("transition_approved"), do: Ipa.Pod.Events.TransitionApproved
  defp type_to_module("phase_changed"), do: Ipa.Pod.Events.PhaseChanged
  defp type_to_module("workstream_created"), do: Ipa.Pod.Events.WorkstreamCreated
  defp type_to_module("workstream_started"), do: Ipa.Pod.Events.WorkstreamStarted
  defp type_to_module("workstream_completed"), do: Ipa.Pod.Events.WorkstreamCompleted
  defp type_to_module("workstream_failed"), do: Ipa.Pod.Events.WorkstreamFailed
  defp type_to_module("message_posted"), do: Ipa.Pod.Events.MessagePosted
  defp type_to_module("approval_requested"), do: Ipa.Pod.Events.ApprovalRequested
  defp type_to_module("approval_given"), do: Ipa.Pod.Events.ApprovalGiven
  defp type_to_module("notification_created"), do: Ipa.Pod.Events.NotificationCreated
  defp type_to_module("notification_read"), do: Ipa.Pod.Events.NotificationRead
  defp type_to_module("agent_started"), do: Ipa.Pod.Events.AgentStarted
  defp type_to_module("agent_completed"), do: Ipa.Pod.Events.AgentCompleted
  defp type_to_module("agent_failed"), do: Ipa.Pod.Events.AgentFailed
  defp type_to_module("agent_interrupted"), do: Ipa.Pod.Events.AgentInterrupted
  defp type_to_module("agent_pending_start"), do: Ipa.Pod.Events.AgentPendingStart
  defp type_to_module("agent_manually_started"), do: Ipa.Pod.Events.AgentManuallyStarted
  defp type_to_module("agent_awaiting_input"), do: Ipa.Pod.Events.AgentAwaitingInput
  defp type_to_module("agent_message_sent"), do: Ipa.Pod.Events.AgentMessageSent
  defp type_to_module("agent_response_received"), do: Ipa.Pod.Events.AgentResponseReceived
  defp type_to_module("agent_marked_done"), do: Ipa.Pod.Events.AgentMarkedDone
  defp type_to_module("agent_state_snapshot"), do: Ipa.Pod.Events.AgentStateSnapshot
  defp type_to_module("base_workspace_created"), do: Ipa.Pod.Events.BaseWorkspaceCreated
  defp type_to_module("sub_workspace_created"), do: Ipa.Pod.Events.SubWorkspaceCreated
  defp type_to_module("workspace_cleanup"), do: Ipa.Pod.Events.WorkspaceCleanup
  defp type_to_module("workstream_agent_started"), do: Ipa.Pod.Events.WorkstreamAgentStarted
  defp type_to_module("task_completed"), do: Ipa.Pod.Events.TaskCompleted
  defp type_to_module("review_thread_resolved"), do: Ipa.Pod.Events.ReviewThreadResolved
  defp type_to_module("review_thread_reopened"), do: Ipa.Pod.Events.ReviewThreadReopened
  # alias to PhaseChanged
  defp type_to_module("phase_transitioned"), do: Ipa.Pod.Events.PhaseChanged
  # Fallback for unknown events - just return the raw data wrapped
  defp type_to_module(unknown), do: raise("Unknown event type: #{unknown}")
end
