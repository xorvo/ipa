defmodule Ipa.Pod.State.TrackerItem do
  @moduledoc """
  Represents a single item in a tracker phase.

  Each item belongs to exactly ONE workstream (owner), but a workstream can own
  multiple items. Items track progress through status changes and can have
  comments visible to all participants.

  ## Status Values

  - `:todo` - Item not started
  - `:wip` - Work in progress
  - `:done` - Item completed
  - `:blocked` - Item blocked (agents can set this)

  ## Ownership

  The `workstream_id` field indicates which workstream owns this item.
  During planning, each item must be assigned to exactly one workstream.
  Workstreams can only update items they own unless requesting approval.
  """

  @type status :: :todo | :wip | :done | :blocked

  defstruct [
    :item_id,
    :phase_id,
    :summary,
    :workstream_id,
    :created_at,
    :updated_at,
    status: :todo,
    comments: []
  ]

  @type t :: %__MODULE__{
          item_id: String.t(),
          phase_id: String.t(),
          summary: String.t(),
          workstream_id: String.t() | nil,
          status: status(),
          comments: [map()],
          created_at: integer() | nil,
          updated_at: integer() | nil
        }

  @doc "Returns true if the item is completed."
  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{status: :done}), do: true
  def completed?(_), do: false

  @doc "Returns true if the item is blocked."
  @spec blocked?(t()) :: boolean()
  def blocked?(%__MODULE__{status: :blocked}), do: true
  def blocked?(_), do: false

  @doc "Returns true if the item is in progress."
  @spec in_progress?(t()) :: boolean()
  def in_progress?(%__MODULE__{status: :wip}), do: true
  def in_progress?(_), do: false
end

defmodule Ipa.Pod.State.TrackerPhase do
  @moduledoc """
  Represents a phase in the progress tracker.

  Phases are the top-level organizational unit for tracking progress.
  Each phase contains expected outcomes (items) with their own statuses.

  ## ETA Handling

  - `eta`: Initially set manually during planning, can be updated
  - Progress is calculated automatically based on item statuses

  ## Ordering

  Phases have an `order` field for display sequencing.
  """

  alias Ipa.Pod.State.TrackerItem

  defstruct [
    :phase_id,
    :name,
    :summary,
    :description,
    :eta,
    :order,
    :created_at,
    :updated_at,
    items: []
  ]

  @type t :: %__MODULE__{
          phase_id: String.t(),
          name: String.t(),
          summary: String.t() | nil,
          description: String.t() | nil,
          eta: Date.t() | nil,
          order: integer(),
          items: [TrackerItem.t()],
          created_at: integer() | nil,
          updated_at: integer() | nil
        }

  @doc "Calculates progress percentage for the phase."
  @spec progress_percentage(t()) :: float()
  def progress_percentage(%__MODULE__{items: []}), do: 0.0

  def progress_percentage(%__MODULE__{items: items}) do
    total = length(items)
    done = Enum.count(items, &TrackerItem.completed?/1)
    done / total * 100.0
  end

  @doc "Returns items in a specific status."
  @spec items_by_status(t(), TrackerItem.status()) :: [TrackerItem.t()]
  def items_by_status(%__MODULE__{items: items}, status) do
    Enum.filter(items, &(&1.status == status))
  end

  @doc "Returns items owned by a specific workstream."
  @spec items_by_workstream(t(), String.t()) :: [TrackerItem.t()]
  def items_by_workstream(%__MODULE__{items: items}, workstream_id) do
    Enum.filter(items, &(&1.workstream_id == workstream_id))
  end

  @doc "Returns true if all items are completed."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{items: []}), do: false
  def complete?(%__MODULE__{items: items}), do: Enum.all?(items, &TrackerItem.completed?/1)
end

defmodule Ipa.Pod.State.Tracker do
  @moduledoc """
  The progress tracker for a task.

  The tracker organizes work into phases, each containing expected outcomes (items).
  It provides a high-level view of task progress that is visible to all participants.

  ## Structure

  ```
  Tracker
  └── Phases (ordered)
      └── Items (expected outcomes)
          - summary
          - status (TODO/WIP/DONE/BLOCKED)
          - workstream_id (owner)
          - comments
  ```

  ## Workflow

  1. **Planning**: Planning agent creates initial tracker with phases and items
  2. **Execution**: Workstreams update their items' status
  3. **Modifications**: Adding/updating/removing items requires admin approval

  ## Rules

  - Each item belongs to exactly ONE workstream
  - Workstreams can only directly update items they own
  - Item modifications (add/update/remove) require approval
  - Comments are visible to everyone
  """

  alias Ipa.Pod.State.{TrackerPhase, TrackerItem}

  defstruct [
    :task_id,
    :created_at,
    :updated_at,
    phases: []
  ]

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          phases: [TrackerPhase.t()],
          created_at: integer() | nil,
          updated_at: integer() | nil
        }

  @doc "Creates a new empty tracker for a task."
  @spec new(String.t()) :: t()
  def new(task_id) do
    %__MODULE__{
      task_id: task_id,
      created_at: System.system_time(:second)
    }
  end

  @doc "Returns all phases sorted by order."
  @spec sorted_phases(t()) :: [TrackerPhase.t()]
  def sorted_phases(%__MODULE__{phases: phases}) do
    Enum.sort_by(phases, & &1.order)
  end

  @doc "Gets a phase by ID."
  @spec get_phase(t(), String.t()) :: TrackerPhase.t() | nil
  def get_phase(%__MODULE__{phases: phases}, phase_id) do
    Enum.find(phases, &(&1.phase_id == phase_id))
  end

  @doc "Gets an item by ID (searches all phases)."
  @spec get_item(t(), String.t()) :: {TrackerPhase.t(), TrackerItem.t()} | nil
  def get_item(%__MODULE__{phases: phases}, item_id) do
    Enum.find_value(phases, fn phase ->
      case Enum.find(phase.items, &(&1.item_id == item_id)) do
        nil -> nil
        item -> {phase, item}
      end
    end)
  end

  @doc "Returns all items for a workstream across all phases."
  @spec items_for_workstream(t(), String.t()) :: [TrackerItem.t()]
  def items_for_workstream(%__MODULE__{phases: phases}, workstream_id) do
    phases
    |> Enum.flat_map(& &1.items)
    |> Enum.filter(&(&1.workstream_id == workstream_id))
  end

  @doc "Calculates overall progress percentage."
  @spec overall_progress(t()) :: float()
  def overall_progress(%__MODULE__{phases: []}), do: 0.0

  def overall_progress(%__MODULE__{phases: phases}) do
    all_items = Enum.flat_map(phases, & &1.items)
    total = length(all_items)

    if total == 0 do
      0.0
    else
      done = Enum.count(all_items, &TrackerItem.completed?/1)
      done / total * 100.0
    end
  end

  @doc "Returns summary statistics for the tracker."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{phases: phases}) do
    all_items = Enum.flat_map(phases, & &1.items)

    %{
      total_phases: length(phases),
      total_items: length(all_items),
      todo: Enum.count(all_items, &(&1.status == :todo)),
      wip: Enum.count(all_items, &(&1.status == :wip)),
      done: Enum.count(all_items, &(&1.status == :done)),
      blocked: Enum.count(all_items, &(&1.status == :blocked))
    }
  end

  @doc "Checks if a workstream owns a specific item."
  @spec workstream_owns_item?(t(), String.t(), String.t()) :: boolean()
  def workstream_owns_item?(tracker, workstream_id, item_id) do
    case get_item(tracker, item_id) do
      nil -> false
      {_phase, item} -> item.workstream_id == workstream_id
    end
  end
end
