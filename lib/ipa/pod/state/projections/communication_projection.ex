defmodule Ipa.Pod.State.Projections.CommunicationProjection do
  @moduledoc "Projects communication events onto state."

  alias Ipa.Pod.State
  alias Ipa.Pod.State.{Message, Notification}

  alias Ipa.Pod.Events.{
    MessagePosted,
    ApprovalRequested,
    ApprovalGiven,
    NotificationCreated,
    NotificationRead
  }

  @doc "Applies a communication event to state."
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, %MessagePosted{} = event) do
    message = %Message{
      message_id: event.message_id,
      author: event.author,
      content: event.content,
      message_type: event.message_type,
      thread_id: event.thread_id,
      workstream_id: event.workstream_id,
      posted_at: System.system_time(:second),
      metadata: event.metadata
    }

    messages = Map.put(state.messages, event.message_id, message)
    state = %{state | messages: messages}

    # If this is a review comment, update the review_threads index
    if event.message_type == :review_comment and event.metadata do
      update_review_threads(state, event)
    else
      state
    end
  end

  def apply(state, %ApprovalRequested{} = event) do
    message = %Message{
      message_id: event.message_id,
      author: event.author,
      content: event.question,
      message_type: :approval,
      workstream_id: event.workstream_id,
      approval_options: event.options,
      blocking?: event.blocking?,
      posted_at: System.system_time(:second),
      approved?: false
    }

    messages = Map.put(state.messages, event.message_id, message)
    %{state | messages: messages}
  end

  def apply(state, %ApprovalGiven{} = event) do
    state
    |> update_message(event.message_id, fn msg ->
      %{
        msg
        | approved?: true,
          approved_by: event.approved_by,
          approval_choice: event.choice
      }
    end)
    |> clear_approval_notification(event.message_id)
  end

  def apply(state, %NotificationCreated{} = event) do
    notification = %Notification{
      notification_id: event.notification_id,
      recipient: event.recipient,
      notification_type: event.notification_type,
      message_id: event.message_id,
      preview: event.preview,
      created_at: System.system_time(:second),
      read?: false
    }

    %{state | notifications: [notification | state.notifications]}
  end

  def apply(state, %NotificationRead{} = event) do
    notifications =
      Enum.map(state.notifications, fn n ->
        if n.notification_id == event.notification_id do
          %{n | read?: true}
        else
          n
        end
      end)

    %{state | notifications: notifications}
  end

  def apply(state, _event), do: state

  # Helpers

  defp update_message(state, message_id, update_fn) do
    case Map.get(state.messages, message_id) do
      nil ->
        state

      msg ->
        updated_msg = update_fn.(msg)
        %{state | messages: Map.put(state.messages, message_id, updated_msg)}
    end
  end

  defp clear_approval_notification(state, message_id) do
    notifications =
      Enum.reject(state.notifications, fn n ->
        n.message_id == message_id and n.notification_type == :needs_approval
      end)

    %{state | notifications: notifications}
  end

  defp update_review_threads(state, event) do
    document_type = get_in(event.metadata, [:document_type]) || event.metadata["document_type"]

    if document_type do
      # Determine the thread_id - either use existing thread_id (for replies) or message_id (for new threads)
      thread_id = event.thread_id || event.message_id

      # Get current threads for this document type
      doc_threads = Map.get(state.review_threads, document_type, %{})

      # Add this message to the thread
      thread_messages = Map.get(doc_threads, thread_id, [])
      updated_thread_messages = thread_messages ++ [event.message_id]

      # Update the nested structure
      updated_doc_threads = Map.put(doc_threads, thread_id, updated_thread_messages)
      updated_review_threads = Map.put(state.review_threads, document_type, updated_doc_threads)

      %{state | review_threads: updated_review_threads}
    else
      state
    end
  end
end
