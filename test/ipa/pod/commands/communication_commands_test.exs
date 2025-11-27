defmodule Ipa.Pod.Commands.CommunicationCommandsTest do
  use ExUnit.Case, async: true

  alias Ipa.Pod.State
  alias Ipa.Pod.Commands.CommunicationCommands

  alias Ipa.Pod.Events.{
    MessagePosted,
    ApprovalRequested,
    ApprovalGiven,
    NotificationCreated,
    NotificationRead
  }

  describe "post_message/2" do
    test "creates MessagePosted event" do
      state = %State{
        task_id: "task-123",
        messages: %{}
      }

      params = %{
        author: "user-1",
        content: "Hello world",
        message_type: :update
      }

      assert {:ok, [event]} = CommunicationCommands.post_message(state, params)
      assert %MessagePosted{} = event
      assert event.author == "user-1"
      assert event.content == "Hello world"
      assert event.message_type == :update
      assert is_binary(event.message_id)
    end

    test "uses provided message_id" do
      state = %State{task_id: "task-123", messages: %{}}

      params = %{
        message_id: "msg-custom",
        author: "user-1",
        content: "Test",
        message_type: :question
      }

      assert {:ok, [event]} = CommunicationCommands.post_message(state, params)
      assert event.message_id == "msg-custom"
    end

    test "creates reply with thread_id" do
      state = %State{
        task_id: "task-123",
        messages: %{
          "msg-parent" => %State.Message{
            message_id: "msg-parent",
            author: "user-1",
            content: "Original"
          }
        }
      }

      params = %{
        author: "user-2",
        content: "Reply",
        message_type: :update,
        thread_id: "msg-parent"
      }

      assert {:ok, [event]} = CommunicationCommands.post_message(state, params)
      assert event.thread_id == "msg-parent"
    end

    test "fails without valid message_type" do
      state = %State{task_id: "task-123", messages: %{}}

      assert {:error, :invalid_type} =
               CommunicationCommands.post_message(state, %{author: "user-1", content: "Test"})
    end

    test "fails without author" do
      state = %State{task_id: "task-123", messages: %{}}

      assert {:error, :invalid_author} =
               CommunicationCommands.post_message(state, %{content: "Test", message_type: :update})
    end

    test "fails without content" do
      state = %State{task_id: "task-123", messages: %{}}

      assert {:error, :empty_content} =
               CommunicationCommands.post_message(state, %{author: "user-1", message_type: :update})
    end

    test "fails if thread_id doesn't exist" do
      state = %State{task_id: "task-123", messages: %{}}

      params = %{
        author: "user-1",
        content: "Reply",
        message_type: :update,
        thread_id: "nonexistent"
      }

      assert {:error, :thread_not_found} = CommunicationCommands.post_message(state, params)
    end
  end

  describe "request_approval/2" do
    test "creates ApprovalRequested event" do
      state = %State{task_id: "task-123", messages: %{}}

      params = %{
        author: "agent-1",
        question: "Should we proceed?",
        options: ["Yes", "No"],
        blocking?: false
      }

      assert {:ok, [event]} = CommunicationCommands.request_approval(state, params)
      assert %ApprovalRequested{} = event
      assert event.question == "Should we proceed?"
      assert event.options == ["Yes", "No"]
      assert event.blocking? == false
    end

    test "defaults blocking? to true" do
      state = %State{task_id: "task-123", messages: %{}}

      params = %{
        author: "agent-1",
        question: "Question?",
        options: ["A", "B"]
      }

      assert {:ok, [event]} = CommunicationCommands.request_approval(state, params)
      assert event.blocking? == true
    end

    test "fails without question" do
      state = %State{task_id: "task-123", messages: %{}}

      assert {:error, :empty_question} =
               CommunicationCommands.request_approval(state, %{author: "agent-1", options: ["A"]})
    end

    test "fails without options" do
      state = %State{task_id: "task-123", messages: %{}}

      assert {:error, :invalid_options} =
               CommunicationCommands.request_approval(state, %{author: "agent-1", question: "Q?"})
    end
  end

  describe "give_approval/4" do
    test "creates ApprovalGiven event" do
      state = %State{
        task_id: "task-123",
        messages: %{
          "msg-1" => %State.Message{
            message_id: "msg-1",
            message_type: :approval,
            approved?: false,
            approval_options: ["Yes", "No"]
          }
        }
      }

      assert {:ok, [event]} =
               CommunicationCommands.give_approval(state, "msg-1", "user-1", "Yes")

      assert %ApprovalGiven{} = event
      assert event.message_id == "msg-1"
      assert event.approved_by == "user-1"
      assert event.choice == "Yes"
    end

    test "fails if message not found" do
      state = %State{task_id: "task-123", messages: %{}}

      assert {:error, :message_not_found} =
               CommunicationCommands.give_approval(state, "nonexistent", "user-1", "Yes")
    end

    test "fails if not an approval message" do
      state = %State{
        task_id: "task-123",
        messages: %{
          "msg-1" => %State.Message{
            message_id: "msg-1",
            message_type: :question
          }
        }
      }

      assert {:error, :not_approval_request} =
               CommunicationCommands.give_approval(state, "msg-1", "user-1", "Yes")
    end

    test "fails if already approved" do
      state = %State{
        task_id: "task-123",
        messages: %{
          "msg-1" => %State.Message{
            message_id: "msg-1",
            message_type: :approval,
            approved?: true,
            approval_options: ["Yes", "No"]
          }
        }
      }

      assert {:error, :already_approved} =
               CommunicationCommands.give_approval(state, "msg-1", "user-1", "Yes")
    end

    test "fails if choice not in options" do
      state = %State{
        task_id: "task-123",
        messages: %{
          "msg-1" => %State.Message{
            message_id: "msg-1",
            message_type: :approval,
            approved?: false,
            approval_options: ["Yes", "No"]
          }
        }
      }

      assert {:error, :invalid_choice} =
               CommunicationCommands.give_approval(state, "msg-1", "user-1", "Maybe")
    end
  end

  describe "create_notification/2" do
    test "creates NotificationCreated event" do
      state = %State{task_id: "task-123", notifications: []}

      params = %{
        recipient: "user-1",
        type: :needs_approval,
        message_id: "msg-1",
        preview: "You have an approval request"
      }

      assert {:ok, [event]} = CommunicationCommands.create_notification(state, params)
      assert %NotificationCreated{} = event
      assert event.recipient == "user-1"
      assert event.notification_type == :needs_approval
      assert is_binary(event.notification_id)
    end

    test "fails without recipient" do
      state = %State{task_id: "task-123", notifications: []}

      assert {:error, :invalid_author} =
               CommunicationCommands.create_notification(state, %{type: :needs_approval})
    end

    test "fails without valid type" do
      state = %State{task_id: "task-123", notifications: []}

      assert {:error, :invalid_notification_type} =
               CommunicationCommands.create_notification(state, %{recipient: "user-1"})
    end
  end

  describe "mark_notification_read/2" do
    test "creates NotificationRead event" do
      state = %State{
        task_id: "task-123",
        notifications: [
          %State.Notification{notification_id: "notif-1", read?: false}
        ]
      }

      assert {:ok, [event]} = CommunicationCommands.mark_notification_read(state, "notif-1")
      assert %NotificationRead{} = event
      assert event.notification_id == "notif-1"
    end

    test "fails if notification not found" do
      state = %State{task_id: "task-123", notifications: []}

      assert {:error, :notification_not_found} =
               CommunicationCommands.mark_notification_read(state, "nonexistent")
    end

    # Note: The implementation doesn't check if already read -
    # this is by design as the projector handles idempotency
    test "allows marking already read notification" do
      state = %State{
        task_id: "task-123",
        notifications: [
          %State.Notification{notification_id: "notif-1", read?: true}
        ]
      }

      assert {:ok, [event]} = CommunicationCommands.mark_notification_read(state, "notif-1")
      assert %NotificationRead{} = event
    end
  end
end
