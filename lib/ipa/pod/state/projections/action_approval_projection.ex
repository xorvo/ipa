defmodule Ipa.Pod.State.Projections.ActionApprovalProjection do
  @moduledoc """
  Projects action approval events onto state.

  This projection maintains the list of pending, approved, and rejected
  action approval requests in the state.
  """

  alias Ipa.Pod.State
  alias Ipa.Pod.State.ActionApprovalRequest

  alias Ipa.Pod.Events.{
    ActionApprovalRequested,
    ActionApprovalGranted,
    ActionApprovalRejected
  }

  @doc "Applies an action approval event to state."
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, %ActionApprovalRequested{} = event) do
    now = System.system_time(:second)

    request = %ActionApprovalRequest{
      request_id: event.request_id,
      task_id: event.task_id,
      action_type: event.action_type,
      action_payload: event.action_payload,
      requested_by: event.requested_by,
      reason: event.reason,
      status: :pending,
      decided_by: nil,
      decided_at: nil,
      decision_comment: nil,
      created_at: now
    }

    pending = [request | state.pending_action_approvals || []]
    %{state | pending_action_approvals: pending}
  end

  def apply(state, %ActionApprovalGranted{} = event) do
    now = System.system_time(:second)

    pending_action_approvals =
      Enum.map(state.pending_action_approvals || [], fn req ->
        if req.request_id == event.request_id do
          %{
            req
            | status: :approved,
              decided_by: event.approved_by,
              decided_at: now,
              decision_comment: event.comment
          }
        else
          req
        end
      end)

    %{state | pending_action_approvals: pending_action_approvals}
  end

  def apply(state, %ActionApprovalRejected{} = event) do
    now = System.system_time(:second)

    pending_action_approvals =
      Enum.map(state.pending_action_approvals || [], fn req ->
        if req.request_id == event.request_id do
          %{
            req
            | status: :rejected,
              decided_by: event.rejected_by,
              decided_at: now,
              decision_comment: event.reason
          }
        else
          req
        end
      end)

    %{state | pending_action_approvals: pending_action_approvals}
  end

  def apply(state, _event), do: state

  # Helper functions

  @doc "Gets all pending action approval requests."
  @spec get_pending(State.t()) :: [ActionApprovalRequest.t()]
  def get_pending(state) do
    (state.pending_action_approvals || [])
    |> Enum.filter(&ActionApprovalRequest.pending?/1)
  end

  @doc "Gets a specific action approval request by ID."
  @spec get_request(State.t(), String.t()) :: ActionApprovalRequest.t() | nil
  def get_request(state, request_id) do
    Enum.find(state.pending_action_approvals || [], fn req ->
      req.request_id == request_id
    end)
  end

  @doc "Gets action approval requests by requester."
  @spec get_by_requester(State.t(), String.t()) :: [ActionApprovalRequest.t()]
  def get_by_requester(state, requester_id) do
    Enum.filter(state.pending_action_approvals || [], fn req ->
      req.requested_by == requester_id
    end)
  end
end
