defmodule Ipa.Pod.EventTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.Event
  alias Ipa.Pod.Events.{
    TaskCreated,
    SpecApproved,
    WorkstreamCreated,
    MessagePosted
  }

  describe "encode/1" do
    test "encodes TaskCreated event" do
      event = %TaskCreated{
        task_id: "task-123",
        title: "Test Task",
        description: "A test",
        requirements: ["req1"],
        acceptance_criteria: ["ac1"]
      }

      encoded = Event.encode(event)

      assert encoded.event_type == "task_created"
      assert encoded.data.task_id == "task-123"
      assert encoded.data.title == "Test Task"
    end

    test "encodes WorkstreamCreated event" do
      event = %WorkstreamCreated{
        task_id: "task-123",
        workstream_id: "ws-1",
        title: "Setup",
        dependencies: ["ws-0"]
      }

      encoded = Event.encode(event)

      assert encoded.event_type == "workstream_created"
      assert encoded.data.workstream_id == "ws-1"
      assert encoded.data.dependencies == ["ws-0"]
    end
  end

  describe "decode/1" do
    test "decodes TaskCreated from stored format" do
      stored = %{
        event_type: "task_created",
        data: %{
          task_id: "task-123",
          title: "Test Task",
          description: "desc"
        }
      }

      decoded = Event.decode(stored)

      assert %TaskCreated{} = decoded
      assert decoded.task_id == "task-123"
      assert decoded.title == "Test Task"
    end

    test "decodes TaskCreated with string keys" do
      stored = %{
        event_type: "task_created",
        data: %{
          "task_id" => "task-123",
          "title" => "Test Task"
        }
      }

      decoded = Event.decode(stored)

      assert %TaskCreated{} = decoded
      assert decoded.task_id == "task-123"
    end

    test "decodes SpecApproved" do
      stored = %{
        event_type: "spec_approved",
        data: %{task_id: "task-123", approved_by: "user-1"}
      }

      decoded = Event.decode(stored)

      assert %SpecApproved{} = decoded
      assert decoded.approved_by == "user-1"
    end

    test "decodes MessagePosted" do
      stored = %{
        event_type: "message_posted",
        data: %{
          task_id: "task-123",
          message_id: "msg-1",
          author: "user-1",
          content: "Hello",
          message_type: "question"
        }
      }

      decoded = Event.decode(stored)

      assert %MessagePosted{} = decoded
      assert decoded.message_type == :question
    end
  end

  describe "roundtrip" do
    test "encode then decode preserves data" do
      original = %TaskCreated{
        task_id: "task-123",
        title: "Test",
        description: "Desc",
        requirements: ["r1", "r2"],
        acceptance_criteria: ["a1"]
      }

      roundtripped = original |> Event.encode() |> Event.decode()

      assert roundtripped.task_id == original.task_id
      assert roundtripped.title == original.title
      assert roundtripped.description == original.description
      assert roundtripped.requirements == original.requirements
    end
  end
end
