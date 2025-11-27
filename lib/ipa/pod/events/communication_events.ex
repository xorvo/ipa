defmodule Ipa.Pod.Events.MessagePosted do
  @moduledoc "Event emitted when a message is posted."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :message_id, :author, :content, :message_type]
  defstruct [
    :task_id,
    :message_id,
    :author,
    :content,
    :message_type,
    :thread_id,
    :workstream_id
  ]

  @type message_type :: :question | :update | :blocker

  @type t :: %__MODULE__{
          task_id: String.t(),
          message_id: String.t(),
          author: String.t(),
          content: String.t(),
          message_type: message_type(),
          thread_id: String.t() | nil,
          workstream_id: String.t() | nil
        }

  @impl true
  def event_type, do: "message_posted"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      message_id: event.message_id,
      author: event.author,
      content: event.content,
      message_type: event.message_type,
      thread_id: event.thread_id,
      workstream_id: event.workstream_id
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      message_id: get_field(data, :message_id),
      author: get_field(data, :author),
      content: get_field(data, :content),
      message_type: normalize_message_type(get_field(data, :message_type) || get_field(data, :type)),
      thread_id: get_field(data, :thread_id),
      workstream_id: get_field(data, :workstream_id)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_message_type(:question), do: :question
  defp normalize_message_type(:update), do: :update
  defp normalize_message_type(:blocker), do: :blocker
  defp normalize_message_type("question"), do: :question
  defp normalize_message_type("update"), do: :update
  defp normalize_message_type("blocker"), do: :blocker
  defp normalize_message_type(_), do: :update
end

defmodule Ipa.Pod.Events.ApprovalRequested do
  @moduledoc "Event emitted when approval is requested."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :message_id, :author, :question, :options]
  defstruct [
    :task_id,
    :message_id,
    :author,
    :question,
    :options,
    :workstream_id,
    blocking?: true
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          message_id: String.t(),
          author: String.t(),
          question: String.t(),
          options: [String.t()],
          workstream_id: String.t() | nil,
          blocking?: boolean()
        }

  @impl true
  def event_type, do: "approval_requested"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      message_id: event.message_id,
      author: event.author,
      question: event.question,
      options: event.options,
      workstream_id: event.workstream_id,
      blocking?: event.blocking?
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      message_id: get_field(data, :message_id),
      author: get_field(data, :author),
      question: get_field(data, :question),
      options: get_field(data, :options) || [],
      workstream_id: get_field(data, :workstream_id),
      blocking?: get_field(data, :blocking?) != false
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.ApprovalGiven do
  @moduledoc "Event emitted when approval is given."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :message_id, :approved_by, :choice]
  defstruct [:task_id, :message_id, :approved_by, :choice, :comment]

  @type t :: %__MODULE__{
          task_id: String.t(),
          message_id: String.t(),
          approved_by: String.t(),
          choice: String.t(),
          comment: String.t() | nil
        }

  @impl true
  def event_type, do: "approval_given"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      message_id: event.message_id,
      approved_by: event.approved_by,
      choice: event.choice,
      comment: event.comment
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      message_id: get_field(data, :message_id),
      approved_by: get_field(data, :approved_by),
      choice: get_field(data, :choice),
      comment: get_field(data, :comment)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.NotificationCreated do
  @moduledoc "Event emitted when a notification is created."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :notification_id, :recipient, :notification_type]
  defstruct [
    :task_id,
    :notification_id,
    :recipient,
    :notification_type,
    :message_id,
    :preview
  ]

  @type notification_type :: :needs_approval | :question_asked | :blocker_raised | :workstream_completed

  @type t :: %__MODULE__{
          task_id: String.t(),
          notification_id: String.t(),
          recipient: String.t(),
          notification_type: notification_type(),
          message_id: String.t() | nil,
          preview: String.t() | nil
        }

  @impl true
  def event_type, do: "notification_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      notification_id: event.notification_id,
      recipient: event.recipient,
      notification_type: event.notification_type,
      message_id: event.message_id,
      preview: event.preview
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      notification_id: get_field(data, :notification_id),
      recipient: get_field(data, :recipient),
      notification_type: normalize_notification_type(get_field(data, :notification_type) || get_field(data, :type)),
      message_id: get_field(data, :message_id),
      preview: get_field(data, :preview) || get_field(data, :message_preview)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_notification_type(:needs_approval), do: :needs_approval
  defp normalize_notification_type(:question_asked), do: :question_asked
  defp normalize_notification_type(:blocker_raised), do: :blocker_raised
  defp normalize_notification_type(:workstream_completed), do: :workstream_completed
  defp normalize_notification_type("needs_approval"), do: :needs_approval
  defp normalize_notification_type("question_asked"), do: :question_asked
  defp normalize_notification_type("blocker_raised"), do: :blocker_raised
  defp normalize_notification_type("workstream_completed"), do: :workstream_completed
  defp normalize_notification_type(_), do: :needs_approval
end

defmodule Ipa.Pod.Events.NotificationRead do
  @moduledoc "Event emitted when a notification is marked as read."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :notification_id]
  defstruct [:task_id, :notification_id]

  @type t :: %__MODULE__{
          task_id: String.t(),
          notification_id: String.t()
        }

  @impl true
  def event_type, do: "notification_read"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      notification_id: event.notification_id
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      notification_id: get_field(data, :notification_id)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end
