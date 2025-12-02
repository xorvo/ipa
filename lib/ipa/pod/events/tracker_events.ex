defmodule Ipa.Pod.Events.TrackerCreated do
  @moduledoc """
  Event emitted when a tracker is created for a task.

  This event is typically emitted by the planning agent after generating
  the initial tracker structure with phases and items.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :phases]
  defstruct [
    :task_id,
    :phases
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          phases: [map()]
        }

  @impl true
  def event_type, do: "tracker_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      phases: event.phases
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      phases: get_field(data, :phases) || []
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.TrackerPhaseAdded do
  @moduledoc """
  Event emitted when a new phase is added to the tracker.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :phase_id, :name, :order]
  defstruct [
    :task_id,
    :phase_id,
    :name,
    :eta,
    :order
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          phase_id: String.t(),
          name: String.t(),
          eta: String.t() | nil,
          order: integer()
        }

  @impl true
  def event_type, do: "tracker_phase_added"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      phase_id: event.phase_id,
      name: event.name,
      eta: event.eta,
      order: event.order
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      phase_id: get_field(data, :phase_id),
      name: get_field(data, :name),
      eta: get_field(data, :eta),
      order: get_field(data, :order) || 0
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.TrackerItemAdded do
  @moduledoc """
  Event emitted when a new item is added to a tracker phase.

  This can be emitted:
  - During initial tracker creation
  - After admin approval of an add_item request
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :phase_id, :item_id, :summary]
  defstruct [
    :task_id,
    :phase_id,
    :item_id,
    :summary,
    :workstream_id
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          phase_id: String.t(),
          item_id: String.t(),
          summary: String.t(),
          workstream_id: String.t() | nil
        }

  @impl true
  def event_type, do: "tracker_item_added"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      phase_id: event.phase_id,
      item_id: event.item_id,
      summary: event.summary,
      workstream_id: event.workstream_id
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      phase_id: get_field(data, :phase_id),
      item_id: get_field(data, :item_id),
      summary: get_field(data, :summary),
      workstream_id: get_field(data, :workstream_id)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.TrackerItemUpdated do
  @moduledoc """
  Event emitted when an item's metadata is updated.

  This is for updating item properties like summary, workstream_id.
  For status changes, use TrackerItemStatusChanged.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :item_id, :changes]
  defstruct [
    :task_id,
    :item_id,
    :changes,
    :updated_by
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          item_id: String.t(),
          changes: map(),
          updated_by: String.t() | nil
        }

  @impl true
  def event_type, do: "tracker_item_updated"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      item_id: event.item_id,
      changes: event.changes,
      updated_by: event.updated_by
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      item_id: get_field(data, :item_id),
      changes: get_field(data, :changes) || %{},
      updated_by: get_field(data, :updated_by)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.TrackerItemRemoved do
  @moduledoc """
  Event emitted when an item is removed from the tracker.

  Requires admin approval to emit.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :item_id, :phase_id]
  defstruct [
    :task_id,
    :item_id,
    :phase_id,
    :removed_by,
    :reason
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          item_id: String.t(),
          phase_id: String.t(),
          removed_by: String.t() | nil,
          reason: String.t() | nil
        }

  @impl true
  def event_type, do: "tracker_item_removed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      item_id: event.item_id,
      phase_id: event.phase_id,
      removed_by: event.removed_by,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      item_id: get_field(data, :item_id),
      phase_id: get_field(data, :phase_id),
      removed_by: get_field(data, :removed_by),
      reason: get_field(data, :reason)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.TrackerItemStatusChanged do
  @moduledoc """
  Event emitted when an item's status changes.

  Workstreams can directly change the status of items they own.
  Valid statuses: :todo, :wip, :done, :blocked
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :item_id, :from_status, :to_status]
  defstruct [
    :task_id,
    :item_id,
    :from_status,
    :to_status,
    :changed_by,
    :reason
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          item_id: String.t(),
          from_status: atom(),
          to_status: atom(),
          changed_by: String.t() | nil,
          reason: String.t() | nil
        }

  @impl true
  def event_type, do: "tracker_item_status_changed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      item_id: event.item_id,
      from_status: event.from_status,
      to_status: event.to_status,
      changed_by: event.changed_by,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      item_id: get_field(data, :item_id),
      from_status: normalize_status(get_field(data, :from_status)),
      to_status: normalize_status(get_field(data, :to_status)),
      changed_by: get_field(data, :changed_by),
      reason: get_field(data, :reason)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status("todo"), do: :todo
  defp normalize_status("wip"), do: :wip
  defp normalize_status("done"), do: :done
  defp normalize_status("blocked"), do: :blocked
  defp normalize_status(_), do: :todo
end

defmodule Ipa.Pod.Events.TrackerItemCommentAdded do
  @moduledoc """
  Event emitted when a comment is added to a tracker item.

  Comments are visible to everyone working on the task.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :item_id, :comment_id, :content, :author]
  defstruct [
    :task_id,
    :item_id,
    :comment_id,
    :content,
    :author
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          item_id: String.t(),
          comment_id: String.t(),
          content: String.t(),
          author: String.t()
        }

  @impl true
  def event_type, do: "tracker_item_comment_added"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      item_id: event.item_id,
      comment_id: event.comment_id,
      content: event.content,
      author: event.author
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      item_id: get_field(data, :item_id),
      comment_id: get_field(data, :comment_id),
      content: get_field(data, :content),
      author: get_field(data, :author)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.TrackerPhaseEtaUpdated do
  @moduledoc """
  Event emitted when a phase's ETA is updated.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :phase_id, :eta]
  defstruct [
    :task_id,
    :phase_id,
    :eta,
    :updated_by
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          phase_id: String.t(),
          eta: String.t() | nil,
          updated_by: String.t() | nil
        }

  @impl true
  def event_type, do: "tracker_phase_eta_updated"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      phase_id: event.phase_id,
      eta: event.eta,
      updated_by: event.updated_by
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      phase_id: get_field(data, :phase_id),
      eta: get_field(data, :eta),
      updated_by: get_field(data, :updated_by)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end
