defmodule Ipa.Pod.Events.AgentStarted do
  @moduledoc "Event emitted when an agent is started."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id, :agent_type]
  defstruct [
    :task_id,
    :agent_id,
    :agent_type,
    :workstream_id,
    :workspace_path
  ]

  @type agent_type :: :planning | :workstream | :review

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          agent_type: agent_type(),
          workstream_id: String.t() | nil,
          workspace_path: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_started"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      agent_type: event.agent_type,
      workstream_id: event.workstream_id,
      workspace_path: event.workspace_path
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      agent_type: normalize_agent_type(get_field(data, :agent_type)),
      workstream_id: get_field(data, :workstream_id),
      workspace_path: get_field(data, :workspace_path) || get_field(data, :workspace)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_agent_type(:planning), do: :planning
  defp normalize_agent_type(:planning_agent), do: :planning
  defp normalize_agent_type(:workstream), do: :workstream
  defp normalize_agent_type(:review), do: :review
  defp normalize_agent_type(:workstream_executor), do: :workstream
  defp normalize_agent_type("planning"), do: :planning
  defp normalize_agent_type("planning_agent"), do: :planning
  defp normalize_agent_type("workstream"), do: :workstream
  defp normalize_agent_type("review"), do: :review
  defp normalize_agent_type("workstream_executor"), do: :workstream
  defp normalize_agent_type(other) do
    require Logger
    Logger.warning("Unknown agent_type: #{inspect(other)}, defaulting to :workstream")
    :workstream
  end
end

defmodule Ipa.Pod.Events.AgentCompleted do
  @moduledoc "Event emitted when an agent completes."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id]
  defstruct [:task_id, :agent_id, :result_summary, :output]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          result_summary: String.t() | nil,
          output: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_completed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      result_summary: event.result_summary,
      output: event.output
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      result_summary: get_field(data, :result_summary),
      output: get_field(data, :output)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.AgentFailed do
  @moduledoc "Event emitted when an agent fails."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id, :error]
  defstruct [:task_id, :agent_id, :error]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          error: String.t()
        }

  @impl true
  def event_type, do: "agent_failed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      error: event.error
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      error: get_field(data, :error)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.AgentInterrupted do
  @moduledoc "Event emitted when an agent is interrupted."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:agent_id]
  defstruct [:task_id, :agent_id, :interrupted_by, :reason]

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          agent_id: String.t(),
          interrupted_by: String.t() | nil,
          reason: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_interrupted"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      interrupted_by: event.interrupted_by,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      interrupted_by: get_field(data, :interrupted_by),
      reason: get_field(data, :reason)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end
