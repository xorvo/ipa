defmodule Ipa.Pod.WorkspaceManager do
  @moduledoc """
  Stateless module for workspace filesystem operations.

  This module provides pure functions for creating, managing, and cleaning up
  hierarchical workspaces. Pod.Manager orchestrates calls to this module and
  persists workspace events.

  ## Workspace Hierarchy

  Workspaces follow a two-level hierarchy:

  - **Base workspace**: `{base_path}/{task_id}/` - One per task, created when pod starts
  - **Sub-workspaces**: `{base_path}/{task_id}/sub-workspaces/{name}/` - Created as needed

  ## Directory Structure

      {base_path}/
        {task_id}/                           # Base workspace
          .ipa/
            task_spec.json
            workspace_config.json
          CLAUDE.md                          # Task-level agent instructions
          AGENT.md                           # Identical to CLAUDE.md
          work/                              # Agent working directory
          output/                            # Agent output directory
          sub-workspaces/
            planning-abc123/                 # Planning sub-workspace
              .ipa/
                workspace_config.json
              CLAUDE.md
              AGENT.md
              work/
              output/
            setup-db-def456/                 # Workstream sub-workspace
              ...

  ## Usage

      # Create base workspace for a task
      {:ok, base_path} = WorkspaceManager.create_base_workspace("task-123", %{
        agent_file_content: "# Task Context..."
      })

      # Create sub-workspace
      {:ok, sub_path} = WorkspaceManager.create_sub_workspace("task-123", "planning", %{
        agent_file_content: "# Planning Context..."
      })

      # Cleanup
      :ok = WorkspaceManager.cleanup_sub_workspace("task-123", "planning")
      :ok = WorkspaceManager.cleanup_base_workspace("task-123")
  """

  require Logger

  alias Ipa.Pod.WorkspaceManager.AgentFile.ContentBlock

  # ============================================================================
  # Path Helpers
  # ============================================================================

  @doc """
  Returns the configured base path for all workspaces.
  """
  @spec base_path() :: String.t()
  def base_path do
    Application.get_env(:ipa, :workspace_base_path, "/tmp/ipa/workspaces")
  end

  @doc """
  Returns the path to a task's base workspace.
  """
  @spec task_workspace_path(String.t()) :: String.t()
  def task_workspace_path(task_id) do
    Path.join(base_path(), task_id)
  end

  @doc """
  Returns the path to the sub-workspaces directory for a task.
  """
  @spec sub_workspaces_dir(String.t()) :: String.t()
  def sub_workspaces_dir(task_id) do
    Path.join(task_workspace_path(task_id), "sub-workspaces")
  end

  @doc """
  Returns the path to a specific sub-workspace.
  """
  @spec sub_workspace_path(String.t(), String.t()) :: String.t()
  def sub_workspace_path(task_id, workspace_name) do
    Path.join(sub_workspaces_dir(task_id), workspace_name)
  end

  # ============================================================================
  # Workspace Name Generation
  # ============================================================================

  @doc """
  Generates a workspace name with a human-readable prefix and unique suffix.

  ## Examples

      generate_workspace_name("planning", "task-abc-123")
      #=> "planning-abc123"

      generate_workspace_name("setup database", "ws-def-456")
      #=> "setup-database-def456"

      generate_workspace_name(nil, "random-id")
      #=> "ws-random"
  """
  @spec generate_workspace_name(String.t() | nil, String.t()) :: String.t()
  def generate_workspace_name(nil, unique_suffix) do
    short_suffix = extract_short_id(unique_suffix)
    "ws-#{short_suffix}"
  end

  def generate_workspace_name(prefix, unique_suffix) do
    sanitized_prefix = sanitize_name(prefix)
    short_suffix = extract_short_id(unique_suffix)
    "#{sanitized_prefix}-#{short_suffix}"
  end

  @doc """
  Sanitizes a string to be safe for use as a workspace directory name.
  """
  @spec sanitize_name(String.t()) :: String.t()
  def sanitize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
    |> String.slice(0, 50)
  end

  # ============================================================================
  # Base Workspace Operations
  # ============================================================================

  @doc """
  Creates the base workspace for a task.

  ## Parameters

  - `task_id` - UUID of the task
  - `config` - Configuration map:
    - `:agent_file_content` - Content for CLAUDE.md/AGENT.md files
    - `:task_spec` - Task specification to store in .ipa/task_spec.json

  ## Returns

  - `{:ok, workspace_path}` - Workspace created successfully
  - `{:error, :already_exists}` - Workspace already exists
  - `{:error, reason}` - Creation failed
  """
  @spec create_base_workspace(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_base_workspace(task_id, config \\ %{}) do
    workspace_path = task_workspace_path(task_id)

    if File.exists?(workspace_path) do
      {:error, :already_exists}
    else
      case do_create_base_workspace(workspace_path, task_id, config) do
        :ok -> {:ok, workspace_path}
        error -> error
      end
    end
  end

  @doc """
  Ensures a base workspace exists, creating it if necessary.
  """
  @spec ensure_base_workspace(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def ensure_base_workspace(task_id, config \\ %{}) do
    workspace_path = task_workspace_path(task_id)

    if File.exists?(workspace_path) do
      {:ok, workspace_path}
    else
      create_base_workspace(task_id, config)
    end
  end

  @doc """
  Cleans up a task's entire base workspace, including all sub-workspaces.
  """
  @spec cleanup_base_workspace(String.t()) :: :ok | {:error, term()}
  def cleanup_base_workspace(task_id) do
    workspace_path = task_workspace_path(task_id)

    if File.exists?(workspace_path) do
      case File.rm_rf(workspace_path) do
        {:ok, _} ->
          Logger.info("[WorkspaceManager] Cleaned up base workspace: #{workspace_path}")
          :ok

        {:error, reason, _} ->
          Logger.error("[WorkspaceManager] Failed to cleanup base workspace: #{inspect(reason)}")
          {:error, {:cleanup_failed, reason}}
      end
    else
      :ok
    end
  end

  # ============================================================================
  # Sub-Workspace Operations
  # ============================================================================

  @doc """
  Creates a sub-workspace under a task's base workspace.

  ## Parameters

  - `task_id` - UUID of the task
  - `workspace_name` - Name of the sub-workspace (should be generated via `generate_workspace_name/2`)
  - `config` - Configuration map:
    - `:agent_file_content` - Content for CLAUDE.md/AGENT.md files
    - `:workstream_id` - Optional workstream ID this workspace belongs to
    - `:purpose` - Purpose of the workspace (:planning, :workstream, etc.)

  ## Returns

  - `{:ok, workspace_path}` - Sub-workspace created successfully
  - `{:error, :base_workspace_not_exists}` - Base workspace must exist first
  - `{:error, :already_exists}` - Sub-workspace already exists
  - `{:error, reason}` - Creation failed
  """
  @spec create_sub_workspace(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_sub_workspace(task_id, workspace_name, config \\ %{}) do
    base_path = task_workspace_path(task_id)
    workspace_path = sub_workspace_path(task_id, workspace_name)

    cond do
      not File.exists?(base_path) ->
        {:error, :base_workspace_not_exists}

      File.exists?(workspace_path) ->
        {:error, :already_exists}

      true ->
        case do_create_sub_workspace(workspace_path, task_id, workspace_name, config) do
          :ok -> {:ok, workspace_path}
          error -> error
        end
    end
  end

  @doc """
  Cleans up a specific sub-workspace.
  """
  @spec cleanup_sub_workspace(String.t(), String.t()) :: :ok | {:error, term()}
  def cleanup_sub_workspace(task_id, workspace_name) do
    workspace_path = sub_workspace_path(task_id, workspace_name)

    if File.exists?(workspace_path) do
      case File.rm_rf(workspace_path) do
        {:ok, _} ->
          Logger.info("[WorkspaceManager] Cleaned up sub-workspace: #{workspace_path}")
          :ok

        {:error, reason, _} ->
          Logger.error("[WorkspaceManager] Failed to cleanup sub-workspace: #{inspect(reason)}")
          {:error, {:cleanup_failed, reason}}
      end
    else
      {:error, :not_found}
    end
  end

  # ============================================================================
  # Query Operations
  # ============================================================================

  @doc """
  Lists all sub-workspaces for a task.
  """
  @spec list_sub_workspaces(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_sub_workspaces(task_id) do
    sub_dir = sub_workspaces_dir(task_id)

    case File.ls(sub_dir) do
      {:ok, entries} ->
        # Filter to only directories
        workspace_names =
          Enum.filter(entries, fn entry ->
            File.dir?(Path.join(sub_dir, entry))
          end)

        {:ok, workspace_names}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if a base workspace exists for a task.
  """
  @spec base_workspace_exists?(String.t()) :: boolean()
  def base_workspace_exists?(task_id) do
    File.exists?(task_workspace_path(task_id))
  end

  @doc """
  Checks if a sub-workspace exists.
  """
  @spec sub_workspace_exists?(String.t(), String.t()) :: boolean()
  def sub_workspace_exists?(task_id, workspace_name) do
    File.exists?(sub_workspace_path(task_id, workspace_name))
  end

  @doc """
  Gets the path to a sub-workspace if it exists.
  """
  @spec get_sub_workspace_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get_sub_workspace_path(task_id, workspace_name) do
    path = sub_workspace_path(task_id, workspace_name)

    if File.exists?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end

  # ============================================================================
  # File Operations (for pod-level inspection)
  # ============================================================================

  @doc """
  Reads a file from a sub-workspace.
  """
  @spec read_file(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_file(task_id, workspace_name, relative_path) do
    workspace_path = sub_workspace_path(task_id, workspace_name)

    with {:ok, full_path} <- validate_path(workspace_path, relative_path),
         {:ok, content} <- File.read(full_path) do
      {:ok, content}
    else
      {:error, :enoent} -> {:error, :file_not_found}
      error -> error
    end
  end

  @doc """
  Writes a file to a sub-workspace.
  """
  @spec write_file(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_file(task_id, workspace_name, relative_path, content) do
    workspace_path = sub_workspace_path(task_id, workspace_name)

    with {:ok, full_path} <- validate_path(workspace_path, relative_path),
         :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, content) do
      :ok
    end
  end

  @doc """
  Lists files in a sub-workspace as a tree structure.
  """
  @spec list_files(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def list_files(task_id, workspace_name) do
    workspace_path = sub_workspace_path(task_id, workspace_name)

    if File.exists?(workspace_path) do
      build_file_tree(workspace_path)
    else
      {:error, :not_found}
    end
  end

  # ============================================================================
  # Private Functions - Base Workspace Creation
  # ============================================================================

  defp do_create_base_workspace(workspace_path, task_id, config) do
    try do
      # Create directory structure
      File.mkdir_p!(workspace_path)
      File.mkdir_p!(Path.join(workspace_path, ".ipa"))
      File.mkdir_p!(Path.join(workspace_path, "sub-workspaces"))
      File.mkdir_p!(Path.join(workspace_path, "work"))
      File.mkdir_p!(Path.join(workspace_path, "output"))

      # Write metadata
      task_spec = config[:task_spec] || %{task_id: task_id}
      File.write!(
        Path.join([workspace_path, ".ipa", "task_spec.json"]),
        Jason.encode!(task_spec, pretty: true)
      )

      workspace_config = Map.drop(config, [:agent_file_content, :task_spec])
      File.write!(
        Path.join([workspace_path, ".ipa", "workspace_config.json"]),
        Jason.encode!(workspace_config, pretty: true)
      )

      # Write agent files
      agent_content = config[:agent_file_content] || default_base_workspace_content(task_id)
      write_agent_files(workspace_path, agent_content)

      Logger.info("[WorkspaceManager] Created base workspace: #{workspace_path}")
      :ok
    rescue
      error ->
        Logger.error("[WorkspaceManager] Failed to create base workspace: #{inspect(error)}")
        # Cleanup partial creation
        File.rm_rf(workspace_path)
        {:error, {:creation_failed, error}}
    end
  end

  # ============================================================================
  # Private Functions - Sub-Workspace Creation
  # ============================================================================

  defp do_create_sub_workspace(workspace_path, task_id, workspace_name, config) do
    try do
      # Create directory structure
      File.mkdir_p!(workspace_path)
      File.mkdir_p!(Path.join(workspace_path, ".ipa"))
      File.mkdir_p!(Path.join(workspace_path, "work"))
      File.mkdir_p!(Path.join(workspace_path, "output"))

      # Write metadata
      workspace_config = %{
        task_id: task_id,
        workspace_name: workspace_name,
        workstream_id: config[:workstream_id],
        purpose: config[:purpose],
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
      File.write!(
        Path.join([workspace_path, ".ipa", "workspace_config.json"]),
        Jason.encode!(workspace_config, pretty: true)
      )

      # Write agent files
      agent_content = config[:agent_file_content] || default_sub_workspace_content(task_id, workspace_name)
      write_agent_files(workspace_path, agent_content)

      Logger.info("[WorkspaceManager] Created sub-workspace: #{workspace_path}")
      :ok
    rescue
      error ->
        Logger.error("[WorkspaceManager] Failed to create sub-workspace: #{inspect(error)}")
        File.rm_rf(workspace_path)
        {:error, {:creation_failed, error}}
    end
  end

  defp write_agent_files(workspace_path, content) do
    # Write both CLAUDE.md and AGENT.md with identical content
    File.write!(Path.join(workspace_path, "CLAUDE.md"), content)
    File.write!(Path.join(workspace_path, "AGENT.md"), content)
  end

  defp default_base_workspace_content(task_id) do
    ContentBlock.compose_for_base_workspace(%{
      task_id: task_id,
      task_title: "Task #{task_id}",
      task_spec: "No specification provided"
    })
  end

  defp default_sub_workspace_content(task_id, workspace_name) do
    ContentBlock.compose_for_sub_workspace(%{
      task_id: task_id,
      task_title: "Task #{task_id}",
      task_spec: "No specification provided",
      workstream_id: workspace_name,
      workstream_title: workspace_name,
      workstream_spec: "No specification provided",
      workstream_dependencies: []
    })
  end

  # ============================================================================
  # Private Functions - Path Validation
  # ============================================================================

  defp validate_path(workspace_path, relative_path) do
    cond do
      String.contains?(relative_path, "\0") ->
        {:error, :invalid_path_null_byte}

      String.starts_with?(relative_path, "/") ->
        {:error, :absolute_path_not_allowed}

      String.contains?(relative_path, "..") ->
        {:error, :path_traversal_attempt}

      String.length(relative_path) > 4096 ->
        {:error, :path_too_long}

      true ->
        full_path = Path.join(workspace_path, relative_path) |> Path.expand()
        expanded_workspace = Path.expand(workspace_path)

        if String.starts_with?(full_path, expanded_workspace <> "/") or full_path == expanded_workspace do
          {:ok, full_path}
        else
          {:error, :path_outside_workspace}
        end
    end
  end

  # ============================================================================
  # Private Functions - File Tree
  # ============================================================================

  defp build_file_tree(path) do
    case File.ls(path) do
      {:ok, entries} ->
        tree =
          Enum.reduce(entries, %{}, fn entry, acc ->
            entry_path = Path.join(path, entry)

            case File.stat(entry_path) do
              {:ok, %File.Stat{type: :directory}} ->
                case build_file_tree(entry_path) do
                  {:ok, subtree} -> Map.put(acc, entry, subtree)
                  _ -> acc
                end

              {:ok, %File.Stat{type: :regular}} ->
                Map.put(acc, entry, :file)

              _ ->
                acc
            end
          end)

        {:ok, tree}

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  # ============================================================================
  # Private Functions - Helpers
  # ============================================================================

  defp extract_short_id(id) do
    id
    |> String.replace("-", "")
    |> String.slice(0, 8)
  end
end
