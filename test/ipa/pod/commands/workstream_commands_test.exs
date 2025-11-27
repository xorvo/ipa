defmodule Ipa.Pod.Commands.WorkstreamCommandsTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.State
  alias Ipa.Pod.State.Workstream
  alias Ipa.Pod.Commands.WorkstreamCommands

  alias Ipa.Pod.Events.{
    WorkstreamCreated,
    WorkstreamStarted,
    WorkstreamCompleted,
    WorkstreamFailed
  }

  describe "create_workstream/2" do
    test "creates WorkstreamCreated event" do
      state = %State{
        task_id: "task-123",
        phase: :planning,
        workstreams: %{}
      }

      params = %{
        workstream_id: "ws-1",
        title: "Setup",
        spec: "Do the setup"
      }

      assert {:ok, [event]} = WorkstreamCommands.create_workstream(state, params)
      assert %WorkstreamCreated{} = event
      assert event.workstream_id == "ws-1"
      assert event.title == "Setup"
    end

    test "generates workstream_id if not provided" do
      state = %State{
        task_id: "task-123",
        phase: :planning,
        workstreams: %{}
      }

      params = %{title: "Setup"}

      assert {:ok, [event]} = WorkstreamCommands.create_workstream(state, params)
      assert is_binary(event.workstream_id)
    end

    test "fails if workstream already exists" do
      state = %State{
        task_id: "task-123",
        phase: :planning,
        workstreams: %{
          "ws-1" => %Workstream{workstream_id: "ws-1", title: "Existing"}
        }
      }

      params = %{workstream_id: "ws-1", title: "New"}

      assert {:error, :workstream_exists} = WorkstreamCommands.create_workstream(state, params)
    end

    test "fails without title" do
      state = %State{task_id: "task-123", phase: :planning, workstreams: %{}}

      assert {:error, :title_required} = WorkstreamCommands.create_workstream(state, %{})
    end

    test "fails if not in planning or execution phase" do
      state = %State{task_id: "task-123", phase: :spec_clarification, workstreams: %{}}

      assert {:error, :invalid_phase} =
               WorkstreamCommands.create_workstream(state, %{title: "Test"})
    end
  end

  describe "start_workstream/4" do
    test "creates WorkstreamStarted event" do
      state = %State{
        task_id: "task-123",
        workstreams: %{
          "ws-1" => %Workstream{
            workstream_id: "ws-1",
            title: "Setup",
            status: :pending,
            dependencies: [],
            blocking_on: []
          }
        }
      }

      assert {:ok, [event]} =
               WorkstreamCommands.start_workstream(state, "ws-1", "agent-1", "/workspace")

      assert %WorkstreamStarted{} = event
      assert event.agent_id == "agent-1"
      assert event.workspace_path == "/workspace"
    end

    test "fails if workstream not found" do
      state = %State{task_id: "task-123", workstreams: %{}}

      assert {:error, :workstream_not_found} =
               WorkstreamCommands.start_workstream(state, "ws-1", "agent-1")
    end

    test "fails if workstream not pending" do
      state = %State{
        task_id: "task-123",
        workstreams: %{
          "ws-1" => %Workstream{
            workstream_id: "ws-1",
            status: :in_progress,
            dependencies: [],
            blocking_on: []
          }
        }
      }

      assert {:error, :workstream_not_pending} =
               WorkstreamCommands.start_workstream(state, "ws-1", "agent-1")
    end

    test "fails if dependencies not satisfied" do
      state = %State{
        task_id: "task-123",
        workstreams: %{
          "ws-1" => %Workstream{
            workstream_id: "ws-1",
            status: :pending,
            dependencies: ["ws-0"],
            blocking_on: ["ws-0"]
          }
        }
      }

      assert {:error, :dependencies_not_satisfied} =
               WorkstreamCommands.start_workstream(state, "ws-1", "agent-1")
    end
  end

  describe "complete_workstream/3" do
    test "creates WorkstreamCompleted event" do
      state = %State{
        task_id: "task-123",
        workstreams: %{
          "ws-1" => %Workstream{
            workstream_id: "ws-1",
            status: :in_progress,
            dependencies: [],
            blocking_on: []
          }
        }
      }

      result = %{summary: "Done", artifacts: ["/path/to/file"]}

      assert {:ok, [event]} = WorkstreamCommands.complete_workstream(state, "ws-1", result)
      assert %WorkstreamCompleted{} = event
      assert event.result_summary == "Done"
    end

    test "fails if not in progress" do
      state = %State{
        task_id: "task-123",
        workstreams: %{
          "ws-1" => %Workstream{
            workstream_id: "ws-1",
            status: :pending,
            dependencies: [],
            blocking_on: []
          }
        }
      }

      assert {:error, :workstream_not_in_progress} =
               WorkstreamCommands.complete_workstream(state, "ws-1")
    end
  end

  describe "fail_workstream/4" do
    test "creates WorkstreamFailed event" do
      state = %State{
        task_id: "task-123",
        workstreams: %{
          "ws-1" => %Workstream{
            workstream_id: "ws-1",
            status: :in_progress,
            dependencies: [],
            blocking_on: []
          }
        }
      }

      assert {:ok, [event]} =
               WorkstreamCommands.fail_workstream(state, "ws-1", "Something went wrong", true)

      assert %WorkstreamFailed{} = event
      assert event.error == "Something went wrong"
      assert event.recoverable? == true
    end
  end
end
