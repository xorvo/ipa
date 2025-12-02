defmodule Ipa.Pod.State.Projections.TrackerProjectionTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.State
  alias Ipa.Pod.State.{Tracker, TrackerPhase, TrackerItem}
  alias Ipa.Pod.State.Projections.TrackerProjection

  alias Ipa.Pod.Events.{
    TrackerCreated,
    TrackerPhaseAdded,
    TrackerItemAdded,
    TrackerItemUpdated,
    TrackerItemRemoved,
    TrackerItemStatusChanged,
    TrackerItemCommentAdded,
    TrackerPhaseEtaUpdated
  }

  describe "apply/2 with TrackerCreated" do
    test "creates tracker with phases and items" do
      state = %State{task_id: "task-123", tracker: nil}

      event = %TrackerCreated{
        task_id: "task-123",
        phases: [
          %{
            phase_id: "phase-1",
            name: "Phase 1",
            eta: "2024-12-25",
            order: 0,
            items: [
              %{item_id: "item-1", summary: "Item 1", workstream_id: "ws-1", status: "todo"},
              %{item_id: "item-2", summary: "Item 2", workstream_id: "ws-2", status: "wip"}
            ]
          },
          %{
            phase_id: "phase-2",
            name: "Phase 2",
            order: 1,
            items: []
          }
        ]
      }

      new_state = TrackerProjection.apply(state, event)

      assert %Tracker{} = new_state.tracker
      assert new_state.tracker.task_id == "task-123"
      assert length(new_state.tracker.phases) == 2

      [phase1, phase2] = new_state.tracker.phases
      assert phase1.name == "Phase 1"
      assert phase1.eta == ~D[2024-12-25]
      assert length(phase1.items) == 2

      [item1, item2] = phase1.items
      assert item1.summary == "Item 1"
      assert item1.workstream_id == "ws-1"
      assert item1.status == :todo
      assert item2.status == :wip

      assert phase2.name == "Phase 2"
      assert phase2.items == []
    end
  end

  describe "apply/2 with TrackerPhaseAdded" do
    test "adds new phase to existing tracker" do
      tracker = %Tracker{
        task_id: "task-123",
        phases: [
          %TrackerPhase{phase_id: "phase-1", name: "Phase 1", order: 0, items: []}
        ]
      }

      state = %State{task_id: "task-123", tracker: tracker}

      event = %TrackerPhaseAdded{
        task_id: "task-123",
        phase_id: "phase-2",
        name: "Phase 2",
        eta: "2024-12-31",
        order: 1
      }

      new_state = TrackerProjection.apply(state, event)

      assert length(new_state.tracker.phases) == 2
      new_phase = Enum.find(new_state.tracker.phases, &(&1.phase_id == "phase-2"))
      assert new_phase.name == "Phase 2"
      assert new_phase.eta == ~D[2024-12-31]
      assert new_phase.order == 1
    end

    test "creates tracker if none exists" do
      state = %State{task_id: "task-123", tracker: nil}

      event = %TrackerPhaseAdded{
        task_id: "task-123",
        phase_id: "phase-1",
        name: "Phase 1",
        eta: nil,
        order: 0
      }

      new_state = TrackerProjection.apply(state, event)

      assert %Tracker{} = new_state.tracker
      assert length(new_state.tracker.phases) == 1
    end
  end

  describe "apply/2 with TrackerItemAdded" do
    test "adds item to specified phase" do
      tracker = %Tracker{
        task_id: "task-123",
        phases: [
          %TrackerPhase{phase_id: "phase-1", name: "Phase 1", order: 0, items: []}
        ]
      }

      state = %State{task_id: "task-123", tracker: tracker}

      event = %TrackerItemAdded{
        task_id: "task-123",
        phase_id: "phase-1",
        item_id: "item-1",
        summary: "New item",
        workstream_id: "ws-1"
      }

      new_state = TrackerProjection.apply(state, event)

      [phase] = new_state.tracker.phases
      assert length(phase.items) == 1

      [item] = phase.items
      assert item.item_id == "item-1"
      assert item.summary == "New item"
      assert item.workstream_id == "ws-1"
      assert item.status == :todo
    end
  end

  describe "apply/2 with TrackerItemUpdated" do
    test "updates item properties" do
      item = %TrackerItem{
        item_id: "item-1",
        phase_id: "phase-1",
        summary: "Original summary",
        workstream_id: "ws-1",
        status: :todo
      }

      tracker = %Tracker{
        task_id: "task-123",
        phases: [
          %TrackerPhase{phase_id: "phase-1", name: "Phase 1", order: 0, items: [item]}
        ]
      }

      state = %State{task_id: "task-123", tracker: tracker}

      event = %TrackerItemUpdated{
        task_id: "task-123",
        item_id: "item-1",
        changes: %{summary: "Updated summary", workstream_id: "ws-2"},
        updated_by: "admin"
      }

      new_state = TrackerProjection.apply(state, event)

      [phase] = new_state.tracker.phases
      [updated_item] = phase.items
      assert updated_item.summary == "Updated summary"
      assert updated_item.workstream_id == "ws-2"
    end
  end

  describe "apply/2 with TrackerItemRemoved" do
    test "removes item from phase" do
      item1 = %TrackerItem{item_id: "item-1", phase_id: "phase-1", summary: "Item 1"}
      item2 = %TrackerItem{item_id: "item-2", phase_id: "phase-1", summary: "Item 2"}

      tracker = %Tracker{
        task_id: "task-123",
        phases: [
          %TrackerPhase{phase_id: "phase-1", name: "Phase 1", order: 0, items: [item1, item2]}
        ]
      }

      state = %State{task_id: "task-123", tracker: tracker}

      event = %TrackerItemRemoved{
        task_id: "task-123",
        item_id: "item-1",
        phase_id: "phase-1",
        removed_by: "admin",
        reason: "No longer needed"
      }

      new_state = TrackerProjection.apply(state, event)

      [phase] = new_state.tracker.phases
      assert length(phase.items) == 1
      assert hd(phase.items).item_id == "item-2"
    end
  end

  describe "apply/2 with TrackerItemStatusChanged" do
    test "updates item status" do
      item = %TrackerItem{
        item_id: "item-1",
        phase_id: "phase-1",
        summary: "Item",
        status: :todo
      }

      tracker = %Tracker{
        task_id: "task-123",
        phases: [
          %TrackerPhase{phase_id: "phase-1", name: "Phase 1", order: 0, items: [item]}
        ]
      }

      state = %State{task_id: "task-123", tracker: tracker}

      event = %TrackerItemStatusChanged{
        task_id: "task-123",
        item_id: "item-1",
        from_status: :todo,
        to_status: :wip,
        changed_by: "ws-1"
      }

      new_state = TrackerProjection.apply(state, event)

      [phase] = new_state.tracker.phases
      [updated_item] = phase.items
      assert updated_item.status == :wip
    end

    test "can set blocked status" do
      item = %TrackerItem{item_id: "item-1", phase_id: "phase-1", status: :wip}

      tracker = %Tracker{
        task_id: "task-123",
        phases: [%TrackerPhase{phase_id: "phase-1", items: [item]}]
      }

      state = %State{task_id: "task-123", tracker: tracker}

      event = %TrackerItemStatusChanged{
        task_id: "task-123",
        item_id: "item-1",
        from_status: :wip,
        to_status: :blocked,
        changed_by: "ws-1",
        reason: "Waiting for external dependency"
      }

      new_state = TrackerProjection.apply(state, event)

      [phase] = new_state.tracker.phases
      [updated_item] = phase.items
      assert updated_item.status == :blocked
    end
  end

  describe "apply/2 with TrackerItemCommentAdded" do
    test "adds comment to item" do
      item = %TrackerItem{
        item_id: "item-1",
        phase_id: "phase-1",
        summary: "Item",
        comments: []
      }

      tracker = %Tracker{
        task_id: "task-123",
        phases: [%TrackerPhase{phase_id: "phase-1", items: [item]}]
      }

      state = %State{task_id: "task-123", tracker: tracker}

      event = %TrackerItemCommentAdded{
        task_id: "task-123",
        item_id: "item-1",
        comment_id: "comment-1",
        content: "This is a comment",
        author: "user-1"
      }

      new_state = TrackerProjection.apply(state, event)

      [phase] = new_state.tracker.phases
      [updated_item] = phase.items
      assert length(updated_item.comments) == 1

      [comment] = updated_item.comments
      assert comment.content == "This is a comment"
      assert comment.author == "user-1"
    end
  end

  describe "apply/2 with TrackerPhaseEtaUpdated" do
    test "updates phase ETA" do
      tracker = %Tracker{
        task_id: "task-123",
        phases: [
          %TrackerPhase{phase_id: "phase-1", name: "Phase 1", eta: ~D[2024-12-01], items: []}
        ]
      }

      state = %State{task_id: "task-123", tracker: tracker}

      event = %TrackerPhaseEtaUpdated{
        task_id: "task-123",
        phase_id: "phase-1",
        eta: "2024-12-31",
        updated_by: "admin"
      }

      new_state = TrackerProjection.apply(state, event)

      [phase] = new_state.tracker.phases
      assert phase.eta == ~D[2024-12-31]
    end
  end
end
