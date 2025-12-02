defmodule Ipa.Pod.State.Projections.ActionApprovalProjectionTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.State
  alias Ipa.Pod.State.ActionApprovalRequest
  alias Ipa.Pod.State.Projections.ActionApprovalProjection

  alias Ipa.Pod.Events.{
    ActionApprovalRequested,
    ActionApprovalGranted,
    ActionApprovalRejected
  }

  describe "apply/2 with ActionApprovalRequested" do
    test "adds pending approval request to state" do
      state = %State{
        task_id: "task-123",
        pending_action_approvals: []
      }

      event = %ActionApprovalRequested{
        task_id: "task-123",
        request_id: "req-456",
        action_type: :tracker_add_item,
        action_payload: %{phase_id: "phase-1", summary: "New item"},
        requested_by: "workstream-1",
        reason: "Discovered new requirement"
      }

      new_state = ActionApprovalProjection.apply(state, event)

      assert length(new_state.pending_action_approvals) == 1
      [request] = new_state.pending_action_approvals

      assert %ActionApprovalRequest{} = request
      assert request.request_id == "req-456"
      assert request.task_id == "task-123"
      assert request.action_type == :tracker_add_item
      assert request.action_payload == %{phase_id: "phase-1", summary: "New item"}
      assert request.requested_by == "workstream-1"
      assert request.reason == "Discovered new requirement"
      assert request.status == :pending
      assert request.decided_by == nil
      assert request.decided_at == nil
    end

    test "appends to existing pending approvals" do
      existing_request = %ActionApprovalRequest{
        request_id: "req-existing",
        task_id: "task-123",
        action_type: :tracker_update_item,
        action_payload: %{},
        requested_by: "ws-1",
        status: :pending,
        created_at: 1_000_000
      }

      state = %State{
        task_id: "task-123",
        pending_action_approvals: [existing_request]
      }

      event = %ActionApprovalRequested{
        task_id: "task-123",
        request_id: "req-new",
        action_type: :tracker_add_item,
        action_payload: %{summary: "Another item"},
        requested_by: "ws-2",
        reason: nil
      }

      new_state = ActionApprovalProjection.apply(state, event)

      assert length(new_state.pending_action_approvals) == 2
      request_ids = Enum.map(new_state.pending_action_approvals, & &1.request_id)
      assert "req-existing" in request_ids
      assert "req-new" in request_ids
    end
  end

  describe "apply/2 with ActionApprovalGranted" do
    test "updates request status to approved" do
      request = %ActionApprovalRequest{
        request_id: "req-456",
        task_id: "task-123",
        action_type: :tracker_add_item,
        action_payload: %{},
        requested_by: "ws-1",
        status: :pending,
        created_at: 1_000_000
      }

      state = %State{
        task_id: "task-123",
        pending_action_approvals: [request]
      }

      event = %ActionApprovalGranted{
        task_id: "task-123",
        request_id: "req-456",
        approved_by: "admin-user",
        comment: "Approved as requested"
      }

      new_state = ActionApprovalProjection.apply(state, event)

      assert length(new_state.pending_action_approvals) == 1
      [updated_request] = new_state.pending_action_approvals

      assert updated_request.status == :approved
      assert updated_request.decided_by == "admin-user"
      assert updated_request.decision_comment == "Approved as requested"
      assert updated_request.decided_at != nil
    end

    test "leaves other requests unchanged" do
      request1 = %ActionApprovalRequest{
        request_id: "req-1",
        task_id: "task-123",
        action_type: :tracker_add_item,
        action_payload: %{},
        requested_by: "ws-1",
        status: :pending,
        created_at: 1_000_000
      }

      request2 = %ActionApprovalRequest{
        request_id: "req-2",
        task_id: "task-123",
        action_type: :tracker_update_item,
        action_payload: %{},
        requested_by: "ws-2",
        status: :pending,
        created_at: 1_000_001
      }

      state = %State{
        task_id: "task-123",
        pending_action_approvals: [request1, request2]
      }

      event = %ActionApprovalGranted{
        task_id: "task-123",
        request_id: "req-1",
        approved_by: "admin-user",
        comment: nil
      }

      new_state = ActionApprovalProjection.apply(state, event)

      approved = Enum.find(new_state.pending_action_approvals, &(&1.request_id == "req-1"))
      pending = Enum.find(new_state.pending_action_approvals, &(&1.request_id == "req-2"))

      assert approved.status == :approved
      assert pending.status == :pending
    end
  end

  describe "apply/2 with ActionApprovalRejected" do
    test "updates request status to rejected" do
      request = %ActionApprovalRequest{
        request_id: "req-456",
        task_id: "task-123",
        action_type: :tracker_remove_item,
        action_payload: %{item_id: "item-1"},
        requested_by: "ws-1",
        status: :pending,
        created_at: 1_000_000
      }

      state = %State{
        task_id: "task-123",
        pending_action_approvals: [request]
      }

      event = %ActionApprovalRejected{
        task_id: "task-123",
        request_id: "req-456",
        rejected_by: "admin-user",
        reason: "Not appropriate for current phase"
      }

      new_state = ActionApprovalProjection.apply(state, event)

      assert length(new_state.pending_action_approvals) == 1
      [updated_request] = new_state.pending_action_approvals

      assert updated_request.status == :rejected
      assert updated_request.decided_by == "admin-user"
      assert updated_request.decision_comment == "Not appropriate for current phase"
      assert updated_request.decided_at != nil
    end
  end

  describe "get_pending/1" do
    test "returns only pending requests" do
      pending = %ActionApprovalRequest{
        request_id: "req-pending",
        status: :pending,
        task_id: "task-123",
        action_type: :tracker_add_item,
        action_payload: %{},
        requested_by: "ws-1",
        created_at: 1_000_000
      }

      approved = %ActionApprovalRequest{
        request_id: "req-approved",
        status: :approved,
        task_id: "task-123",
        action_type: :tracker_update_item,
        action_payload: %{},
        requested_by: "ws-2",
        created_at: 1_000_001
      }

      rejected = %ActionApprovalRequest{
        request_id: "req-rejected",
        status: :rejected,
        task_id: "task-123",
        action_type: :tracker_remove_item,
        action_payload: %{},
        requested_by: "ws-3",
        created_at: 1_000_002
      }

      state = %State{
        task_id: "task-123",
        pending_action_approvals: [pending, approved, rejected]
      }

      result = ActionApprovalProjection.get_pending(state)

      assert length(result) == 1
      assert hd(result).request_id == "req-pending"
    end

    test "returns empty list when no pending requests" do
      state = %State{
        task_id: "task-123",
        pending_action_approvals: []
      }

      assert ActionApprovalProjection.get_pending(state) == []
    end
  end

  describe "get_request/2" do
    test "returns request by ID" do
      request = %ActionApprovalRequest{
        request_id: "req-456",
        status: :pending,
        task_id: "task-123",
        action_type: :tracker_add_item,
        action_payload: %{},
        requested_by: "ws-1",
        created_at: 1_000_000
      }

      state = %State{
        task_id: "task-123",
        pending_action_approvals: [request]
      }

      result = ActionApprovalProjection.get_request(state, "req-456")

      assert result.request_id == "req-456"
    end

    test "returns nil when request not found" do
      state = %State{
        task_id: "task-123",
        pending_action_approvals: []
      }

      assert ActionApprovalProjection.get_request(state, "non-existent") == nil
    end
  end

  describe "get_by_requester/2" do
    test "returns requests for specific requester" do
      req1 = %ActionApprovalRequest{
        request_id: "req-1",
        status: :pending,
        task_id: "task-123",
        action_type: :tracker_add_item,
        action_payload: %{},
        requested_by: "ws-1",
        created_at: 1_000_000
      }

      req2 = %ActionApprovalRequest{
        request_id: "req-2",
        status: :pending,
        task_id: "task-123",
        action_type: :tracker_update_item,
        action_payload: %{},
        requested_by: "ws-2",
        created_at: 1_000_001
      }

      req3 = %ActionApprovalRequest{
        request_id: "req-3",
        status: :approved,
        task_id: "task-123",
        action_type: :tracker_add_item,
        action_payload: %{},
        requested_by: "ws-1",
        created_at: 1_000_002
      }

      state = %State{
        task_id: "task-123",
        pending_action_approvals: [req1, req2, req3]
      }

      result = ActionApprovalProjection.get_by_requester(state, "ws-1")

      assert length(result) == 2
      assert Enum.all?(result, &(&1.requested_by == "ws-1"))
    end
  end
end
