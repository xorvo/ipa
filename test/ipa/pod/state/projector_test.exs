defmodule Ipa.Pod.State.ProjectorTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.State
  alias Ipa.Pod.State.Projector

  alias Ipa.Pod.Events.{
    TaskCreated,
    SpecUpdated,
    SpecApproved,
    WorkstreamCreated,
    WorkstreamStarted,
    WorkstreamCompleted,
    MessagePosted,
    ApprovalRequested,
    TransitionRequested
  }

  describe "apply/2 with TaskCreated" do
    test "initializes state from TaskCreated" do
      state = State.new("task-123")

      event = %TaskCreated{
        task_id: "task-123",
        title: "Test Task",
        description: "Description",
        requirements: ["req1"],
        acceptance_criteria: ["ac1"]
      }

      new_state = Projector.apply(state, event)

      assert new_state.task_id == "task-123"
      assert new_state.title == "Test Task"
      # Description is now stored as content
      assert new_state.spec.content == "Description"
      assert new_state.spec.generation_status == :idle
      assert new_state.phase == :spec_clarification
    end
  end

  describe "apply/2 with spec events" do
    test "SpecUpdated updates spec fields" do
      state = %State{
        task_id: "task-123",
        spec: %{content: "old", workspace_path: nil, generation_status: :idle, approved?: false}
      }

      event = %SpecUpdated{
        task_id: "task-123",
        content: "# New Spec\n\nUpdated content",
        workspace_path: "/tmp/workspaces/task-123"
      }

      new_state = Projector.apply(state, event)

      assert new_state.spec.content == "# New Spec\n\nUpdated content"
      assert new_state.spec.workspace_path == "/tmp/workspaces/task-123"
    end

    test "SpecApproved marks spec as approved" do
      state = %State{
        task_id: "task-123",
        spec: %{approved?: false}
      }

      event = %SpecApproved{
        task_id: "task-123",
        approved_by: "user-1"
      }

      new_state = Projector.apply(state, event)

      assert new_state.spec.approved? == true
      assert new_state.spec.approved_by == "user-1"
    end
  end

  describe "apply/2 with workstream events" do
    test "WorkstreamCreated adds workstream" do
      state = %State{task_id: "task-123", workstreams: %{}}

      event = %WorkstreamCreated{
        task_id: "task-123",
        workstream_id: "ws-1",
        title: "Setup",
        spec: "Do setup",
        dependencies: []
      }

      new_state = Projector.apply(state, event)

      assert Map.has_key?(new_state.workstreams, "ws-1")
      ws = new_state.workstreams["ws-1"]
      assert ws.title == "Setup"
      assert ws.status == :pending
    end

    test "WorkstreamStarted updates status" do
      state = %State{
        task_id: "task-123",
        workstreams: %{
          "ws-1" => %State.Workstream{
            workstream_id: "ws-1",
            title: "Setup",
            status: :pending,
            dependencies: [],
            blocking_on: []
          }
        }
      }

      event = %WorkstreamStarted{
        task_id: "task-123",
        workstream_id: "ws-1",
        agent_id: "agent-1"
      }

      new_state = Projector.apply(state, event)

      ws = new_state.workstreams["ws-1"]
      assert ws.status == :in_progress
      assert ws.agent_id == "agent-1"
    end

    test "WorkstreamCompleted updates status and unblocks dependents" do
      state = %State{
        task_id: "task-123",
        workstreams: %{
          "ws-1" => %State.Workstream{
            workstream_id: "ws-1",
            title: "Setup",
            status: :in_progress,
            dependencies: [],
            blocking_on: []
          },
          "ws-2" => %State.Workstream{
            workstream_id: "ws-2",
            title: "Build",
            status: :pending,
            dependencies: ["ws-1"],
            blocking_on: ["ws-1"]
          }
        }
      }

      event = %WorkstreamCompleted{
        task_id: "task-123",
        workstream_id: "ws-1"
      }

      new_state = Projector.apply(state, event)

      assert new_state.workstreams["ws-1"].status == :completed
      assert new_state.workstreams["ws-2"].blocking_on == []
    end
  end

  describe "apply/2 with communication events" do
    test "MessagePosted adds message" do
      state = %State{task_id: "task-123", messages: %{}}

      event = %MessagePosted{
        task_id: "task-123",
        message_id: "msg-1",
        author: "user-1",
        content: "Hello",
        message_type: :question
      }

      new_state = Projector.apply(state, event)

      assert Map.has_key?(new_state.messages, "msg-1")
      msg = new_state.messages["msg-1"]
      assert msg.content == "Hello"
      assert msg.message_type == :question
    end

    test "ApprovalRequested adds approval message" do
      state = %State{task_id: "task-123", messages: %{}}

      event = %ApprovalRequested{
        task_id: "task-123",
        message_id: "msg-1",
        author: "agent-1",
        question: "Proceed?",
        options: ["Yes", "No"],
        blocking?: true
      }

      new_state = Projector.apply(state, event)

      msg = new_state.messages["msg-1"]
      assert msg.message_type == :approval
      assert msg.approval_options == ["Yes", "No"]
      assert msg.blocking? == true
    end
  end

  describe "apply/2 with phase events" do
    test "TransitionRequested adds pending transition" do
      state = %State{
        task_id: "task-123",
        phase: :spec_clarification,
        pending_transitions: []
      }

      event = %TransitionRequested{
        task_id: "task-123",
        from_phase: :spec_clarification,
        to_phase: :planning,
        reason: "Spec approved"
      }

      new_state = Projector.apply(state, event)

      assert length(new_state.pending_transitions) == 1
      [transition] = new_state.pending_transitions
      assert transition.to_phase == :planning
    end
  end

  describe "replay/2" do
    test "builds state from event sequence" do
      events = [
        %TaskCreated{
          task_id: "task-123",
          title: "Test Task",
          description: "Desc"
        },
        %SpecApproved{
          task_id: "task-123",
          approved_by: "user-1"
        },
        %WorkstreamCreated{
          task_id: "task-123",
          workstream_id: "ws-1",
          title: "Setup"
        }
      ]

      state = Projector.replay(events, State.new("task-123"))

      assert state.title == "Test Task"
      assert state.spec.approved? == true
      assert Map.has_key?(state.workstreams, "ws-1")
    end
  end
end
