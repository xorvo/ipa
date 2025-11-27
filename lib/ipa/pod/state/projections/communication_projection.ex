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
      posted_at: System.system_time(:second)
    }

    messages = Map.put(state.messages, event.message_id, message)
    %{state | messages: messages}
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
end
