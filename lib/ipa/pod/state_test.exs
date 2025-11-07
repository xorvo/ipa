defmodule Ipa.Pod.StateTest do
  use Ipa.DataCase, async: false

  alias Ipa.Pod.State
  alias Ipa.EventStore

  setup do
    # Generate unique task ID for each test
    task_id = "task-#{System.unique_integer([:positive, :monotonic])}"

    # Create event stream (stream_type, stream_id)
    {:ok, ^task_id} = EventStore.start_stream("task", task_id)

    # Append initial task_created event
    {:ok, _version} =
      EventStore.append(task_id, "task_created", %{title: "Test Task"}, actor_id: "test")

    on_exit(fn ->
      # Cleanup: stop State Manager if running
      case GenServer.whereis({:via, Registry, {Ipa.PodRegistry, {:pod_state, task_id}}}) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 100)
      end
    end)

    %{task_id: task_id}
  end

  describe "start_link/1" do
    test "starts State Manager and loads events", %{task_id: task_id} do
      assert {:ok, pid} = State.start_link(task_id: task_id)
      assert Process.alive?(pid)

      # Should load initial state
      {:ok, state} = State.get_state(task_id)
      assert state.task_id == task_id
      assert state.version == 1
      assert state.phase == :spec_clarification
      assert state.title == "Test Task"
    end

    test "fails gracefully if stream doesn't exist" do
      task_id = "non-existent-task"

      # GenServer init will fail and stop with :stream_not_found reason
      # This causes start_link to fail with EXIT
      Process.flag(:trap_exit, true)
      assert {:error, _} = State.start_link(task_id: task_id)
    end

    test "registers via Registry", %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)

      # Should be registered
      [{pid, _meta}] = Registry.lookup(Ipa.PodRegistry, {:pod_state, task_id})
      assert Process.alive?(pid)
    end
  end

  describe "append_event/5" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "appends event successfully", %{task_id: task_id} do
      {:ok, state} = State.get_state(task_id)

      {:ok, new_version} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Test description"}},
          state.version
        )

      assert new_version == 2

      # State should be updated
      {:ok, new_state} = State.get_state(task_id)
      assert new_state.version == 2
      assert new_state.spec.description == "Test description"
    end

    test "increments version correctly", %{task_id: task_id} do
      {:ok, v1} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "First update"}},
          nil
        )

      {:ok, v2} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Second update"}},
          nil
        )

      assert v2 == v1 + 1
    end

    test "detects version conflicts", %{task_id: task_id} do
      # Process A gets state
      {:ok, state_a} = State.get_state(task_id)

      # Process B appends event
      {:ok, _v2} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Process B update"}},
          state_a.version
        )

      # Process A tries to append with old version
      assert {:error, :version_conflict} =
               State.append_event(
                 task_id,
                 "spec_updated",
                 %{spec: %{description: "Process A update"}},
                 state_a.version
               )
    end

    test "validates events before appending", %{task_id: task_id} do
      # Try to approve spec without description
      assert {:error, {:validation_failed, _reason}} =
               State.append_event(
                 task_id,
                 "spec_approved",
                 %{approved_by: "user-123"},
                 nil
               )
    end

    test "updates in-memory state after appending", %{task_id: task_id} do
      {:ok, _version} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "New description"}},
          nil
        )

      # State should be immediately available
      {:ok, state} = State.get_state(task_id)
      assert state.spec.description == "New description"
    end

    test "includes actor_id in metadata", %{task_id: task_id} do
      {:ok, version} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Test"}},
          nil,
          actor_id: "user-456"
        )

      # Verify event has actor_id (from_version is exclusive, so use version - 1)
      {:ok, events} = EventStore.read_stream(task_id, from_version: version - 1, max_count: 1)
      assert [event] = events
      assert event.actor_id == "user-456"
    end
  end

  describe "get_state/1" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "returns current state", %{task_id: task_id} do
      {:ok, state} = State.get_state(task_id)

      assert state.task_id == task_id
      assert state.version == 1
      assert state.phase == :spec_clarification
      assert is_map(state.spec)
      assert is_list(state.agents)
    end

    test "returns error if State Manager not running" do
      assert {:error, :not_found} = State.get_state("non-existent-task")
    end
  end

  describe "pub-sub integration" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "broadcasts state updates", %{task_id: task_id} do
      # Subscribe to state changes
      State.subscribe(task_id)

      # Append event
      {:ok, _version} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Test"}},
          nil
        )

      # Should receive broadcast
      assert_receive {:state_updated, ^task_id, new_state}, 1000
      assert new_state.spec.description == "Test"
    end

    test "multiple subscribers receive messages", %{task_id: task_id} do
      # Subscribe from multiple processes
      parent = self()

      spawn(fn ->
        State.subscribe(task_id)

        receive do
          {:state_updated, ^task_id, _state} -> send(parent, {:subscriber_1, :ok})
        after
          1000 -> send(parent, {:subscriber_1, :timeout})
        end
      end)

      spawn(fn ->
        State.subscribe(task_id)

        receive do
          {:state_updated, ^task_id, _state} -> send(parent, {:subscriber_2, :ok})
        after
          1000 -> send(parent, {:subscriber_2, :timeout})
        end
      end)

      # Give subscribers time to subscribe
      Process.sleep(50)

      # Append event
      {:ok, _version} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Test"}},
          nil
        )

      # Both subscribers should receive message
      assert_receive {:subscriber_1, :ok}, 1000
      assert_receive {:subscriber_2, :ok}, 1000
    end
  end

  describe "event application" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "applies spec_updated event", %{task_id: task_id} do
      {:ok, _version} =
        State.append_event(
          task_id,
          "spec_updated",
          %{
            spec: %{
              description: "Test description",
              requirements: ["req1", "req2"],
              acceptance_criteria: ["ac1"]
            }
          },
          nil
        )

      {:ok, state} = State.get_state(task_id)
      assert state.spec.description == "Test description"
      assert state.spec.requirements == ["req1", "req2"]
      assert state.spec.acceptance_criteria == ["ac1"]
      assert state.spec.approved? == false
    end

    test "applies spec_approved event", %{task_id: task_id} do
      # First update spec
      {:ok, _v} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Test"}},
          nil
        )

      # Then approve
      {:ok, _v} =
        State.append_event(
          task_id,
          "spec_approved",
          %{approved_by: "user-123"},
          nil
        )

      {:ok, state} = State.get_state(task_id)
      assert state.spec.approved? == true
      assert state.spec.approved_by == "user-123"
      assert is_integer(state.spec.approved_at)
    end

    test "applies agent_started event", %{task_id: task_id} do
      {:ok, _v} =
        State.append_event(
          task_id,
          "agent_started",
          %{
            agent_id: "agent-1",
            agent_type: "planning",
            workspace: "/workspace/agent-1"
          },
          nil
        )

      {:ok, state} = State.get_state(task_id)
      assert length(state.agents) == 1

      [agent] = state.agents
      assert agent.agent_id == "agent-1"
      assert agent.status == :running
      assert agent.workspace == "/workspace/agent-1"
    end

    test "applies agent_completed event", %{task_id: task_id} do
      # Start agent
      {:ok, _v} =
        State.append_event(
          task_id,
          "agent_started",
          %{agent_id: "agent-1", agent_type: "planning", workspace: "/ws"},
          nil
        )

      # Complete agent
      {:ok, _v} =
        State.append_event(
          task_id,
          "agent_completed",
          %{agent_id: "agent-1", result: %{status: "success"}},
          nil
        )

      {:ok, state} = State.get_state(task_id)
      [agent] = state.agents
      assert agent.status == :completed
      assert agent.result == %{status: "success"}
      assert is_integer(agent.completed_at)
    end

    test "applies transition_approved event", %{task_id: task_id} do
      # First update spec and approve
      {:ok, _v} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Test"}},
          nil
        )

      {:ok, _v} = State.append_event(task_id, "spec_approved", %{approved_by: "user"}, nil)

      # Request transition
      {:ok, _v} =
        State.append_event(
          task_id,
          "transition_requested",
          %{from_phase: :spec_clarification, to_phase: :planning, reason: "Ready"},
          nil
        )

      # Approve transition
      {:ok, _v} =
        State.append_event(
          task_id,
          "transition_approved",
          %{to_phase: :planning, approved_by: "user"},
          nil
        )

      {:ok, state} = State.get_state(task_id)
      assert state.phase == :planning
      assert Enum.empty?(state.pending_transitions)
    end
  end

  describe "workstream operations" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "creates workstream", %{task_id: task_id} do
      {:ok, _v} =
        State.append_event(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-1",
            spec: "Implement feature X",
            dependencies: []
          },
          nil
        )

      {:ok, workstream} = State.get_workstream(task_id, "ws-1")
      assert workstream.workstream_id == "ws-1"
      assert workstream.spec == "Implement feature X"
      assert workstream.status == :pending
      assert workstream.dependencies == []
      assert workstream.blocking_on == []
    end

    test "lists all workstreams", %{task_id: task_id} do
      {:ok, _v} =
        State.append_event(task_id, "workstream_created", %{
          workstream_id: "ws-1",
          spec: "Feature 1",
          dependencies: []
        }, nil)

      {:ok, _v} =
        State.append_event(task_id, "workstream_created", %{
          workstream_id: "ws-2",
          spec: "Feature 2",
          dependencies: []
        }, nil)

      {:ok, workstreams} = State.list_workstreams(task_id)
      assert map_size(workstreams) == 2
      assert Map.has_key?(workstreams, "ws-1")
      assert Map.has_key?(workstreams, "ws-2")
    end

    test "tracks active workstreams", %{task_id: task_id} do
      # Create workstreams
      {:ok, _v} =
        State.append_event(task_id, "workstream_created", %{
          workstream_id: "ws-1",
          spec: "Feature 1",
          dependencies: []
        }, nil)

      {:ok, _v} =
        State.append_event(task_id, "workstream_created", %{
          workstream_id: "ws-2",
          spec: "Feature 2",
          dependencies: []
        }, nil)

      # Start one workstream
      {:ok, _v} =
        State.append_event(task_id, "workstream_agent_started", %{
          workstream_id: "ws-1",
          agent_id: "agent-1",
          workspace: "/ws"
        }, nil)

      {:ok, active} = State.get_active_workstreams(task_id)
      assert length(active) == 1
      assert hd(active).workstream_id == "ws-1"

      {:ok, state} = State.get_state(task_id)
      assert state.active_workstream_count == 1
    end

    test "handles workstream dependencies", %{task_id: task_id} do
      # Create ws-1 (no dependencies)
      {:ok, _v} =
        State.append_event(task_id, "workstream_created", %{
          workstream_id: "ws-1",
          spec: "Feature 1",
          dependencies: []
        }, nil)

      # Create ws-2 (depends on ws-1)
      {:ok, _v} =
        State.append_event(task_id, "workstream_created", %{
          workstream_id: "ws-2",
          spec: "Feature 2",
          dependencies: ["ws-1"]
        }, nil)

      {:ok, ws2} = State.get_workstream(task_id, "ws-2")
      assert ws2.dependencies == ["ws-1"]
      assert ws2.blocking_on == ["ws-1"]

      # Complete ws-1
      {:ok, _v} =
        State.append_event(task_id, "workstream_agent_started", %{
          workstream_id: "ws-1",
          agent_id: "agent-1",
          workspace: "/ws"
        }, nil)

      {:ok, _v} =
        State.append_event(task_id, "workstream_completed", %{
          workstream_id: "ws-1",
          result: %{}
        }, nil)

      # ws-2 should be unblocked
      {:ok, ws2_updated} = State.get_workstream(task_id, "ws-2")
      assert ws2_updated.blocking_on == []
    end

    test "validates max concurrency", %{task_id: task_id} do
      # Create 3 workstreams (max concurrency default is 3)
      for i <- 1..3 do
        {:ok, _v} =
          State.append_event(task_id, "workstream_created", %{
            workstream_id: "ws-#{i}",
            spec: "Feature #{i}",
            dependencies: []
          }, nil)
      end

      # Start all 3
      for i <- 1..3 do
        {:ok, _v} =
          State.append_event(task_id, "workstream_agent_started", %{
            workstream_id: "ws-#{i}",
            agent_id: "agent-#{i}",
            workspace: "/ws"
          }, nil)
      end

      # Try to create and start a 4th
      {:ok, _v} =
        State.append_event(task_id, "workstream_created", %{
          workstream_id: "ws-4",
          spec: "Feature 4",
          dependencies: []
        }, nil)

      assert {:error, {:validation_failed, _reason}} =
               State.append_event(task_id, "workstream_agent_started", %{
                 workstream_id: "ws-4",
                 agent_id: "agent-4",
                 workspace: "/ws"
               }, nil)
    end
  end

  describe "message operations" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "posts message", %{task_id: task_id} do
      {:ok, _v} =
        State.append_event(task_id, "message_posted", %{
          message_id: "msg-1",
          type: :update,
          content: "Progress update",
          author: "agent-1"
        }, nil)

      {:ok, messages} = State.get_messages(task_id)
      assert length(messages) == 1

      [msg] = messages
      assert msg.message_id == "msg-1"
      assert msg.type == :update
      assert msg.content == "Progress update"
    end

    test "filters messages by thread", %{task_id: task_id} do
      # Root message
      {:ok, _v} =
        State.append_event(task_id, "message_posted", %{
          message_id: "msg-1",
          type: :question,
          content: "Question?",
          author: "agent-1"
        }, nil)

      # Reply
      {:ok, _v} =
        State.append_event(task_id, "message_posted", %{
          message_id: "msg-2",
          type: :update,
          content: "Answer",
          author: "user-1",
          thread_id: "msg-1"
        }, nil)

      # Unrelated message
      {:ok, _v} =
        State.append_event(task_id, "message_posted", %{
          message_id: "msg-3",
          type: :update,
          content: "Other",
          author: "agent-2"
        }, nil)

      {:ok, thread} = State.get_messages(task_id, thread_id: "msg-1")
      assert length(thread) == 2
      assert Enum.any?(thread, &(&1.message_id == "msg-1"))
      assert Enum.any?(thread, &(&1.message_id == "msg-2"))
    end

    test "requests approval", %{task_id: task_id} do
      {:ok, _v} =
        State.append_event(task_id, "approval_requested", %{
          message_id: "approve-1",
          question: "Proceed with deployment?",
          options: ["Yes", "No"],
          author: "agent-1",
          blocking?: true
        }, nil)

      {:ok, messages} = State.get_messages(task_id)
      [approval] = messages

      assert approval.type == :approval
      assert approval.approval_options == ["Yes", "No"]
      assert approval.blocking? == true
      assert approval.approval_choice == nil
    end

    test "gives approval", %{task_id: task_id} do
      # Request approval
      {:ok, _v} =
        State.append_event(task_id, "approval_requested", %{
          message_id: "approve-1",
          question: "Proceed?",
          options: ["Yes", "No"],
          author: "agent-1"
        }, nil)

      # Give approval
      {:ok, _v} =
        State.append_event(task_id, "approval_given", %{
          message_id: "approve-1",
          approved_by: "user-1",
          choice: "Yes",
          comment: "Looks good"
        }, nil)

      {:ok, messages} = State.get_messages(task_id)
      [approval] = messages

      assert approval.approval_choice == "Yes"
      assert approval.approval_given_by == "user-1"
      assert is_integer(approval.approval_given_at)
    end
  end

  describe "inbox operations" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "creates notification", %{task_id: task_id} do
      {:ok, _v} =
        State.append_event(task_id, "notification_created", %{
          notification_id: "notif-1",
          recipient: "user-1",
          message_id: "msg-1",
          type: :question_asked,
          message_preview: "Agent has a question..."
        }, nil)

      {:ok, inbox} = State.get_inbox(task_id)
      assert length(inbox) == 1

      [notif] = inbox
      assert notif.notification_id == "notif-1"
      assert notif.recipient == "user-1"
      assert notif.read? == false
    end

    test "filters unread notifications", %{task_id: task_id} do
      # Create two notifications
      {:ok, _v} =
        State.append_event(task_id, "notification_created", %{
          notification_id: "notif-1",
          recipient: "user-1",
          message_id: "msg-1",
          type: :question_asked,
          message_preview: "Question 1"
        }, nil)

      {:ok, _v} =
        State.append_event(task_id, "notification_created", %{
          notification_id: "notif-2",
          recipient: "user-1",
          message_id: "msg-2",
          type: :question_asked,
          message_preview: "Question 2"
        }, nil)

      # Mark one as read
      {:ok, _v} =
        State.append_event(task_id, "notification_read", %{
          notification_id: "notif-1",
          read_by: "user-1"
        }, nil)

      {:ok, unread} = State.get_inbox(task_id, unread_only?: true)
      assert length(unread) == 1
      assert hd(unread).notification_id == "notif-2"
    end

    test "filters by recipient", %{task_id: task_id} do
      {:ok, _v} =
        State.append_event(task_id, "notification_created", %{
          notification_id: "notif-1",
          recipient: "user-1",
          message_id: "msg-1",
          type: :question_asked,
          message_preview: "For user 1"
        }, nil)

      {:ok, _v} =
        State.append_event(task_id, "notification_created", %{
          notification_id: "notif-2",
          recipient: "user-2",
          message_id: "msg-2",
          type: :question_asked,
          message_preview: "For user 2"
        }, nil)

      {:ok, inbox} = State.get_inbox(task_id, recipient: "user-1")
      assert length(inbox) == 1
      assert hd(inbox).recipient == "user-1"
    end
  end

  describe "reload_state/1" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "reloads state from Event Store", %{task_id: task_id} do
      # Append event via State Manager
      {:ok, _v} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Original"}},
          nil
        )

      # Manually append event via Event Store (bypass State Manager)
      {:ok, _v} =
        EventStore.append(
          task_id,
          "spec_updated",
          %{spec: %{description: "Manual update"}},
          actor_id: "test"
        )

      # State Manager still has old state
      {:ok, state} = State.get_state(task_id)
      assert state.spec.description == "Original"

      # Reload
      {:ok, new_state} = State.reload_state(task_id)
      assert new_state.spec.description == "Manual update"
    end
  end

  describe "concurrent operations" do
    setup %{task_id: task_id} do
      {:ok, _pid} = State.start_link(task_id: task_id)
      %{task_id: task_id}
    end

    test "handles concurrent appends with retry", %{task_id: task_id} do
      parent = self()

      # Spawn multiple processes trying to append
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            result =
              Enum.reduce_while(1..10, {:error, :retry}, fn _attempt, _acc ->
                {:ok, state} = State.get_state(task_id)

                case State.append_event(
                       task_id,
                       "spec_updated",
                       %{spec: %{description: "Update #{i}"}},
                       state.version
                     ) do
                  {:ok, version} ->
                    {:halt, {:ok, version}}

                  {:error, :version_conflict} ->
                    # Add small random delay to reduce contention
                    Process.sleep(:rand.uniform(50))
                    {:cont, {:error, :retry}}

                  error ->
                    {:halt, error}
                end
              end)

            send(parent, {:process_done, i, result})
            result
          end)
        end

      # Wait for all tasks
      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _version} -> true
               _ -> false
             end)

      # Final version should be 11 (initial + 10 updates)
      {:ok, final_state} = State.get_state(task_id)
      assert final_state.version == 11
    end
  end

  describe "terminate/2" do
    test "saves snapshot on shutdown", %{task_id: task_id} do
      {:ok, pid} = State.start_link(task_id: task_id)

      # Append some events
      {:ok, _v} =
        State.append_event(
          task_id,
          "spec_updated",
          %{spec: %{description: "Test"}},
          nil
        )

      # Stop the State Manager
      GenServer.stop(pid)

      # Wait for shutdown
      Process.sleep(100)

      # Snapshot should be saved
      {:ok, %{state: snapshot_state}} = EventStore.load_snapshot(task_id)
      assert snapshot_state.spec.description == "Test"
    end
  end
end
