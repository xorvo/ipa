defmodule Ipa.Pod.Events.ReviewThreadResolved do
  @moduledoc "Event emitted when a review thread is marked as resolved."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :thread_id, :resolved_by]
  defstruct [:task_id, :thread_id, :resolved_by, :resolution_comment]

  @type t :: %__MODULE__{
          task_id: String.t(),
          thread_id: String.t(),
          resolved_by: String.t(),
          resolution_comment: String.t() | nil
        }

  @impl true
  def event_type, do: "review_thread_resolved"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      thread_id: event.thread_id,
      resolved_by: event.resolved_by,
      resolution_comment: event.resolution_comment
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      thread_id: get_field(data, :thread_id),
      resolved_by: get_field(data, :resolved_by),
      resolution_comment: get_field(data, :resolution_comment)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.ReviewThreadReopened do
  @moduledoc "Event emitted when a resolved review thread is reopened."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :thread_id, :reopened_by]
  defstruct [:task_id, :thread_id, :reopened_by]

  @type t :: %__MODULE__{
          task_id: String.t(),
          thread_id: String.t(),
          reopened_by: String.t()
        }

  @impl true
  def event_type, do: "review_thread_reopened"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      thread_id: event.thread_id,
      reopened_by: event.reopened_by
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      thread_id: get_field(data, :thread_id),
      reopened_by: get_field(data, :reopened_by)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end
