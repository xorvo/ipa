defmodule Ipa.Pod.Events.BaseWorkspaceCreated do
  @moduledoc """
  Event emitted when a base workspace is created for a task.

  The base workspace is the root directory for a task's workspace hierarchy.
  """
  @behaviour Ipa.Pod.Event

  defstruct [
    :task_id,
    :workspace_path,
    :config
  ]

  @impl true
  def event_type, do: "base_workspace_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      workspace_path: event.workspace_path,
      config: event.config
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: data[:task_id] || data["task_id"],
      workspace_path: data[:workspace_path] || data["workspace_path"],
      config: data[:config] || data["config"]
    }
  end
end

defmodule Ipa.Pod.Events.SubWorkspaceCreated do
  @moduledoc """
  Event emitted when a sub-workspace is created under a task's base workspace.

  Sub-workspaces are used for planning, workstreams, and other agent activities.
  """
  @behaviour Ipa.Pod.Event

  defstruct [
    :task_id,
    :workspace_name,
    :workspace_path,
    :agent_id,
    :workstream_id,
    :purpose,
    :config
  ]

  @impl true
  def event_type, do: "sub_workspace_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      workspace_name: event.workspace_name,
      workspace_path: event.workspace_path,
      agent_id: event.agent_id,
      workstream_id: event.workstream_id,
      purpose: event.purpose,
      config: event.config
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: data[:task_id] || data["task_id"],
      workspace_name: data[:workspace_name] || data["workspace_name"],
      workspace_path: data[:workspace_path] || data["workspace_path"],
      agent_id: data[:agent_id] || data["agent_id"],
      workstream_id: data[:workstream_id] || data["workstream_id"],
      purpose: atomize_purpose(data[:purpose] || data["purpose"]),
      config: data[:config] || data["config"]
    }
  end

  defp atomize_purpose(nil), do: nil
  defp atomize_purpose(purpose) when is_atom(purpose), do: purpose
  defp atomize_purpose(purpose) when is_binary(purpose), do: String.to_existing_atom(purpose)
end

defmodule Ipa.Pod.Events.WorkspaceCleanup do
  @moduledoc """
  Event emitted when a workspace is cleaned up.

  Can be used for both base workspaces and sub-workspaces.
  """
  @behaviour Ipa.Pod.Event

  defstruct [
    :task_id,
    :workspace_path,
    :workspace_name,
    :workspace_type,
    :reason
  ]

  @impl true
  def event_type, do: "workspace_cleanup"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      workspace_path: event.workspace_path,
      workspace_name: event.workspace_name,
      workspace_type: event.workspace_type,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: data[:task_id] || data["task_id"],
      workspace_path: data[:workspace_path] || data["workspace_path"],
      workspace_name: data[:workspace_name] || data["workspace_name"],
      workspace_type: atomize_type(data[:workspace_type] || data["workspace_type"]),
      reason: data[:reason] || data["reason"]
    }
  end

  defp atomize_type(nil), do: nil
  defp atomize_type(type) when is_atom(type), do: type
  defp atomize_type(type) when is_binary(type), do: String.to_existing_atom(type)
end
