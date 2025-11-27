defmodule Ipa.Pod.Events.TaskCreated do
  @moduledoc "Event emitted when a new task is created."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :title]
  defstruct [
    :task_id,
    :title,
    :description,
    requirements: [],
    acceptance_criteria: [],
    external_references: %{}
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          requirements: [String.t()],
          acceptance_criteria: [String.t()],
          external_references: map()
        }

  @impl true
  def event_type, do: "task_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      title: event.title,
      description: event.description,
      requirements: event.requirements,
      acceptance_criteria: event.acceptance_criteria,
      external_references: event.external_references
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      title: get_field(data, :title),
      description: get_field(data, :description),
      requirements: get_field(data, :requirements) || [],
      acceptance_criteria: get_field(data, :acceptance_criteria) || [],
      external_references: get_field(data, :external_references) || %{}
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.SpecUpdated do
  @moduledoc "Event emitted when the task spec is updated."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id]
  defstruct [
    :task_id,
    :description,
    :requirements,
    :acceptance_criteria,
    :external_references
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          description: String.t() | nil,
          requirements: [String.t()] | nil,
          acceptance_criteria: [String.t()] | nil,
          external_references: map() | nil
        }

  @impl true
  def event_type, do: "spec_updated"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      description: event.description,
      requirements: event.requirements,
      acceptance_criteria: event.acceptance_criteria,
      external_references: event.external_references
    }
  end

  @impl true
  def from_map(data) do
    # Support both nested spec format and flat format
    spec_data = get_field(data, :spec)

    if spec_data && is_map(spec_data) do
      %__MODULE__{
        task_id: get_field(data, :task_id),
        description: get_field(spec_data, :description),
        requirements: get_field(spec_data, :requirements),
        acceptance_criteria: get_field(spec_data, :acceptance_criteria),
        external_references: get_field(spec_data, :external_references)
      }
    else
      %__MODULE__{
        task_id: get_field(data, :task_id),
        description: get_field(data, :description),
        requirements: get_field(data, :requirements),
        acceptance_criteria: get_field(data, :acceptance_criteria),
        external_references: get_field(data, :external_references)
      }
    end
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.SpecApproved do
  @moduledoc "Event emitted when the task spec is approved."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :approved_by]
  defstruct [:task_id, :approved_by, :comment]

  @type t :: %__MODULE__{
          task_id: String.t(),
          approved_by: String.t(),
          comment: String.t() | nil
        }

  @impl true
  def event_type, do: "spec_approved"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      approved_by: event.approved_by,
      comment: event.comment
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      approved_by: get_field(data, :approved_by),
      comment: get_field(data, :comment)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.PlanCreated do
  @moduledoc "Event emitted when a plan is created for the task."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id]
  defstruct [
    :task_id,
    :summary,
    workstreams: [],
    created_by: nil
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          summary: String.t() | nil,
          workstreams: [map()],
          created_by: String.t() | nil
        }

  @impl true
  def event_type, do: "plan_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      summary: event.summary,
      workstreams: event.workstreams,
      created_by: event.created_by
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      summary: get_field(data, :summary),
      workstreams: get_field(data, :workstreams) || [],
      created_by: get_field(data, :created_by)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.PlanUpdated do
  @moduledoc "Event emitted when the plan is updated."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id]
  defstruct [
    :task_id,
    :summary,
    :workstreams,
    :updated_by
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          summary: String.t() | nil,
          workstreams: [map()] | nil,
          updated_by: String.t() | nil
        }

  @impl true
  def event_type, do: "plan_updated"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      summary: event.summary,
      workstreams: event.workstreams,
      updated_by: event.updated_by
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      summary: get_field(data, :summary),
      workstreams: get_field(data, :workstreams),
      updated_by: get_field(data, :updated_by)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.PlanApproved do
  @moduledoc "Event emitted when the plan is approved."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :approved_by]
  defstruct [:task_id, :approved_by, :comment]

  @type t :: %__MODULE__{
          task_id: String.t(),
          approved_by: String.t(),
          comment: String.t() | nil
        }

  @impl true
  def event_type, do: "plan_approved"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      approved_by: event.approved_by,
      comment: event.comment
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      approved_by: get_field(data, :approved_by),
      comment: get_field(data, :comment)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.TaskCompleted do
  @moduledoc "Event emitted when a task is completed."
  @behaviour Ipa.Pod.Event

  defstruct [:task_id, :summary, :completed_by, :artifacts]

  @impl true
  def event_type, do: "task_completed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      summary: event.summary,
      completed_by: event.completed_by,
      artifacts: event.artifacts
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      summary: get_field(data, :summary),
      completed_by: get_field(data, :completed_by),
      artifacts: get_field(data, :artifacts)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end
