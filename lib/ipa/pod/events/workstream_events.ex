defmodule Ipa.Pod.Events.WorkstreamCreated do
  @moduledoc "Event emitted when a new workstream is created."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :workstream_id, :title]
  defstruct [
    :task_id,
    :workstream_id,
    :title,
    :spec,
    dependencies: [],
    priority: :normal
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          workstream_id: String.t(),
          title: String.t(),
          spec: String.t() | nil,
          dependencies: [String.t()],
          priority: :low | :normal | :high
        }

  @impl true
  def event_type, do: "workstream_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      workstream_id: event.workstream_id,
      title: event.title,
      spec: event.spec,
      dependencies: event.dependencies,
      priority: event.priority
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      workstream_id: get_field(data, :workstream_id),
      title: get_field(data, :title),
      spec: get_field(data, :spec),
      dependencies: get_field(data, :dependencies) || [],
      priority: normalize_priority(get_field(data, :priority))
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_priority(:low), do: :low
  defp normalize_priority(:normal), do: :normal
  defp normalize_priority(:high), do: :high
  defp normalize_priority("low"), do: :low
  defp normalize_priority("normal"), do: :normal
  defp normalize_priority("high"), do: :high
  defp normalize_priority(_), do: :normal
end

defmodule Ipa.Pod.Events.WorkstreamStarted do
  @moduledoc "Event emitted when a workstream starts execution."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :workstream_id, :agent_id]
  defstruct [:task_id, :workstream_id, :agent_id, :workspace_path]

  @type t :: %__MODULE__{
          task_id: String.t(),
          workstream_id: String.t(),
          agent_id: String.t(),
          workspace_path: String.t() | nil
        }

  @impl true
  def event_type, do: "workstream_started"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      workstream_id: event.workstream_id,
      agent_id: event.agent_id,
      workspace_path: event.workspace_path
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      workstream_id: get_field(data, :workstream_id),
      agent_id: get_field(data, :agent_id),
      workspace_path: get_field(data, :workspace_path)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.WorkstreamCompleted do
  @moduledoc "Event emitted when a workstream completes successfully."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :workstream_id]
  defstruct [:task_id, :workstream_id, :result_summary, :artifacts]

  @type t :: %__MODULE__{
          task_id: String.t(),
          workstream_id: String.t(),
          result_summary: String.t() | nil,
          artifacts: [String.t()] | nil
        }

  @impl true
  def event_type, do: "workstream_completed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      workstream_id: event.workstream_id,
      result_summary: event.result_summary,
      artifacts: event.artifacts
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      workstream_id: get_field(data, :workstream_id),
      result_summary: get_field(data, :result_summary),
      artifacts: get_field(data, :artifacts)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.WorkstreamFailed do
  @moduledoc "Event emitted when a workstream fails."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :workstream_id, :error]
  defstruct [:task_id, :workstream_id, :error, recoverable?: false]

  @type t :: %__MODULE__{
          task_id: String.t(),
          workstream_id: String.t(),
          error: String.t(),
          recoverable?: boolean()
        }

  @impl true
  def event_type, do: "workstream_failed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      workstream_id: event.workstream_id,
      error: event.error,
      recoverable?: event.recoverable?
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      workstream_id: get_field(data, :workstream_id),
      error: get_field(data, :error),
      recoverable?: get_field(data, :recoverable?) || false
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.WorkstreamAgentStarted do
  @moduledoc "Event emitted when an agent is started for a workstream."
  @behaviour Ipa.Pod.Event

  defstruct [:task_id, :workstream_id, :agent_id, :agent_type, :workspace]

  @impl true
  def event_type, do: "workstream_agent_started"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      workstream_id: event.workstream_id,
      agent_id: event.agent_id,
      agent_type: event.agent_type,
      workspace: event.workspace
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      workstream_id: get_field(data, :workstream_id),
      agent_id: get_field(data, :agent_id),
      agent_type: get_field(data, :agent_type),
      # Support both :workspace and :workspace_path
      workspace: get_field(data, :workspace) || get_field(data, :workspace_path)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end
