defmodule Ipa.Pod.CommunicationsManagerTest do
  use Ipa.DataCase, async: false

  alias Ipa.Pod.CommunicationsManager
  alias Ipa.Pod.State
  alias Ipa.EventStore

  setup do
    # Generate unique task ID for each test
    task_id = "task-#{System.unique_integer([:positive, :monotonic])}"

    # Create event stream (stream_type, stream_id)
    {:ok, ^task_id} = EventStore.start_stream("task", task_id)

    # Append initial task_created event
    {:ok, _version} =
      EventStore.append(task_id, "task_created", %{title: "Test Task"}, actor_id: "system")

    # Start State Manager (it will replay the task_created event)
    {:ok, state_pid} = State.start_link(task_id: task_id)

    # Give State Manager time to fully initialize
    Process.sleep(10)

    # Start CommunicationsManager (will register via Registry automatically)
    {:ok, comm_pid} = CommunicationsManager.start_link(task_id)

    # Give CommunicationsManager time to fully initialize
    Process.sleep(10)

    on_exit(fn ->
      # Stop processes
      if Process.alive?(comm_pid), do: GenServer.stop(comm_pid)
      if Process.alive?(state_pid), do: GenServer.stop(state_pid)

      # Clean up event stream
      EventStore.delete_stream(task_id)
    end)

    {:ok, task_id: task_id}
  end

  # ============================================================================
  # Message Posting Tests
  # ============================================================================

  describe "post_message/2" do
    test "creates message event with valid data", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Test question?",
          author: "agent-1"
        )

      # Verify event was appended
      {:ok, state} = State.get_state(task_id)
      message = Enum.find(state.messages, fn msg -> msg.message_id == msg_id end)

      assert message != nil
      assert message.type == :question
      assert message.content == "Test question?"
      assert message.author == "agent-1"
      assert message.thread_id == nil
      assert message.workstream_id == nil
      assert message.approved? == false
    end

    test "creates notification for questions", %{task_id: task_id} do
      {:ok, _msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Need help",
          author: "agent-1"
        )

      # Verify notification was created
      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      assert length(inbox) > 0
      assert Enum.any?(inbox, fn n -> n.type == :question_asked end)
    end

    test "creates notification for blockers", %{task_id: task_id} do
      {:ok, _msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :blocker,
          content: "Critical issue",
          author: "agent-1"
        )

      # Verify notification was created
      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      assert Enum.any?(inbox, fn n -> n.type == :blocker_raised end)
    end

    test "does not create notification for updates", %{task_id: task_id} do
      {:ok, _msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "Progress update",
          author: "agent-1"
        )

      # Verify no notification was created
      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      assert length(inbox) == 0
    end

    test "returns error for invalid type", %{task_id: task_id} do
      assert {:error, :invalid_type} =
               CommunicationsManager.post_message(
                 task_id,
                 type: :invalid,
                 content: "Test",
                 author: "agent-1"
               )
    end

    test "returns error for empty content", %{task_id: task_id} do
      assert {:error, :empty_content} =
               CommunicationsManager.post_message(
                 task_id,
                 type: :question,
                 content: "",
                 author: "agent-1"
               )
    end

    test "returns error for invalid author", %{task_id: task_id} do
      assert {:error, :invalid_author} =
               CommunicationsManager.post_message(
                 task_id,
                 type: :question,
                 content: "Test",
                 author: ""
               )
    end

    test "supports optional workstream_id", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "Progress",
          author: "agent-1",
          workstream_id: "ws-1"
        )

      {:ok, state} = State.get_state(task_id)
      message = Enum.find(state.messages, fn msg -> msg.message_id == msg_id end)
      assert message.workstream_id == "ws-1"
    end
  end

  # ============================================================================
  # Threading Tests
  # ============================================================================

  describe "threading" do
    test "reply message references parent thread", %{task_id: task_id} do
      {:ok, root_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Root message",
          author: "agent-1"
        )

      {:ok, reply_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "Reply message",
          author: "agent-2",
          thread_id: root_id
        )

      {:ok, thread} = CommunicationsManager.get_thread(task_id, root_id)
      assert length(thread) == 2

      reply = Enum.find(thread, fn msg -> msg.message_id == reply_id end)
      assert reply.thread_id == root_id
    end

    test "get_thread returns all messages in thread", %{task_id: task_id} do
      {:ok, root_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Root",
          author: "agent-1"
        )

      {:ok, _reply1} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "Reply 1",
          author: "agent-2",
          thread_id: root_id
        )

      {:ok, _reply2} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "Reply 2",
          author: "agent-3",
          thread_id: root_id
        )

      {:ok, thread} = CommunicationsManager.get_thread(task_id, root_id)
      assert length(thread) == 3
    end

    test "returns error for invalid thread_id", %{task_id: task_id} do
      assert {:error, :thread_not_found} =
               CommunicationsManager.post_message(
                 task_id,
                 type: :update,
                 content: "Reply",
                 author: "agent-1",
                 thread_id: "nonexistent"
               )
    end

    test "get_thread returns error for nonexistent thread", %{task_id: task_id} do
      assert {:error, :thread_not_found} =
               CommunicationsManager.get_thread(task_id, "nonexistent")
    end
  end

  # ============================================================================
  # Approval Workflow Tests
  # ============================================================================

  describe "approval workflow" do
    test "request_approval creates approval message", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.request_approval(
          task_id,
          question: "Deploy to prod?",
          options: ["Yes", "No"],
          author: "agent-1"
        )

      {:ok, state} = State.get_state(task_id)
      message = Enum.find(state.messages, fn msg -> msg.message_id == msg_id end)

      assert message != nil
      assert message.type == :approval
      assert message.content == "Deploy to prod?"
      assert message.approval_options == ["Yes", "No"]
      assert message.approved? == false
    end

    test "request_approval creates high-priority notification", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.request_approval(
          task_id,
          question: "Deploy?",
          options: ["Yes", "No"],
          author: "agent-1"
        )

      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      notification = Enum.find(inbox, fn n -> n.message_id == msg_id end)

      assert notification != nil
      assert notification.type == :needs_approval
      assert notification.read? == false
    end

    test "give_approval updates message and clears notification", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.request_approval(
          task_id,
          question: "Merge PR?",
          options: ["Yes", "No"],
          author: "agent-1"
        )

      {:ok, _approval_id} =
        CommunicationsManager.give_approval(
          task_id,
          msg_id,
          approved_by: "user-1",
          choice: "Yes"
        )

      # Verify approval recorded
      {:ok, state} = State.get_state(task_id)
      message = Enum.find(state.messages, fn m -> m.message_id == msg_id end)
      assert message.approved? == true
      assert message.approval_choice == "Yes"
      assert message.approval_given_by == "user-1"
      assert message.approval_given_at != nil

      # Verify notification cleared
      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      refute Enum.any?(inbox, fn n -> n.message_id == msg_id end)
    end

    test "give_approval with invalid choice returns error", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.request_approval(
          task_id,
          question: "Deploy?",
          options: ["Yes", "No"],
          author: "agent-1"
        )

      assert {:error, :invalid_choice} =
               CommunicationsManager.give_approval(
                 task_id,
                 msg_id,
                 approved_by: "user-1",
                 choice: "Maybe"
               )
    end

    test "give_approval on non-approval message returns error", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Question?",
          author: "agent-1"
        )

      assert {:error, :not_approval_request} =
               CommunicationsManager.give_approval(
                 task_id,
                 msg_id,
                 approved_by: "user-1",
                 choice: "Yes"
               )
    end

    test "give_approval on already approved message returns error", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.request_approval(
          task_id,
          question: "Deploy?",
          options: ["Yes", "No"],
          author: "agent-1"
        )

      {:ok, _} =
        CommunicationsManager.give_approval(
          task_id,
          msg_id,
          approved_by: "user-1",
          choice: "Yes"
        )

      assert {:error, :already_approved} =
               CommunicationsManager.give_approval(
                 task_id,
                 msg_id,
                 approved_by: "user-2",
                 choice: "No"
               )
    end

    test "request_approval with empty question returns error", %{task_id: task_id} do
      assert {:error, :empty_question} =
               CommunicationsManager.request_approval(
                 task_id,
                 question: "",
                 options: ["Yes", "No"],
                 author: "agent-1"
               )
    end

    test "request_approval with invalid options returns error", %{task_id: task_id} do
      assert {:error, :invalid_options} =
               CommunicationsManager.request_approval(
                 task_id,
                 question: "Deploy?",
                 options: [],
                 author: "agent-1"
               )
    end
  end

  # ============================================================================
  # Inbox Management Tests
  # ============================================================================

  describe "inbox management" do
    test "get_inbox returns all notifications", %{task_id: task_id} do
      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Q1",
          author: "agent-1"
        )

      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :blocker,
          content: "B1",
          author: "agent-2"
        )

      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      assert length(inbox) == 2
    end

    test "get_inbox filters by unread_only", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Q1",
          author: "agent-1"
        )

      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      notification = Enum.find(inbox, fn n -> n.message_id == msg_id end)

      # Mark as read
      :ok = CommunicationsManager.mark_read(task_id, notification.notification_id)

      # Get unread only
      {:ok, unread_inbox} = CommunicationsManager.get_inbox(task_id, unread_only?: true)
      assert length(unread_inbox) == 0

      # Get all
      {:ok, all_inbox} = CommunicationsManager.get_inbox(task_id, unread_only?: false)
      assert length(all_inbox) == 1
    end

    test "mark_read updates notification status", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Q1",
          author: "agent-1"
        )

      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      notification = Enum.find(inbox, fn n -> n.message_id == msg_id end)
      assert notification.read? == false

      :ok = CommunicationsManager.mark_read(task_id, notification.notification_id)

      {:ok, updated_inbox} = CommunicationsManager.get_inbox(task_id)
      updated_notification = Enum.find(updated_inbox, fn n -> n.message_id == msg_id end)
      assert updated_notification.read? == true
    end

    test "mark_read returns error for nonexistent notification", %{task_id: task_id} do
      assert {:error, :notification_not_found} =
               CommunicationsManager.mark_read(task_id, "nonexistent")
    end
  end

  # ============================================================================
  # Message Query Tests
  # ============================================================================

  describe "get_messages/2" do
    test "returns all messages by default", %{task_id: task_id} do
      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Q1",
          author: "agent-1"
        )

      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "U1",
          author: "agent-2"
        )

      {:ok, messages} = CommunicationsManager.get_messages(task_id)
      assert length(messages) == 2
    end

    test "filters by message type", %{task_id: task_id} do
      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Q1",
          author: "agent-1"
        )

      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "U1",
          author: "agent-2"
        )

      {:ok, questions} = CommunicationsManager.get_messages(task_id, type: :question)
      assert length(questions) == 1
      assert Enum.all?(questions, fn m -> m.type == :question end)
    end

    test "filters by workstream_id", %{task_id: task_id} do
      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "WS1 update",
          author: "agent-1",
          workstream_id: "ws-1"
        )

      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "WS2 update",
          author: "agent-2",
          workstream_id: "ws-2"
        )

      {:ok, ws1_messages} =
        CommunicationsManager.get_messages(task_id, workstream_id: "ws-1")

      assert length(ws1_messages) == 1
      assert Enum.all?(ws1_messages, fn m -> m.workstream_id == "ws-1" end)
    end

    test "filters by author", %{task_id: task_id} do
      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "Agent 1 update",
          author: "agent-1"
        )

      {:ok, _} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "Agent 2 update",
          author: "agent-2"
        )

      {:ok, agent1_messages} = CommunicationsManager.get_messages(task_id, author: "agent-1")
      assert length(agent1_messages) == 1
      assert Enum.all?(agent1_messages, fn m -> m.author == "agent-1" end)
    end

    test "respects limit parameter", %{task_id: task_id} do
      for i <- 1..10 do
        {:ok, _} =
          CommunicationsManager.post_message(
            task_id,
            type: :update,
            content: "Update #{i}",
            author: "agent-1"
          )
      end

      {:ok, messages} = CommunicationsManager.get_messages(task_id, limit: 5)
      assert length(messages) == 5
    end

    test "returns messages sorted by posted_at descending", %{task_id: task_id} do
      {:ok, msg1_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "First",
          author: "agent-1"
        )

      # Delay to ensure different timestamps (need full second for Unix timestamps)
      Process.sleep(1100)

      {:ok, msg2_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "Second",
          author: "agent-1"
        )

      {:ok, messages} = CommunicationsManager.get_messages(task_id)
      assert length(messages) == 2

      # Most recent first
      assert List.first(messages).message_id == msg2_id
      assert List.last(messages).message_id == msg1_id
    end
  end

  # ============================================================================
  # Pub-Sub Tests
  # ============================================================================

  describe "pub-sub broadcasting" do
    test "broadcasts message_posted event", %{task_id: task_id} do
      CommunicationsManager.subscribe(task_id)

      {:ok, msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Test",
          author: "agent-1"
        )

      assert_receive {:message_posted, ^task_id, %{message_id: ^msg_id}}, 500
    end

    test "broadcasts approval_requested event", %{task_id: task_id} do
      CommunicationsManager.subscribe(task_id)

      {:ok, msg_id} =
        CommunicationsManager.request_approval(
          task_id,
          question: "Deploy?",
          options: ["Yes", "No"],
          author: "agent-1"
        )

      assert_receive {:approval_requested, ^task_id, %{message_id: ^msg_id}}, 500
    end

    test "broadcasts approval_given event", %{task_id: task_id} do
      CommunicationsManager.subscribe(task_id)

      {:ok, msg_id} =
        CommunicationsManager.request_approval(
          task_id,
          question: "Deploy?",
          options: ["Yes", "No"],
          author: "agent-1"
        )

      # Clear previous messages
      flush_messages()

      {:ok, _} =
        CommunicationsManager.give_approval(
          task_id,
          msg_id,
          approved_by: "user-1",
          choice: "Yes"
        )

      assert_receive {:approval_given, ^task_id, ^msg_id, _}, 500
    end
  end

  # ============================================================================
  # Integration Tests with Pod State
  # ============================================================================

  describe "integration with Pod State" do
    test "messages persist after state reload", %{task_id: task_id} do
      {:ok, msg1_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Q1",
          author: "agent-1"
        )

      {:ok, msg2_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :update,
          content: "U1",
          author: "agent-2"
        )

      # Reload state
      {:ok, _reloaded_state} = State.reload_state(task_id)

      # Verify messages still there
      {:ok, messages} = CommunicationsManager.get_messages(task_id)
      assert length(messages) == 2
      assert Enum.any?(messages, fn m -> m.message_id == msg1_id end)
      assert Enum.any?(messages, fn m -> m.message_id == msg2_id end)
    end

    test "approvals persist after state reload", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.request_approval(
          task_id,
          question: "Deploy?",
          options: ["Yes", "No"],
          author: "agent-1"
        )

      {:ok, _} =
        CommunicationsManager.give_approval(
          task_id,
          msg_id,
          approved_by: "user-1",
          choice: "Yes"
        )

      # Reload state
      {:ok, _reloaded_state} = State.reload_state(task_id)

      # Verify approval still recorded
      {:ok, state} = State.get_state(task_id)
      message = Enum.find(state.messages, fn m -> m.message_id == msg_id end)
      assert message.approved? == true
      assert message.approval_choice == "Yes"
    end

    test "notifications persist after state reload", %{task_id: task_id} do
      {:ok, msg_id} =
        CommunicationsManager.post_message(
          task_id,
          type: :question,
          content: "Q1",
          author: "agent-1"
        )

      # Reload state
      {:ok, _reloaded_state} = State.reload_state(task_id)

      # Verify notification still there
      {:ok, inbox} = CommunicationsManager.get_inbox(task_id)
      assert Enum.any?(inbox, fn n -> n.message_id == msg_id end)
    end
  end

  # Helper Functions

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
