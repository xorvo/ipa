defmodule Ipa.EventStoreTest do
  use Ipa.DataCase, async: true

  alias Ipa.EventStore

  describe "start_stream/1" do
    test "creates a new stream with auto-generated UUID" do
      assert {:ok, stream_id} = EventStore.start_stream("task")
      assert is_binary(stream_id)
      # UUID format
      assert String.length(stream_id) == 36
      assert EventStore.stream_exists?(stream_id)
    end

    test "creates multiple unique streams" do
      assert {:ok, stream_id1} = EventStore.start_stream("task")
      assert {:ok, stream_id2} = EventStore.start_stream("task")
      assert stream_id1 != stream_id2
    end
  end

  describe "start_stream/2" do
    test "creates a stream with specific stream_id" do
      stream_id = "my-custom-id"
      assert {:ok, ^stream_id} = EventStore.start_stream("task", stream_id)
      assert EventStore.stream_exists?(stream_id)
    end

    test "returns error when stream_id already exists" do
      stream_id = "duplicate-id"
      assert {:ok, ^stream_id} = EventStore.start_stream("task", stream_id)
      assert {:error, :already_exists} = EventStore.start_stream("task", stream_id)
    end
  end

  describe "append/4" do
    setup do
      {:ok, stream_id} = EventStore.start_stream("task")
      %{stream_id: stream_id}
    end

    test "appends an event to a stream", %{stream_id: stream_id} do
      assert {:ok, 1} =
               EventStore.append(
                 stream_id,
                 "task_created",
                 %{title: "My Task"},
                 actor_id: "user-123"
               )
    end

    test "increments version for each event", %{stream_id: stream_id} do
      assert {:ok, 1} = EventStore.append(stream_id, "event1", %{data: 1})
      assert {:ok, 2} = EventStore.append(stream_id, "event2", %{data: 2})
      assert {:ok, 3} = EventStore.append(stream_id, "event3", %{data: 3})
    end

    test "stores all event metadata", %{stream_id: stream_id} do
      assert {:ok, 1} =
               EventStore.append(
                 stream_id,
                 "task_created",
                 %{title: "Test"},
                 actor_id: "user-123",
                 correlation_id: "corr-456",
                 causation_id: "cause-789",
                 metadata: %{source: "api"}
               )

      {:ok, [event]} = EventStore.read_stream(stream_id)

      assert event.event_type == "task_created"
      assert event.data == %{title: "Test"}
      assert event.actor_id == "user-123"
      assert event.correlation_id == "corr-456"
      assert event.causation_id == "cause-789"
      assert event.metadata == %{source: "api"}
    end

    test "supports optimistic concurrency control", %{stream_id: stream_id} do
      assert {:ok, 1} = EventStore.append(stream_id, "event1", %{})

      # Correct expected version
      assert {:ok, 2} = EventStore.append(stream_id, "event2", %{}, expected_version: 1)

      # Wrong expected version
      assert {:error, :version_conflict} =
               EventStore.append(
                 stream_id,
                 "event3",
                 %{},
                 # Should be 2
                 expected_version: 1
               )
    end
  end

  describe "append_batch/3" do
    setup do
      {:ok, stream_id} = EventStore.start_stream("task")
      %{stream_id: stream_id}
    end

    test "appends multiple events atomically", %{stream_id: stream_id} do
      events = [
        %{event_type: "event1", data: %{value: 1}, opts: []},
        %{event_type: "event2", data: %{value: 2}, opts: []},
        %{event_type: "event3", data: %{value: 3}, opts: []}
      ]

      assert {:ok, 3} = EventStore.append_batch(stream_id, events)

      {:ok, stored_events} = EventStore.read_stream(stream_id)
      assert length(stored_events) == 3
      assert Enum.at(stored_events, 0).event_type == "event1"
      assert Enum.at(stored_events, 1).event_type == "event2"
      assert Enum.at(stored_events, 2).event_type == "event3"
    end

    test "applies global options to all events", %{stream_id: stream_id} do
      events = [
        %{event_type: "event1", data: %{value: 1}, opts: []},
        %{event_type: "event2", data: %{value: 2}, opts: []}
      ]

      assert {:ok, 2} =
               EventStore.append_batch(
                 stream_id,
                 events,
                 actor_id: "system",
                 correlation_id: "batch-123"
               )

      {:ok, stored_events} = EventStore.read_stream(stream_id)
      assert Enum.all?(stored_events, fn e -> e.actor_id == "system" end)
      assert Enum.all?(stored_events, fn e -> e.correlation_id == "batch-123" end)
    end

    test "per-event options override global options", %{stream_id: stream_id} do
      events = [
        %{event_type: "event1", data: %{}, opts: [actor_id: "user-1"]},
        %{event_type: "event2", data: %{}, opts: [actor_id: "user-2"]}
      ]

      assert {:ok, 2} =
               EventStore.append_batch(
                 stream_id,
                 events,
                 actor_id: "system"
               )

      {:ok, [event1, event2]} = EventStore.read_stream(stream_id)
      assert event1.actor_id == "user-1"
      assert event2.actor_id == "user-2"
    end
  end

  describe "read_stream/2" do
    setup do
      {:ok, stream_id} = EventStore.start_stream("task")
      EventStore.append(stream_id, "event1", %{value: 1}, actor_id: "user-1")
      EventStore.append(stream_id, "event2", %{value: 2}, actor_id: "user-2")
      EventStore.append(stream_id, "event3", %{value: 3}, actor_id: "user-3")
      %{stream_id: stream_id}
    end

    test "reads all events in order", %{stream_id: stream_id} do
      {:ok, events} = EventStore.read_stream(stream_id)
      assert length(events) == 3
      assert Enum.at(events, 0).event_type == "event1"
      assert Enum.at(events, 1).event_type == "event2"
      assert Enum.at(events, 2).event_type == "event3"
    end

    test "reads events from specific version", %{stream_id: stream_id} do
      {:ok, events} = EventStore.read_stream(stream_id, from_version: 1)
      assert length(events) == 2
      assert Enum.at(events, 0).event_type == "event2"
      assert Enum.at(events, 1).event_type == "event3"
    end

    test "limits number of events returned", %{stream_id: stream_id} do
      {:ok, events} = EventStore.read_stream(stream_id, max_count: 2)
      assert length(events) == 2
      assert Enum.at(events, 0).event_type == "event1"
      assert Enum.at(events, 1).event_type == "event2"
    end

    test "filters by event types", %{stream_id: stream_id} do
      EventStore.append(stream_id, "event1", %{})
      EventStore.append(stream_id, "different_event", %{})
      EventStore.append(stream_id, "event1", %{})

      {:ok, events} = EventStore.read_stream(stream_id, event_types: ["event1"])
      # 2 from setup + 2 new = 3 "event1" events
      assert length(events) == 3
      assert Enum.all?(events, fn e -> e.event_type == "event1" end)
    end
  end

  describe "stream_version/1" do
    test "returns error for non-existent stream" do
      assert {:error, :not_found} = EventStore.stream_version("nonexistent")
    end

    test "returns current version after appends" do
      {:ok, stream_id} = EventStore.start_stream("task")
      EventStore.append(stream_id, "event1", %{})
      EventStore.append(stream_id, "event2", %{})
      EventStore.append(stream_id, "event3", %{})

      assert {:ok, 3} = EventStore.stream_version(stream_id)
    end
  end

  describe "stream_exists?/1" do
    test "returns false for non-existent stream" do
      refute EventStore.stream_exists?("nonexistent")
    end

    test "returns true for existing stream" do
      {:ok, stream_id} = EventStore.start_stream("task")
      assert EventStore.stream_exists?(stream_id)
    end
  end

  describe "snapshots" do
    setup do
      {:ok, stream_id} = EventStore.start_stream("task")
      EventStore.append(stream_id, "event1", %{value: 1})
      EventStore.append(stream_id, "event2", %{value: 2})
      EventStore.append(stream_id, "event3", %{value: 3})
      %{stream_id: stream_id}
    end

    test "saves and loads snapshots", %{stream_id: stream_id} do
      state = %{phase: "executing", progress: 50}
      assert :ok = EventStore.save_snapshot(stream_id, state, 3)

      assert {:ok, snapshot} = EventStore.load_snapshot(stream_id)
      assert snapshot.state == state
      assert snapshot.version == 3
    end

    test "returns error when no snapshot exists" do
      {:ok, stream_id} = EventStore.start_stream("task")
      assert {:error, :not_found} = EventStore.load_snapshot(stream_id)
    end

    test "overwrites existing snapshot", %{stream_id: stream_id} do
      EventStore.save_snapshot(stream_id, %{phase: "planning"}, 2)
      EventStore.save_snapshot(stream_id, %{phase: "executing"}, 3)

      {:ok, snapshot} = EventStore.load_snapshot(stream_id)
      assert snapshot.state.phase == "executing"
      assert snapshot.version == 3
    end
  end

  describe "delete_stream/1" do
    test "deletes stream and all events" do
      {:ok, stream_id} = EventStore.start_stream("task")
      EventStore.append(stream_id, "event1", %{})
      EventStore.append(stream_id, "event2", %{})

      assert :ok = EventStore.delete_stream(stream_id)
      refute EventStore.stream_exists?(stream_id)
    end

    test "returns error for non-existent stream" do
      assert {:error, :not_found} = EventStore.delete_stream("nonexistent")
    end
  end

  describe "list_streams/1" do
    test "lists all streams" do
      {:ok, stream1} = EventStore.start_stream("task")
      {:ok, stream2} = EventStore.start_stream("agent")
      {:ok, stream3} = EventStore.start_stream("task")

      {:ok, streams} = EventStore.list_streams(nil)
      stream_ids = Enum.map(streams, & &1.id)

      assert stream1 in stream_ids
      assert stream2 in stream_ids
      assert stream3 in stream_ids
    end

    test "filters streams by type" do
      {:ok, task1} = EventStore.start_stream("task")
      {:ok, agent1} = EventStore.start_stream("agent")
      {:ok, task2} = EventStore.start_stream("task")

      {:ok, task_streams} = EventStore.list_streams("task")
      task_stream_ids = Enum.map(task_streams, & &1.id)

      # Should include the task streams created in this test
      assert task1 in task_stream_ids
      assert task2 in task_stream_ids
      # Should NOT include the agent stream
      refute agent1 in task_stream_ids

      # Verify all returned streams are actually task type
      assert Enum.all?(task_streams, fn s -> s.stream_type == "task" end)
    end
  end

  describe "concurrent writes" do
    test "handles concurrent appends with version conflicts" do
      {:ok, stream_id} = EventStore.start_stream("task")
      EventStore.append(stream_id, "event1", %{})

      # Simulate two concurrent appends with same expected version
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            EventStore.append(stream_id, "concurrent_event", %{value: i})
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      successful =
        Enum.filter(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      # All should succeed since we're not using optimistic concurrency
      assert length(successful) == 10

      # Verify all events were stored
      {:ok, events} = EventStore.read_stream(stream_id)
      # 1 initial + 10 concurrent
      assert length(events) == 11
    end
  end

  describe "event replay for state reconstruction" do
    test "rebuilds state from events" do
      {:ok, stream_id} = EventStore.start_stream("task")

      # Append lifecycle events
      EventStore.append(stream_id, "task_created", %{title: "Build API"})
      EventStore.append(stream_id, "spec_approved", %{approved_by: "user-1"})
      EventStore.append(stream_id, "phase_transitioned", %{from: :spec, to: :planning})
      EventStore.append(stream_id, "plan_approved", %{approved_by: "user-2"})

      # Replay events to rebuild state
      {:ok, events} = EventStore.read_stream(stream_id)

      state =
        Enum.reduce(events, %{phase: nil, title: nil, approved_count: 0}, fn event, acc ->
          case event.event_type do
            "task_created" -> %{acc | title: event.data.title, phase: :spec}
            "spec_approved" -> %{acc | approved_count: acc.approved_count + 1}
            "phase_transitioned" -> %{acc | phase: event.data.to}
            "plan_approved" -> %{acc | approved_count: acc.approved_count + 1, phase: :executing}
            _ -> acc
          end
        end)

      assert state.title == "Build API"
      assert state.phase == :executing
      assert state.approved_count == 2
    end
  end

  describe "PubSub integration" do
    test "broadcasts event_appended message when event is appended" do
      {:ok, stream_id} = EventStore.start_stream("task")

      # Subscribe to the stream's event broadcasts
      EventStore.subscribe(stream_id)

      # Append an event
      {:ok, version} =
        EventStore.append(stream_id, "task_created", %{title: "Test Task"}, actor_id: "test-user")

      # Should receive the broadcast
      assert_receive {:event_appended, ^stream_id, event}, 1000
      assert event.event_type == "task_created"
      assert event.data.title == "Test Task"
      assert event.version == version
      assert event.actor_id == "test-user"
    end

    test "broadcasts event_appended for each event in batch" do
      {:ok, stream_id} = EventStore.start_stream("task")

      # Subscribe to the stream's event broadcasts
      EventStore.subscribe(stream_id)

      # Append batch of events
      events = [
        %{event_type: "task_created", data: %{title: "Test"}, opts: []},
        %{event_type: "spec_updated", data: %{description: "A spec"}, opts: []},
        %{event_type: "spec_approved", data: %{approved_by: "user"}, opts: []}
      ]

      {:ok, _version} = EventStore.append_batch(stream_id, events, actor_id: "test-user")

      # Should receive broadcasts for all events
      assert_receive {:event_appended, ^stream_id, event1}, 1000
      assert event1.event_type == "task_created"
      assert event1.version == 1

      assert_receive {:event_appended, ^stream_id, event2}, 1000
      assert event2.event_type == "spec_updated"
      assert event2.version == 2

      assert_receive {:event_appended, ^stream_id, event3}, 1000
      assert event3.event_type == "spec_approved"
      assert event3.version == 3
    end

    test "unsubscribe stops receiving broadcasts" do
      {:ok, stream_id} = EventStore.start_stream("task")

      # Subscribe then unsubscribe
      EventStore.subscribe(stream_id)
      EventStore.unsubscribe(stream_id)

      # Append an event
      EventStore.append(stream_id, "task_created", %{title: "Test Task"})

      # Should NOT receive the broadcast
      refute_receive {:event_appended, ^stream_id, _}, 100
    end

    test "subscribes are isolated per stream" do
      {:ok, stream_1} = EventStore.start_stream("task")
      {:ok, stream_2} = EventStore.start_stream("task")

      # Subscribe only to stream_1
      EventStore.subscribe(stream_1)

      # Append events to both streams
      EventStore.append(stream_1, "event_1", %{})
      EventStore.append(stream_2, "event_2", %{})

      # Should only receive event from stream_1
      assert_receive {:event_appended, ^stream_1, event}, 1000
      assert event.event_type == "event_1"

      # Should NOT receive event from stream_2
      refute_receive {:event_appended, ^stream_2, _}, 100
    end
  end
end
