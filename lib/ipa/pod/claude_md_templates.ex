defmodule Ipa.Pod.ClaudeMdTemplates do
  @moduledoc """
  CLAUDE.md Template System - Generates contextual instruction files at multiple levels.

  This module provides a hierarchical system of instructions from system-wide conventions
  down to specific workstream details. It uses EEx (Embedded Elixir) templates to render
  CLAUDE.md files with dynamic context.

  ## Three-Level Hierarchy

  1. **System-Level** (Static) - Overall IPA architecture and conventions
  2. **Pod-Level** (Task Context) - Task-specific information
  3. **Workstream-Level** (Workstream Context) - Full context hierarchy

  ## Usage

      # Get system-level template (static)
      {:ok, content} = ClaudeMdTemplates.get_system_level()

      # Generate pod-level template with task context
      {:ok, content} = ClaudeMdTemplates.generate_pod_level(task_id)

      # Generate workstream-level template with full context
      {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, workstream_id)

  ## Dependencies

  - Ipa.Pod.Manager - To query task and workstream state
  - EEx - For template rendering

  ## Configuration

  Templates are stored in `priv/claude_md_templates/`:
  - `system_level.md.eex` - Static system template
  - `pod_level.md.eex` - Pod template with task variables
  - `workstream_level.md.eex` - Workstream template with full context
  """

  require Logger

  @type task_id :: String.t()
  @type workstream_id :: String.t()
  @type content :: String.t()

  # Template paths
  @templates_dir "priv/claude_md_templates"
  @system_template "system_level.md.eex"
  @pod_template "pod_level.md.eex"
  @workstream_template "workstream_level.md.eex"

  # Cache for system-level template (static, loaded once)
  @system_template_cache_key :claude_md_system_template

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Returns the static system-level CLAUDE.md content.

  The system-level template contains IPA architecture, conventions, and common commands.
  This is a static template with no variables.

  ## Returns

  - `{:ok, content}` - System-level CLAUDE.md content as string
  - `{:error, :template_not_found}` - System template file is missing
  - `{:error, reason}` - File read error

  ## Examples

      {:ok, content} = Ipa.Pod.ClaudeMdTemplates.get_system_level()
      # Returns: "# IPA System Context\\n\\n## Architecture\\n..."
  """
  @spec get_system_level() :: {:ok, content()} | {:error, term()}
  def get_system_level do
    # Check cache first
    case :persistent_term.get(@system_template_cache_key, nil) do
      nil ->
        # Load and cache
        case load_template(@system_template) do
          {:ok, content} ->
            :persistent_term.put(@system_template_cache_key, content)
            {:ok, content}

          error ->
            error
        end

      cached_content ->
        {:ok, cached_content}
    end
  end

  @doc """
  Generates pod-level CLAUDE.md with task context.

  The pod-level template includes task title, spec, phase, repository info,
  and an overview of all workstreams.

  ## Parameters

  - `task_id` - Task UUID
  - `opts` - Optional keyword list:
    - `:task_title` - Override task title from state
    - `:task_spec` - Override task spec from state
    - `:repo_url` - Git repository URL (default: from config)
    - `:branch` - Git branch (default: "main")

  ## Returns

  - `{:ok, content}` - Generated CLAUDE.md content
  - `{:error, :task_not_found}` - Task doesn't exist in Pod State
  - `{:error, :template_not_found}` - Pod template file is missing
  - `{:error, reason}` - Template rendering error

  ## Examples

      {:ok, content} = ClaudeMdTemplates.generate_pod_level(
        "task-123",
        repo_url: "git@github.com:xorvo/ipa.git",
        branch: "feature/auth"
      )
  """
  @spec generate_pod_level(task_id(), keyword()) :: {:ok, content()} | {:error, term()}
  def generate_pod_level(task_id, opts \\ []) do
    with {:ok, task_state} <- Ipa.Pod.Manager.get_state(task_id),
         {:ok, template} <- load_template(@pod_template) do
      # Build context from task state and opts
      context = build_pod_context(task_state, opts)

      # Render template
      try do
        rendered = EEx.eval_string(template, assigns: context)
        {:ok, rendered}
      rescue
        error ->
          Logger.error("Template rendering failed",
            error: inspect(error),
            task_id: task_id
          )

          {:error, {:rendering_failed, error}}
      end
    end
  end

  @doc """
  Generates workstream-level CLAUDE.md with full context hierarchy.

  The workstream-level template includes all pod-level context plus specific
  workstream details, dependencies, and related workstreams.

  ## Parameters

  - `task_id` - Task UUID
  - `workstream_id` - Workstream UUID
  - `opts` - Optional keyword list:
    - `:workstream_spec` - Override workstream spec from state
    - `:dependencies` - Override dependencies from state
    - `:repo_url` - Git repository URL (default: from config)
    - `:branch` - Git branch (default: "main")

  ## Returns

  - `{:ok, content}` - Generated CLAUDE.md content
  - `{:error, :task_not_found}` - Task doesn't exist
  - `{:error, :workstream_not_found}` - Workstream doesn't exist
  - `{:error, :template_not_found}` - Workstream template file is missing
  - `{:error, reason}` - Template rendering error

  ## Examples

      {:ok, content} = ClaudeMdTemplates.generate_workstream_level(
        "task-123",
        "ws-1"
      )
  """
  @spec generate_workstream_level(task_id(), workstream_id(), keyword()) ::
          {:ok, content()} | {:error, term()}
  def generate_workstream_level(task_id, workstream_id, opts \\ []) do
    with {:ok, task_state} <- Ipa.Pod.Manager.get_state(task_id),
         {:ok, workstream} <- get_workstream_from_state(task_state, workstream_id),
         {:ok, template} <- load_template(@workstream_template) do
      # Build context from task state, workstream, and opts
      context = build_workstream_context(task_id, task_state, workstream, opts)

      # Render template
      try do
        rendered = EEx.eval_string(template, assigns: context)
        {:ok, rendered}
      rescue
        error ->
          Logger.error("Template rendering failed",
            error: inspect(error),
            task_id: task_id,
            workstream_id: workstream_id
          )

          {:error, {:rendering_failed, error}}
      end
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Load template file from priv directory
  defp load_template(template_name) do
    path = Path.join([@templates_dir, template_name])

    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        Logger.error("Template not found", path: path)
        {:error, :template_not_found}

      {:error, reason} ->
        Logger.error("Failed to read template", path: path, reason: inspect(reason))
        {:error, reason}
    end
  end

  # Build context map for pod-level template
  defp build_pod_context(task_state, opts) do
    # Extract workstreams from state (map to list)
    workstreams =
      (task_state.workstreams || %{})
      |> Map.values()
      |> Enum.map(fn ws ->
        %{
          id: ws.workstream_id,
          title: Map.get(ws, :title, ws.workstream_id),
          status: ws.status,
          spec: ws.spec || "No specification provided",
          dependencies: ws.dependencies || []
        }
      end)
      |> Enum.sort_by(& &1.id)

    %{
      task_id: task_state.task_id,
      task_title: opts[:task_title] || task_state.title,
      task_spec: opts[:task_spec] || format_task_spec(task_state.spec),
      task_phase: task_state.phase,
      repo_url: opts[:repo_url] || get_repo_url_from_config(),
      branch: opts[:branch] || "main",
      workstreams: workstreams
    }
  end

  # Build context map for workstream-level template
  defp build_workstream_context(task_id, task_state, workstream, opts) do
    # Get all workstreams except the current one
    related_workstreams =
      (task_state.workstreams || %{})
      |> Map.values()
      |> Enum.reject(fn ws -> ws.workstream_id == workstream.workstream_id end)
      |> Enum.map(fn ws ->
        %{
          id: ws.workstream_id,
          title: Map.get(ws, :title, ws.workstream_id),
          status: ws.status,
          spec: ws.spec || "No specification provided",
          dependencies: ws.dependencies || []
        }
      end)
      |> Enum.sort_by(& &1.id)

    # Find workstreams that depend on this workstream
    dependent_workstreams =
      related_workstreams
      |> Enum.filter(fn ws ->
        workstream.workstream_id in (ws.dependencies || [])
      end)

    %{
      task_id: task_id,
      task_title: task_state.title,
      task_spec: format_task_spec(task_state.spec),
      task_phase: task_state.phase,
      workstream_id: workstream.workstream_id,
      workstream_title: Map.get(workstream, :title, workstream.workstream_id),
      workstream_status: workstream.status,
      workstream_spec: opts[:workstream_spec] || workstream.spec || "No specification provided",
      estimated_hours: Map.get(workstream, :estimated_hours, 0),
      dependencies: opts[:dependencies] || workstream.dependencies || [],
      related_workstreams: related_workstreams,
      dependent_workstreams: dependent_workstreams,
      repo_url: opts[:repo_url] || get_repo_url_from_config(),
      branch: opts[:branch] || "main"
    }
  end

  # Extract workstream from task state
  defp get_workstream_from_state(task_state, workstream_id) do
    case Map.get(task_state.workstreams || %{}, workstream_id) do
      nil ->
        {:error, :workstream_not_found}

      workstream ->
        {:ok, workstream}
    end
  end

  # Format task spec for display
  defp format_task_spec(spec) when is_map(spec) do
    # Try new content field first, then fall back to legacy description
    content = spec[:content] || Map.get(spec, :content)
    description = spec[:description] || Map.get(spec, :description)

    cond do
      content && content != "" -> content
      description && description != "" -> description
      true -> "No detailed specification provided"
    end
  end

  defp format_task_spec(_), do: "No detailed specification provided"

  # Get repository URL from application config
  defp get_repo_url_from_config do
    Application.get_env(:ipa, :repo_url, "git@github.com:xorvo/ipa.git")
  end
end
