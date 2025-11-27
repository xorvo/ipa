defmodule Ipa.Pod.WorkspaceManager do
  @moduledoc """
  Manages isolated filesystem workspaces for agents executing within a pod.

  ## Primary Responsibilities

  - **Workspace Lifecycle Management**: Creates, destroys, and lists workspaces using
    native Elixir file operations (`File.mkdir_p`, `File.rm_rf`)
  - **Agent Execution Coordination**: Provides workspace paths to Pod Scheduler for
    agent spawning (agents work directly in workspace via Claude Code SDK)
  - **Workspace State Tracking**: Maintains workspace metadata and lifecycle events
  - **File Utilities**: Provides Elixir file operations for pod-level inspection

  ## Architecture

  The WorkspaceManager creates and manages isolated filesystem workspaces directly using
  Elixir File operations. Each workspace has a structured directory layout that's easy
  for both agents and humans to navigate and inspect.

  Agents DO NOT use WorkspaceManager for file operations - they work directly in their
  workspace directory via the Claude Code SDK with standard file operations.

  ## Workspace Directory Structure

      /ipa/workspaces/{task_id}/{agent_id}/
      ├── .ipa/                      # IPA metadata (read-only for agent)
      │   ├── task_spec.json         # Task specification
      │   ├── workspace_config.json  # Workspace configuration
      │   └── context.json           # Additional task context
      ├── CLAUDE.md                  # Injected agent instructions (if provided)
      ├── work/                      # Agent working directory (read-write)
      └── output/                    # Agent output artifacts (read-write)

  ## Usage

      # Create workspace for agent
      {:ok, path} = Ipa.Pod.WorkspaceManager.create_workspace(
        "task-123",
        "agent-456",
        %{max_size_mb: 1000, git_config: %{enabled: true}}
      )
      # => Creates: /ipa/workspaces/task-123/agent-456/
      # => Returns: {:ok, "/ipa/workspaces/task-123/agent-456"}

      # Agent spawns with workspace as cwd
      options = %Ipa.Agent.Options{cwd: path, allowed_tools: ["Read", "Write", "Bash"]}
      messages = ClaudeAgentSdkTs.stream("Complete task", Ipa.Agent.Options.to_keyword_list(options), fn msg -> msg end) |> Enum.to_list()

      # Cleanup workspace after agent completes
      :ok = Ipa.Pod.WorkspaceManager.cleanup_workspace("task-123", "agent-456")
      # => Removes: /ipa/workspaces/task-123/agent-456/

  ## Configuration

      config :ipa, Ipa.Pod.WorkspaceManager,
        base_path: "/ipa/workspaces",
        default_max_size_mb: 1000,
        cleanup_on_pod_shutdown: true
  """

  use GenServer
  require Logger

  # Client API

  @doc """
  Starts the WorkspaceManager for a specific task.

  ## Parameters

  - `opts` - Keyword list with:
    - `:task_id` (required) - UUID of the task
    - `:name` (optional) - GenServer name override

  ## Returns

  - `{:ok, pid}` - GenServer started successfully
  - `{:stop, reason}` - Failed to start (e.g., base path creation failed)
  """
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    name = Keyword.get(opts, :name, via_tuple(task_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a new workspace for an agent using native Elixir file operations.

  The workspace path is returned and can be used as the `cwd` parameter when
  spawning the agent via the Claude Code SDK.

  ## Parameters

  - `task_id` - UUID of the task
  - `agent_id` - UUID of the agent
  - `config` - Workspace configuration map (optional fields):
    - `:max_size_mb` - Maximum workspace size in MB (default: 1000)
    - `:git_config` - Git configuration map (e.g., `%{enabled: true}`)
    - `:claude_md` - CLAUDE.md content string to inject (optional)

  ## Returns

  - `{:ok, workspace_path}` - Workspace created successfully
  - `{:error, :workspace_exists}` - Workspace already exists
  - `{:error, reason}` - Other creation failure

  ## Example

      {:ok, path} = create_workspace("task-123", "agent-456", %{
        max_size_mb: 500,
        git_config: %{enabled: true},
        claude_md: "# Task Context\\n..."
      })
  """
  @spec create_workspace(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def create_workspace(task_id, agent_id, config \\ %{}) do
    GenServer.call(via_tuple(task_id), {:create_workspace, agent_id, config}, 30_000)
  end

  @doc """
  Removes a workspace and all its contents using `File.rm_rf`.

  ## Parameters

  - `task_id` - UUID of the task
  - `agent_id` - UUID of the agent
  - `opts` - Options keyword list:
    - `:force` - Force deletion even if files are in use (default: false)

  ## Returns

  - `:ok` - Workspace cleaned up successfully
  - `{:error, :workspace_not_found}` - Workspace doesn't exist
  - `{:error, reason}` - Other cleanup failure
  """
  @spec cleanup_workspace(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def cleanup_workspace(task_id, agent_id, opts \\ []) do
    GenServer.call(via_tuple(task_id), {:cleanup_workspace, agent_id, opts}, 30_000)
  end

  @doc """
  Returns the absolute path to a workspace.

  ## Example

      {:ok, "/ipa/workspaces/task-123/agent-456"} =
        get_workspace_path("task-123", "agent-456")
  """
  @spec get_workspace_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :workspace_not_found}
  def get_workspace_path(task_id, agent_id) do
    GenServer.call(via_tuple(task_id), {:get_workspace_path, agent_id})
  end

  @doc """
  Lists all workspaces for a task by scanning the filesystem.

  ## Returns

  - `{:ok, agent_ids}` - List of agent IDs with workspaces
  - `{:error, reason}` - List operation failed
  """
  @spec list_workspaces(String.t()) :: {:ok, list(String.t())} | {:error, term()}
  def list_workspaces(task_id) do
    GenServer.call(via_tuple(task_id), :list_workspaces)
  end

  @doc """
  Checks if a workspace exists.

  ## Example

      true = workspace_exists?("task-123", "agent-456")
  """
  @spec workspace_exists?(String.t(), String.t()) :: boolean()
  def workspace_exists?(task_id, agent_id) do
    case get_workspace_path(task_id, agent_id) do
      {:ok, _path} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Reads a file from within a workspace (optional utility for pod-level inspection).

  NOTE: Agents DO NOT use this function - agents work directly in their workspace
  using standard file operations via the Claude Code SDK.

  ## Parameters

  - `task_id` - UUID of the task
  - `agent_id` - UUID of the agent
  - `relative_path` - Path relative to workspace root

  ## Returns

  - `{:ok, content}` - File content as string
  - `{:error, :path_outside_workspace}` - Path escapes workspace
  - `{:error, :file_not_found}` - File doesn't exist
  - `{:error, reason}` - Read failed
  """
  @spec read_file(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def read_file(task_id, agent_id, relative_path) do
    GenServer.call(via_tuple(task_id), {:read_file, agent_id, relative_path})
  end

  @doc """
  Writes content to a file within a workspace (optional utility for pod-level inspection).

  NOTE: Agents DO NOT use this function - agents work directly in their workspace
  using standard file operations via the Claude Code SDK.

  ## Parameters

  - `task_id` - UUID of the task
  - `agent_id` - UUID of the agent
  - `relative_path` - Path relative to workspace root
  - `content` - Content to write

  ## Returns

  - `:ok` - File written successfully
  - `{:error, :path_outside_workspace}` - Path escapes workspace
  - `{:error, reason}` - Write failed
  """
  @spec write_file(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def write_file(task_id, agent_id, relative_path, content) do
    GenServer.call(via_tuple(task_id), {:write_file, agent_id, relative_path, content})
  end

  @doc """
  Lists all files and directories within a workspace as a nested tree structure.

  ## Returns

  - `{:ok, file_tree}` - Nested map representing directory structure
  - `{:error, :workspace_not_found}` - Workspace doesn't exist
  - `{:error, reason}` - Listing failed

  ## Example

      {:ok, %{
        ".ipa" => %{"task_spec.json" => :file},
        "work" => %{"lib" => %{"auth.ex" => :file}}
      }} = list_files("task-123", "agent-456")
  """
  @spec list_files(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def list_files(task_id, agent_id) do
    GenServer.call(via_tuple(task_id), {:list_files, agent_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)

    config = Application.get_env(:ipa, __MODULE__, [])
    base_path = Keyword.get(config, :base_path, "/ipa/workspaces")

    # Ensure base path exists
    case File.mkdir_p(base_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[WorkspaceManager] Failed to create base path #{base_path}: #{inspect(reason)}"
        )

        {:stop, {:base_path_creation_failed, reason}}
    end

    # Rebuild state from events (event-sourced)
    {:ok, events} =
      Ipa.EventStore.read_stream(task_id,
        event_types: ["workspace_created", "workspace_cleanup"]
      )

    workspaces = Enum.reduce(events, %{}, &apply_workspace_event/2)

    Logger.info(
      "[WorkspaceManager] Initialized for task #{task_id}, loaded #{map_size(workspaces)} workspaces from events"
    )

    {:ok, %{task_id: task_id, base_path: base_path, workspaces: workspaces}}
  end

  @impl true
  def handle_call({:create_workspace, agent_id, config}, _from, state) do
    # Check if workspace already exists
    if Map.has_key?(state.workspaces, agent_id) do
      {:reply, {:error, :workspace_exists}, state}
    else
      # Create workspace directories
      workspace_path = Path.join([state.base_path, state.task_id, agent_id])

      case create_workspace_structure(workspace_path, state.task_id, agent_id, config) do
        :ok ->
          # Inject CLAUDE.md if provided
          if claude_md = config[:claude_md] do
            claude_md_path = Path.join(workspace_path, "CLAUDE.md")

            case File.write(claude_md_path, claude_md) do
              :ok ->
                Logger.info("[WorkspaceManager] Injected CLAUDE.md to #{claude_md_path}")

              {:error, reason} ->
                Logger.warning(
                  "[WorkspaceManager] Failed to write CLAUDE.md: #{inspect(reason)}"
                )
            end
          end

          # Record event
          {:ok, _version} =
            Ipa.EventStore.append(
              state.task_id,
              "workspace_created",
              %{
                agent_id: agent_id,
                workspace_path: workspace_path,
                config: config
              },
              actor_id: "system"
            )

          # Broadcast to pod pub-sub
          Phoenix.PubSub.broadcast(
            Ipa.PubSub,
            "pod:#{state.task_id}:state",
            {:workspace_created, state.task_id, agent_id, workspace_path}
          )

          # Update state
          workspace_metadata = %{
            path: workspace_path,
            created_at: DateTime.utc_now(),
            config: config
          }

          new_workspaces = Map.put(state.workspaces, agent_id, workspace_metadata)
          {:reply, {:ok, workspace_path}, %{state | workspaces: new_workspaces}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:cleanup_workspace, agent_id, _opts}, _from, state) do
    case Map.get(state.workspaces, agent_id) do
      nil ->
        {:reply, {:error, :workspace_not_found}, state}

      workspace_metadata ->
        # Delete workspace directory
        case File.rm_rf(workspace_metadata.path) do
          {:ok, _} ->
            Logger.info("[WorkspaceManager] Deleted workspace: #{workspace_metadata.path}")

            # Record event
            {:ok, _version} =
              Ipa.EventStore.append(
                state.task_id,
                "workspace_cleanup",
                %{
                  agent_id: agent_id,
                  workspace_path: workspace_metadata.path,
                  cleanup_reason: "explicit_cleanup"
                },
                actor_id: "system"
              )

            # Broadcast to pod pub-sub
            Phoenix.PubSub.broadcast(
              Ipa.PubSub,
              "pod:#{state.task_id}:state",
              {:workspace_cleanup, state.task_id, agent_id}
            )

            # Update state
            new_workspaces = Map.delete(state.workspaces, agent_id)
            {:reply, :ok, %{state | workspaces: new_workspaces}}

          {:error, reason, _} ->
            Logger.error(
              "[WorkspaceManager] Failed to delete workspace: #{workspace_metadata.path}, reason: #{inspect(reason)}"
            )

            {:reply, {:error, {:cleanup_failed, reason}}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_workspace_path, agent_id}, _from, state) do
    case Map.get(state.workspaces, agent_id) do
      nil -> {:reply, {:error, :workspace_not_found}, state}
      workspace -> {:reply, {:ok, workspace.path}, state}
    end
  end

  @impl true
  def handle_call(:list_workspaces, _from, state) do
    # List workspaces by scanning filesystem
    task_workspace_dir = Path.join(state.base_path, state.task_id)

    case File.ls(task_workspace_dir) do
      {:ok, entries} ->
        # Filter to only directories (agent IDs)
        agent_ids =
          Enum.filter(entries, fn entry ->
            File.dir?(Path.join(task_workspace_dir, entry))
          end)

        {:reply, {:ok, agent_ids}, state}

      {:error, :enoent} ->
        # Task directory doesn't exist yet - no workspaces
        {:reply, {:ok, []}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read_file, agent_id, relative_path}, _from, state) do
    with {:ok, workspace_path} <- get_workspace_path_from_state(state, agent_id),
         {:ok, full_path} <- validate_path(workspace_path, relative_path),
         {:ok, content} <- File.read(full_path) do
      {:reply, {:ok, content}, state}
    else
      {:error, :enoent} -> {:reply, {:error, :file_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:write_file, agent_id, relative_path, content}, _from, state) do
    with {:ok, workspace_path} <- get_workspace_path_from_state(state, agent_id),
         {:ok, full_path} <- validate_path(workspace_path, relative_path),
         :ok <- ensure_parent_dir(full_path),
         :ok <- File.write(full_path, content) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:list_files, agent_id}, _from, state) do
    with {:ok, workspace_path} <- get_workspace_path_from_state(state, agent_id),
         {:ok, tree} <- build_file_tree(workspace_path, workspace_path) do
      {:reply, {:ok, tree}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "[WorkspaceManager] Shutting down for task #{state.task_id}, reason: #{inspect(reason)}"
    )

    config = Application.get_env(:ipa, __MODULE__, [])

    if Keyword.get(config, :cleanup_on_pod_shutdown, true) do
      # Clean up all workspaces for this task
      task_workspace_dir = Path.join(state.base_path, state.task_id)

      case File.ls(task_workspace_dir) do
        {:ok, agent_ids} ->
          Enum.each(agent_ids, fn agent_id ->
            workspace_path = Path.join(task_workspace_dir, agent_id)

            if File.dir?(workspace_path) do
              Logger.info("[WorkspaceManager] Cleaning up workspace for agent #{agent_id}")

              case File.rm_rf(workspace_path) do
                {:ok, _} ->
                  Logger.info(
                    "[WorkspaceManager] Successfully destroyed workspace for agent #{agent_id}"
                  )

                  # Best effort event recording
                  try do
                    Ipa.EventStore.append(
                      state.task_id,
                      "workspace_cleanup",
                      %{
                        agent_id: agent_id,
                        workspace_path: workspace_path,
                        cleanup_reason: "pod_shutdown"
                      },
                      actor_id: "system"
                    )
                  rescue
                    error ->
                      Logger.warning(
                        "[WorkspaceManager] Could not record workspace_cleanup event: #{inspect(error)}"
                      )
                  end

                {:error, reason, _} ->
                  Logger.error(
                    "[WorkspaceManager] Failed to destroy workspace for agent #{agent_id}: #{inspect(reason)}"
                  )
              end
            end
          end)

        {:error, :enoent} ->
          Logger.info("[WorkspaceManager] No workspaces to clean up")

        {:error, reason} ->
          Logger.error("[WorkspaceManager] Failed to list workspaces: #{inspect(reason)}")
      end
    else
      Logger.info(
        "[WorkspaceManager] Skipping workspace cleanup (cleanup_on_pod_shutdown: false)"
      )
    end

    :ok
  end

  # Private Functions - Workspace Creation

  defp create_workspace_structure(workspace_path, task_id, agent_id, config) do
    try do
      # Create main workspace directory
      File.mkdir_p!(workspace_path)

      # Create subdirectories
      File.mkdir_p!(Path.join(workspace_path, ".ipa"))
      File.mkdir_p!(Path.join(workspace_path, "work"))
      File.mkdir_p!(Path.join(workspace_path, "output"))

      # Write metadata files
      task_spec_path = Path.join([workspace_path, ".ipa", "task_spec.json"])

      File.write!(task_spec_path, Jason.encode!(%{task_id: task_id, agent_id: agent_id}, pretty: true))

      workspace_config_path = Path.join([workspace_path, ".ipa", "workspace_config.json"])
      File.write!(workspace_config_path, Jason.encode!(config, pretty: true))

      context_path = Path.join([workspace_path, ".ipa", "context.json"])

      File.write!(
        context_path,
        Jason.encode!(
          %{
            created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            workspace_path: workspace_path
          },
          pretty: true
        )
      )

      Logger.info("[WorkspaceManager] Created workspace structure at #{workspace_path}")
      :ok
    rescue
      error ->
        Logger.error("[WorkspaceManager] Failed to create workspace: #{inspect(error)}")
        {:error, {:workspace_creation_failed, error}}
    end
  end

  # Private Functions - Event Sourcing

  defp apply_workspace_event(%{event_type: "workspace_created", data: data}, workspaces) do
    Map.put(workspaces, data[:agent_id] || data["agent_id"], %{
      path: data[:workspace_path] || data["workspace_path"],
      created_at: data[:created_at] || data["created_at"],
      config: data[:config] || data["config"]
    })
  end

  defp apply_workspace_event(%{event_type: "workspace_cleanup", data: data}, workspaces) do
    Map.delete(workspaces, data[:agent_id] || data["agent_id"])
  end

  defp apply_workspace_event(_event, workspaces), do: workspaces

  # Private Functions - Path Validation

  defp get_workspace_path_from_state(state, agent_id) do
    case Map.get(state.workspaces, agent_id) do
      nil -> {:error, :workspace_not_found}
      workspace -> {:ok, workspace.path}
    end
  end

  defp validate_path(workspace_path, relative_path) do
    with :ok <- validate_relative_path_format(relative_path),
         {:ok, full_path} <- build_safe_path(workspace_path, relative_path),
         :ok <- check_path_boundaries(full_path, workspace_path),
         :ok <- check_symlinks(full_path, workspace_path) do
      {:ok, full_path}
    end
  end

  defp validate_relative_path_format(path) do
    cond do
      String.contains?(path, "\0") ->
        {:error, :invalid_path_null_byte}

      String.starts_with?(path, "/") ->
        {:error, :absolute_path_not_allowed}

      String.contains?(path, "..") ->
        {:error, :path_traversal_attempt}

      String.length(path) > 4096 ->
        {:error, :path_too_long}

      true ->
        :ok
    end
  end

  defp build_safe_path(workspace_path, relative_path) do
    full_path = Path.join(workspace_path, relative_path)
    absolute_full = Path.expand(full_path)
    {:ok, absolute_full}
  end

  defp check_path_boundaries(full_path, workspace_path) do
    absolute_workspace = Path.expand(workspace_path)

    if String.starts_with?(full_path, absolute_workspace <> "/") or
         full_path == absolute_workspace do
      :ok
    else
      {:error, :path_outside_workspace}
    end
  end

  defp check_symlinks(full_path, workspace_path) do
    absolute_workspace = Path.expand(workspace_path)

    case resolve_symlinks_in_path(full_path) do
      {:ok, resolved_path} ->
        if String.starts_with?(resolved_path, absolute_workspace <> "/") or
             resolved_path == absolute_workspace do
          :ok
        else
          {:error, :symlink_outside_workspace}
        end

      {:error, :enoent} ->
        # File doesn't exist yet - check parent dirs
        parent_dir = Path.dirname(full_path)

        if parent_dir == full_path do
          :ok
        else
          check_symlinks(parent_dir, workspace_path)
        end

      {:error, _reason} ->
        {:error, :cannot_resolve_symlinks}
    end
  end

  defp resolve_symlinks_in_path(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        # It's a symlink - resolve it
        case File.read_link(path) do
          {:ok, resolved} ->
            # Make it absolute if it's relative
            resolved_path =
              if String.starts_with?(resolved, "/") do
                resolved
              else
                Path.expand(resolved, Path.dirname(path))
              end

            {:ok, resolved_path}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _} ->
        # Not a symlink - return as is
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_parent_dir(full_path) do
    parent = Path.dirname(full_path)

    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Private Functions - File Tree

  defp build_file_tree(base_path, current_path) do
    case File.ls(current_path) do
      {:ok, entries} ->
        tree =
          Enum.reduce(entries, %{}, fn entry, acc ->
            entry_path = Path.join(current_path, entry)

            case File.stat(entry_path) do
              {:ok, %File.Stat{type: :directory}} ->
                case build_file_tree(base_path, entry_path) do
                  {:ok, subtree} -> Map.put(acc, entry, subtree)
                  {:error, _} -> acc
                end

              {:ok, %File.Stat{type: :regular}} ->
                Map.put(acc, entry, :file)

              _ ->
                acc
            end
          end)

        {:ok, tree}

      {:error, :enoent} ->
        {:error, :workspace_not_found}

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  # Private Functions - Registry

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {__MODULE__, task_id}}}
  end
end
