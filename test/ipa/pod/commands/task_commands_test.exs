defmodule Ipa.Pod.Commands.TaskCommandsTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.State
  alias Ipa.Pod.Commands.TaskCommands
  alias Ipa.Pod.Events.{TaskCreated, SpecUpdated, SpecApproved}

  describe "create_task/1" do
    test "creates TaskCreated event with valid params" do
      params = %{
        task_id: "task-123",
        title: "Test Task",
        description: "A test task"
      }

      assert {:ok, [event]} = TaskCommands.create_task(params)
      assert %TaskCreated{} = event
      assert event.task_id == "task-123"
      assert event.title == "Test Task"
    end

    test "generates task_id if not provided" do
      params = %{title: "Test Task"}

      assert {:ok, [event]} = TaskCommands.create_task(params)
      assert is_binary(event.task_id)
      assert byte_size(event.task_id) > 0
    end

    test "fails without title" do
      assert {:error, :title_required} = TaskCommands.create_task(%{})
      assert {:error, :title_required} = TaskCommands.create_task(%{title: ""})
    end
  end

  describe "update_spec/2" do
    test "creates SpecUpdated event" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        spec: %{approved?: false}
      }

      params = %{
        description: "Updated description",
        requirements: ["req1"]
      }

      assert {:ok, [event]} = TaskCommands.update_spec(state, params)
      assert %SpecUpdated{} = event
      assert event.description == "Updated description"
    end

    test "fails if spec already approved" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        spec: %{approved?: true}
      }

      assert {:error, :spec_already_approved} = TaskCommands.update_spec(state, %{})
    end

    test "fails if not in spec_clarification phase" do
      state = %State{
        task_id: "task-123",
        phase: :planning,
        spec: %{approved?: false}
      }

      assert {:error, :invalid_phase} = TaskCommands.update_spec(state, %{})
    end
  end

  describe "approve_spec/3" do
    test "creates SpecApproved event" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        spec: %{approved?: false}
      }

      assert {:ok, [event]} = TaskCommands.approve_spec(state, "user-1", "Looks good")
      assert %SpecApproved{} = event
      assert event.approved_by == "user-1"
      assert event.comment == "Looks good"
    end

    test "fails if already approved" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        spec: %{approved?: true}
      }

      assert {:error, :already_approved} = TaskCommands.approve_spec(state, "user-1")
    end

    test "fails if not in spec_clarification phase" do
      state = %State{
        task_id: "task-123",
        phase: :planning,
        spec: %{approved?: false}
      }

      assert {:error, :invalid_phase} = TaskCommands.approve_spec(state, "user-1")
    end
  end
end
