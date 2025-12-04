defmodule Ipa.Agent.MdFile do
  @moduledoc """
  Agent-specific CLAUDE.md generation using composable EEx blocks.

  Each block is an EEx template that receives a context map.
  Blocks can be composed in any order for different agent types.

  ## Usage

      # Generate CLAUDE.md for a workstream agent
      {:ok, content} = MdFile.for_workstream(state, "ws-1")

      # Generate CLAUDE.md for a planning agent
      {:ok, content} = MdFile.for_planning(state)

      # Compose custom blocks
      context = MdFile.build_workstream_context(state, workstream, [])
      content = MdFile.compose([:workspace_rules, :task_context], context)
  """

  require Logger

  @type block_id ::
          :workspace_rules
          | :workstream_spec
          | :dependencies
          | :tracker_items
          | :related_workstreams
          | :dependent_workstreams
          | :task_context
          | :workflow_instructions
          | :success_criteria
          | :code_guidelines
          | :git_workflow
          | :planning_instructions

  # ============================================================================
  # High-Level API (used by Manager)
  # ============================================================================

  @doc """
  Generate CLAUDE.md for workstream agent from state.

  This is the primary function for generating workstream agent instructions.
  It composes all relevant blocks with full context from the task state.
  """
  @spec for_workstream(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def for_workstream(state, workstream_id, opts \\ []) do
    with {:ok, workstream} <- get_workstream_from_state(state, workstream_id) do
      context = build_workstream_context(state, workstream, opts)

      content =
        compose(
          [
            :workstream_spec,
            :dependencies,
            :tracker_items,
            :task_context,
            :workflow_instructions,
            :related_workstreams,
            :dependent_workstreams,
            :success_criteria
          ],
          context
        )

      {:ok, content}
    end
  rescue
    error ->
      Logger.error("MdFile rendering failed",
        error: inspect(error),
        workstream_id: workstream_id
      )

      {:error, {:rendering_failed, error}}
  end

  @doc """
  Generate CLAUDE.md for planning agent from state.
  """
  @spec for_planning(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def for_planning(state, opts \\ []) do
    context = build_planning_context(state, opts)

    content =
      compose(
        [
          :workspace_rules,
          :task_context,
          :planning_instructions,
          :code_guidelines
        ],
        context
      )

    {:ok, content}
  rescue
    error ->
      Logger.error("MdFile rendering failed for planning", error: inspect(error))
      {:error, {:rendering_failed, error}}
  end

  @doc """
  Generate CLAUDE.md for spec generator from state.
  """
  @spec for_spec_generator(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def for_spec_generator(state, opts \\ []) do
    context = build_planning_context(state, opts)

    content =
      compose(
        [
          :workspace_rules,
          :task_context
        ],
        context
      )

    {:ok, content}
  rescue
    error ->
      Logger.error("MdFile rendering failed for spec generator", error: inspect(error))
      {:error, {:rendering_failed, error}}
  end

  # ============================================================================
  # Block Composition
  # ============================================================================

  @doc """
  Compose multiple blocks with context.

  Renders each block with EEx and joins them with separators.
  """
  @spec compose([block_id()], map()) :: String.t()
  def compose(block_ids, context) do
    block_ids
    |> Enum.map(&render(&1, context))
    |> Enum.reject(&(&1 == "" or &1 == nil))
    |> Enum.join("\n")
  end

  @doc """
  Render a single block with EEx.
  """
  @spec render(block_id(), map()) :: String.t()
  def render(block_id, context) do
    template = get_template(block_id)
    EEx.eval_string(template, assigns: context)
  rescue
    error ->
      Logger.warning("Failed to render block #{block_id}: #{inspect(error)}")
      ""
  end

  # ============================================================================
  # Context Building
  # ============================================================================

  @doc """
  Build context for workstream agent.
  """
  @spec build_workstream_context(map(), map(), keyword()) :: map()
  def build_workstream_context(state, workstream, opts) do
    # Get all workstreams except the current one
    related_workstreams =
      (state.workstreams || %{})
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

    # Get tracker items assigned to this workstream
    tracker_items = get_tracker_items_for_workstream(state, workstream.workstream_id)

    %{
      task_id: state.task_id,
      task_title: state.title,
      task_spec: format_task_spec(state.spec),
      task_phase: state.phase,
      workstream_id: workstream.workstream_id,
      workstream_title: Map.get(workstream, :title, workstream.workstream_id),
      workstream_status: workstream.status,
      workstream_spec: opts[:workstream_spec] || workstream.spec || "No specification provided",
      estimated_hours: Map.get(workstream, :estimated_hours, 0),
      dependencies: opts[:dependencies] || workstream.dependencies || [],
      related_workstreams: related_workstreams,
      dependent_workstreams: dependent_workstreams,
      tracker_items: tracker_items,
      repo_url: opts[:repo_url] || get_repo_url_from_state(state),
      branch: opts[:branch] || get_branch_from_state(state),
      # Only show repo info if a repo URL is configured for this task
      show_repo_info: opts[:show_repo_info] != false && get_repo_url_from_state(state) != nil
    }
  end

  @doc """
  Build context for planning agent.
  """
  @spec build_planning_context(map(), keyword()) :: map()
  def build_planning_context(state, opts) do
    workstreams =
      (state.workstreams || %{})
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
      task_id: state.task_id,
      task_title: opts[:task_title] || state.title,
      task_spec: opts[:task_spec] || format_task_spec(state.spec),
      task_phase: state.phase,
      workstreams: workstreams,
      repo_url: opts[:repo_url] || get_repo_url_from_state(state),
      branch: opts[:branch] || get_branch_from_state(state),
      # Planning/spec agents don't need repo info in their context
      show_repo_info: opts[:show_repo_info] || false
    }
  end

  # ============================================================================
  # Block Templates (EEx)
  # ============================================================================

  @spec get_template(block_id()) :: String.t()
  def get_template(:workspace_rules) do
    ~S"""
    ---

    ## Workspace Rules (CRITICAL)

    **You are working in an isolated workspace directory.**

    ### File Operations - MUST FOLLOW

    - **ALL file operations MUST use paths relative to your current working directory**
    - Use `./` prefix for relative paths (e.g., `./src/`, `./output/`, `./work/`)
    - **NEVER write to `/tmp/` or any directory outside your workspace**
    - **NEVER use absolute paths** unless they start with your workspace path
    - Your completion marker `WORKSTREAM_COMPLETE.md` MUST be in the workspace root (use `./WORKSTREAM_COMPLETE.md`)

    ### Why This Matters

    - Your workspace is isolated for safety and reproducibility
    - Files written outside your workspace (like `/tmp/`) will NOT be detected by the system
    - Other agents have their own workspaces and cannot see yours
    - **The system checks YOUR workspace for completion markers, not `/tmp/`**

    ### Examples

    ```bash
    # CORRECT - relative to workspace
    mkdir -p ./work/src
    echo "content" > ./output/result.txt
    echo "Done!" > ./WORKSTREAM_COMPLETE.md

    # WRONG - writing outside workspace (WILL CAUSE FAILURES)
    mkdir -p /tmp/work           # DO NOT DO THIS
    echo "content" > /tmp/result.txt  # DO NOT DO THIS
    echo "Done!" > /tmp/workspace/WORKSTREAM_COMPLETE.md  # DO NOT DO THIS - system won't find it!
    ```
    """
  end

  def get_template(:workstream_spec) do
    ~S"""
    # Workstream Context: <%= @workstream_id %>

    ## Workstream Specification

    <%= @workstream_spec %>

    ## Workstream Details

    - **Workstream ID**: `<%= @workstream_id %>`
    - **Status**: `<%= @workstream_status %>`
    """
  end

  def get_template(:dependencies) do
    ~S"""
    <%= if @dependencies && length(@dependencies) > 0 do %>
    ## Dependencies

    This workstream depends on the following workstreams completing first:

    <%= for dep_id <- @dependencies do %>
    - `<%= dep_id %>`
    <% end %>

    **IMPORTANT**: Do not start work until all dependencies are completed.
    <% else %>
    ## Dependencies

    This workstream has no dependencies and can start immediately.
    <% end %>
    """
  end

  def get_template(:tracker_items) do
    ~S"""
    <%= if @tracker_items && length(@tracker_items) > 0 do %>
    ---

    ## Your Tracker Items (IMPORTANT)

    You are responsible for the following tracker items. **You MUST update their status as you work.**

    <%= for item <- @tracker_items do %>
    - **[<%= item.status %>]** <%= item.summary %> (Phase: <%= item.phase_name %>, ID: `<%= item.item_id %>`)
    <% end %>

    ### How to Update Tracker Items

    Update item status by writing to `tracker_update.json` in the workspace root:

    ```json
    {
      "updates": [
        {"item_id": "<item-id>", "status": "wip"},
        {"item_id": "<item-id>", "status": "done"}
      ]
    }
    ```

    **Status values:**
    - `todo` - Not started
    - `wip` - Work in progress (set this when you START working on an item)
    - `done` - Completed (set this when you FINISH an item)
    - `blocked` - Blocked by external dependency

    ### CRITICAL: Update Tracker Before Finishing

    Before marking your workstream as complete:
    1. Ensure ALL your tracker items are marked as `done`
    2. Write the final `tracker_update.json` with all items set to `done`
    3. Verify each deliverable is actually complete

    **The tracker is how the team tracks progress. Failing to update it leaves everyone in the dark.**
    <% end %>
    """
  end

  def get_template(:related_workstreams) do
    ~S"""
    <%= if @related_workstreams && length(@related_workstreams) > 0 do %>
    ## Related Workstreams

    Other workstreams in this task:

    <%= for ws <- @related_workstreams do %>
    ### `<%= ws.id %>`

    <%= if ws.spec do %><%= ws.spec |> String.slice(0..150) %><%= if String.length(ws.spec || "") > 150 do %>...<% end %><% end %>

    - **Status**: <%= ws.status %>
    <%= if ws.dependencies && length(ws.dependencies) > 0 do %>- **Dependencies**: <%= Enum.join(ws.dependencies, ", ") %><% end %>
    <% end %>
    <% end %>
    """
  end

  def get_template(:dependent_workstreams) do
    ~S"""
    <%= if @dependent_workstreams && length(@dependent_workstreams) > 0 do %>
    ## Dependent Workstreams

    These workstreams are waiting for your completion:

    <%= for ws <- @dependent_workstreams do %>
    - `<%= ws.id %>` (Status: <%= ws.status %>)
    <% end %>
    <% end %>
    """
  end

  def get_template(:task_context) do
    ~S"""
    ---

    ## Task Context: <%= @task_title %>

    ### Task Overview

    <%= if @task_spec && @task_spec != "" && @task_spec != "No detailed specification provided" do %>
    <%= @task_spec |> String.slice(0..500) %><%= if String.length(@task_spec || "") > 500 do %>...<% end %>
    <% else %>
    _Specification not yet created._
    <% end %>

    **Current Phase**: `<%= @task_phase %>`
    <%= if @show_repo_info do %>

    ### Repository

    - **URL**: `<%= @repo_url %>`
    - **Branch**: `<%= @branch %>`
    <% end %>
    """
  end

  def get_template(:workflow_instructions) do
    ~S"""
    ---

    ## Your Role

    You are the **primary agent** for workstream `<%= @workstream_id %>`. Your responsibilities:

    1. **Focus on your workstream**: Complete the work defined in the workstream spec above
    2. **Coordinate with other workstreams**: Be aware of related workstreams and dependencies
    3. **Respect boundaries**: Don't modify code outside your workstream scope
    4. **Communicate progress**: Post updates as you hit milestones
    5. **Ask for help**: Post questions if you're blocked or need clarification

    ## Workflow

    1. **Read the workstream spec** (above) carefully
    2. **Check dependencies**: Ensure all dependent workstreams are completed
    3. **Plan your approach**: Break down the work into steps
    4. **Implement**: Write code, following the spec
    5. **Test**: Run tests to verify correctness
    6. **Communicate**: Share updates and blockers
    7. **Complete**: Mark workstream as complete when done

    ## Communication

    Post messages to the pod's communication system:

    - **Questions**: `{:question, "What approach should I take for X?"}`
    - **Updates**: `{:update, "Completed API implementation, starting tests"}`
    - **Blockers**: `{:blocker, "Need approval on database schema changes"}`
    - **Approvals**: Request approval for major decisions

    All messages are threaded and visible to humans and other agents in this pod.

    ## Testing

    ```bash
    # Run all tests
    mix test

    # Run tests for your component
    mix test test/path/to/your_component_test.exs

    # Run a specific test
    mix test test/path/to/your_component_test.exs:42
    ```

    ## Workspace

    Your isolated workspace contains:
    - A clone of the repository at branch `<%= @branch %>`
    - This CLAUDE.md file with full context
    - All project files and dependencies

    Any changes you make can be committed and pushed to the repository.

    ## Coordination Points

    <%= if @dependencies && length(@dependencies) > 0 do %>
    **Before starting**: Verify dependent workstreams are complete:
    <%= for dep_id <- @dependencies do %>
    - Check status of `<%= dep_id %>`
    <% end %>
    <% end %>

    <%= if @related_workstreams && length(@related_workstreams) > 0 do %>
    **Awareness**: Other agents are working on related workstreams:
    <%= for ws <- @related_workstreams do %>
    - `<%= ws.id %>`
    <% end %>

    If you need to coordinate, use the communication system to post messages.
    <% end %>
    """
  end

  def get_template(:success_criteria) do
    ~S"""
    ---

    ## Success Criteria

    Complete this workstream when:
    1. The workstream spec requirements are fully implemented
    2. All tests pass
    3. Code follows project conventions
    4. Changes are committed to git
    5. **All tracker items are marked as `done`** (write `tracker_update.json`)
    6. Status is updated to `:completed`

    Mark the workstream as complete by posting a completion update with evidence (test results, commit hash, etc.).
    """
  end

  def get_template(:code_guidelines) do
    ~S"""
    ---

    ## Code Guidelines

    ### Elixir Conventions
    - Use pattern matching and guards over conditionals
    - Prefer pipes for data transformations
    - Use with statements for sequential operations that may fail
    - Follow the "let it crash" philosophy with proper supervision

    ### Phoenix Conventions
    - Keep controllers thin, logic in contexts
    - Use changesets for data validation
    - Leverage LiveView for real-time UI updates

    ### Code Quality
    - Run `mix format` before committing
    - Ensure tests pass with `mix test`
    - Use descriptive function and variable names
    """
  end

  def get_template(:git_workflow) do
    ~S"""
    ---

    ## Git Workflow

    ### Branch Naming
    - Feature branches: `feature/description`
    - Bug fixes: `fix/description`
    - Refactoring: `refactor/description`

    ### Commit Messages
    - Use present tense ("Add feature" not "Added feature")
    - Keep first line under 72 characters
    - Include context in body if needed

    ### Pull Requests
    - Use `gh pr create` to create PRs
    - Include summary of changes
    - Reference related issues
    """
  end

  def get_template(:planning_instructions) do
    ~S"""
    ---

    ## Planning Instructions

    You are a planning agent responsible for breaking down tasks into workstreams.

    ### Your Responsibilities

    1. **Analyze the task**: Understand the full scope and requirements
    2. **Identify workstreams**: Break into logical, parallelizable units
    3. **Define dependencies**: Which workstreams depend on others
    4. **Estimate effort**: Rough sizing for each workstream
    5. **Create specs**: Detailed specifications for each workstream

    ### Workstream Guidelines

    - Each workstream should be independently implementable
    - Keep workstreams focused (single responsibility)
    - Minimize dependencies between workstreams
    - Include clear acceptance criteria in each spec
    """
  end

  def get_template(_unknown), do: ""

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_workstream_from_state(state, workstream_id) do
    case Map.get(state.workstreams || %{}, workstream_id) do
      nil -> {:error, :workstream_not_found}
      workstream -> {:ok, workstream}
    end
  end

  defp get_tracker_items_for_workstream(state, workstream_id) do
    case state.tracker do
      nil ->
        []

      tracker ->
        tracker.phases
        |> Enum.flat_map(fn phase ->
          phase.items
          |> Enum.filter(fn item -> item.workstream_id == workstream_id end)
          |> Enum.map(fn item ->
            %{
              item_id: item.item_id,
              phase_name: phase.name,
              summary: item.summary,
              status: item.status
            }
          end)
        end)
    end
  end

  defp format_task_spec(spec) when is_map(spec) do
    content = spec[:content] || Map.get(spec, :content)
    description = spec[:description] || Map.get(spec, :description)

    cond do
      content && content != "" -> content
      description && description != "" -> description
      true -> "No detailed specification provided"
    end
  end

  defp format_task_spec(spec) when is_binary(spec), do: spec
  defp format_task_spec(_), do: "No detailed specification provided"

  defp get_repo_url_from_state(state) do
    get_in(state, [:config, :repo_url])
  end

  defp get_branch_from_state(state) do
    get_in(state, [:config, :branch]) || "main"
  end

  # ============================================================================
  # Introspection API
  # ============================================================================

  @doc """
  Returns the list of all available content block IDs.
  """
  @spec available_blocks() :: [block_id()]
  def available_blocks do
    [
      :workspace_rules,
      :workstream_spec,
      :dependencies,
      :tracker_items,
      :related_workstreams,
      :dependent_workstreams,
      :task_context,
      :workflow_instructions,
      :success_criteria,
      :code_guidelines,
      :git_workflow,
      :planning_instructions
    ]
  end

  @doc """
  Returns the raw EEx template for a specific block ID.
  Alias for get_template/1.
  """
  @spec get_block(block_id()) :: String.t()
  def get_block(block_id), do: get_template(block_id)
end
