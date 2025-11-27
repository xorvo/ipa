defmodule Ipa.Pod.Commands.PhaseCommandsTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.State
  alias Ipa.Pod.Commands.PhaseCommands

  alias Ipa.Pod.Events.{
    TransitionRequested,
    TransitionApproved,
    PhaseChanged
  }

  describe "request_transition/3" do
    test "creates TransitionRequested event" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        spec: %{approved?: true}
      }

      assert {:ok, [event]} =
               PhaseCommands.request_transition(state, :planning, "Spec is approved")

      assert %TransitionRequested{} = event
      assert event.from_phase == :spec_clarification
      assert event.to_phase == :planning
      assert event.reason == "Spec is approved"
    end

    test "fails for invalid transition" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification
      }

      assert {:error, msg} = PhaseCommands.request_transition(state, :completed, "Skip to end")
      assert msg =~ "Invalid transition"
    end

    test "fails when guards not satisfied" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        spec: %{approved?: false}
      }

      assert {:error, msg} = PhaseCommands.request_transition(state, :planning, "Try anyway")
      assert msg =~ "Spec must be approved"
    end
  end

  describe "approve_transition/3" do
    test "creates TransitionApproved event" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        pending_transitions: [
          %{
            to_phase: :planning,
            from_phase: :spec_clarification,
            reason: "Ready"
          }
        ]
      }

      assert {:ok, [event]} =
               PhaseCommands.approve_transition(state, :planning, "user-1")

      assert %TransitionApproved{} = event
      assert event.to_phase == :planning
      assert event.approved_by == "user-1"
    end

    test "fails if no pending transition" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        pending_transitions: []
      }

      assert {:error, :no_pending_transition} =
               PhaseCommands.approve_transition(state, :planning, "user-1")
    end
  end

  describe "change_phase/2" do
    test "creates PhaseChanged event" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        spec: %{approved?: true}
      }

      assert {:ok, [event]} = PhaseCommands.change_phase(state, :planning)
      assert %PhaseChanged{} = event
      assert event.from_phase == :spec_clarification
      assert event.to_phase == :planning
    end

    test "fails for invalid transition" do
      state = %State{
        task_id: "task-123",
        phase: :completed
      }

      assert {:error, :invalid_transition} =
               PhaseCommands.change_phase(state, :planning)
    end
  end

  describe "cancel/3" do
    test "creates PhaseChanged event to cancelled" do
      state = %State{
        task_id: "task-123",
        phase: :planning
      }

      assert {:ok, [event]} = PhaseCommands.cancel(state, "user-1", "No longer needed")
      assert %PhaseChanged{} = event
      assert event.from_phase == :planning
      assert event.to_phase == :cancelled
    end

    test "fails if already in terminal state" do
      state = %State{
        task_id: "task-123",
        phase: :completed
      }

      assert {:error, :already_terminal} = PhaseCommands.cancel(state, "user-1", "Try cancel")
    end

    test "fails if already cancelled" do
      state = %State{
        task_id: "task-123",
        phase: :cancelled
      }

      assert {:error, :already_terminal} = PhaseCommands.cancel(state, "user-1", "Cancel again")
    end
  end
end
