defmodule Ipa.Pod.MachineTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.Machine

  describe "phases/0" do
    test "returns all phases" do
      phases = Machine.phases()

      assert :spec_clarification in phases
      assert :planning in phases
      assert :workstream_execution in phases
      assert :review in phases
      assert :completed in phases
      assert :cancelled in phases
    end
  end

  describe "valid_transitions/1" do
    test "spec_clarification can transition to planning or cancelled" do
      transitions = Machine.valid_transitions(:spec_clarification)

      assert :planning in transitions
      assert :cancelled in transitions
      refute :completed in transitions
    end

    test "planning can transition to execution, back to spec, or cancelled" do
      transitions = Machine.valid_transitions(:planning)

      assert :workstream_execution in transitions
      assert :spec_clarification in transitions
      assert :cancelled in transitions
    end

    test "workstream_execution can transition to review, back to planning, or cancelled" do
      transitions = Machine.valid_transitions(:workstream_execution)

      assert :review in transitions
      assert :planning in transitions
      assert :cancelled in transitions
    end

    test "review can transition to completed, back to execution, or cancelled" do
      transitions = Machine.valid_transitions(:review)

      assert :completed in transitions
      assert :workstream_execution in transitions
      assert :cancelled in transitions
    end

    test "completed has no valid transitions" do
      assert Machine.valid_transitions(:completed) == []
    end

    test "cancelled has no valid transitions" do
      assert Machine.valid_transitions(:cancelled) == []
    end
  end

  describe "can_transition?/2" do
    test "returns true for valid transitions" do
      assert Machine.can_transition?(:spec_clarification, :planning)
      assert Machine.can_transition?(:planning, :workstream_execution)
      assert Machine.can_transition?(:workstream_execution, :review)
      assert Machine.can_transition?(:review, :completed)
    end

    test "returns false for invalid transitions" do
      refute Machine.can_transition?(:spec_clarification, :completed)
      refute Machine.can_transition?(:spec_clarification, :review)
      refute Machine.can_transition?(:completed, :planning)
    end

    test "any non-terminal state can transition to cancelled" do
      assert Machine.can_transition?(:spec_clarification, :cancelled)
      assert Machine.can_transition?(:planning, :cancelled)
      assert Machine.can_transition?(:workstream_execution, :cancelled)
      assert Machine.can_transition?(:review, :cancelled)
    end
  end

  describe "terminal?/1" do
    test "completed is terminal" do
      assert Machine.terminal?(:completed)
    end

    test "cancelled is terminal" do
      assert Machine.terminal?(:cancelled)
    end

    test "other phases are not terminal" do
      refute Machine.terminal?(:spec_clarification)
      refute Machine.terminal?(:planning)
      refute Machine.terminal?(:workstream_execution)
      refute Machine.terminal?(:review)
    end
  end

  describe "initial?/1" do
    test "spec_clarification is initial" do
      assert Machine.initial?(:spec_clarification)
    end

    test "other phases are not initial" do
      refute Machine.initial?(:planning)
      refute Machine.initial?(:completed)
    end
  end

  describe "next_phase/1" do
    test "returns the next phase in happy path" do
      assert Machine.next_phase(:spec_clarification) == :planning
      assert Machine.next_phase(:planning) == :workstream_execution
      assert Machine.next_phase(:workstream_execution) == :review
      assert Machine.next_phase(:review) == :completed
    end

    test "returns nil for terminal phases" do
      assert Machine.next_phase(:completed) == nil
      assert Machine.next_phase(:cancelled) == nil
    end
  end
end
