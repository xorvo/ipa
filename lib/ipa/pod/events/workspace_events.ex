defmodule Ipa.Pod.Events.WorkspaceCreated do
  @moduledoc """
  Event emitted when a workspace is created for an agent.
  """
  @behaviour Ipa.Pod.Event

  defstruct [
    :agent_id,
    :workspace_path,
    :workstream_id,
    :config
  ]

  @impl true
  def event_type, do: "workspace_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      agent_id: event.agent_id,
      workspace_path: event.workspace_path,
      workstream_id: event.workstream_id,
      config: event.config
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      agent_id: data[:agent_id] || data["agent_id"],
      workspace_path: data[:workspace_path] || data["workspace_path"],
      workstream_id: data[:workstream_id] || data["workstream_id"],
      config: data[:config] || data["config"]
    }
  end
end

defmodule Ipa.Pod.Events.WorkspaceCleanup do
  @moduledoc """
  Event emitted when a workspace is cleaned up.
  """
  @behaviour Ipa.Pod.Event

  defstruct [
    :agent_id,
    :workspace_path,
    :reason
  ]

  @impl true
  def event_type, do: "workspace_cleanup"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      agent_id: event.agent_id,
      workspace_path: event.workspace_path,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      agent_id: data[:agent_id] || data["agent_id"],
      workspace_path: data[:workspace_path] || data["workspace_path"],
      reason: data[:reason] || data["reason"]
    }
  end
end
