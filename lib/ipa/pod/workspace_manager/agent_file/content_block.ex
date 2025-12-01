defmodule Ipa.Pod.WorkspaceManager.AgentFile.ContentBlock do
  @moduledoc """
  Predefined content blocks for CLAUDE.md/AGENT.md files.

  Blocks can be selected during workspace creation to compose agent instruction files.
  Each block provides context for a specific aspect of the task or project.

  ## Usage

      # Get available blocks
      ContentBlock.available_blocks()
      #=> [:project_context, :task_context, :workstream_context, ...]

      # Compose agent file from selected blocks
      content = ContentBlock.compose(
        [:project_context, :task_context],
        %{task_title: "Build auth system", task_spec: "..."}
      )

      # Get a single block
      block = ContentBlock.get_block(:code_guidelines)
  """

  @type block_id ::
          :workspace_rules
          | :project_context
          | :task_context
          | :workstream_context
          | :code_guidelines
          | :testing_guidelines
          | :git_workflow

  @type variables :: %{
          optional(:task_id) => String.t(),
          optional(:task_title) => String.t(),
          optional(:task_spec) => String.t(),
          optional(:workstream_id) => String.t(),
          optional(:workstream_title) => String.t(),
          optional(:workstream_spec) => String.t(),
          optional(:workstream_dependencies) => [String.t()],
          optional(:workspace_path) => String.t()
        }

  @doc """
  Returns the list of all available content block IDs.
  """
  @spec available_blocks() :: [block_id()]
  def available_blocks do
    [
      :workspace_rules,
      :project_context,
      :task_context,
      :workstream_context,
      :code_guidelines,
      :testing_guidelines,
      :git_workflow
    ]
  end

  @doc """
  Returns the content for a specific block ID.
  """
  @spec get_block(block_id()) :: String.t()
  def get_block(:workspace_rules) do
    """
    # Workspace Rules

    **CRITICAL**: You are working in an isolated workspace directory.

    ## Your Workspace
    Your working directory is: `{{workspace_path}}`

    ## File Operations
    - **ALL** file operations MUST use paths relative to this workspace
    - Use `./` prefix for relative paths (e.g., `./src/`, `./output/`)
    - NEVER write to `/tmp/` or any directory outside your workspace
    - NEVER use absolute paths unless they start with your workspace path

    ## Why This Matters
    - Your workspace is isolated for safety and reproducibility
    - Files written outside your workspace will be lost or cause conflicts
    - Other agents have their own workspaces and cannot see yours

    ## Examples
    ```bash
    # CORRECT - relative to workspace
    mkdir -p ./work/src
    echo "content" > ./output/result.txt

    # WRONG - writing outside workspace
    mkdir -p /tmp/work       # DO NOT DO THIS
    echo "content" > /var/tmp/result.txt  # DO NOT DO THIS
    ```
    """
  end

  def get_block(:project_context) do
    """
    # IPA Project Context

    IPA (Intelligent Process Automation) is a pod-based task management system built with Elixir/Phoenix LiveView.

    ## Tech Stack
    - **Backend**: Elixir/Phoenix with LiveView
    - **State Management**: Event Sourcing with custom implementation
    - **Persistence**: PostgreSQL with JSON events via Ecto
    - **Agent Runtime**: Claude Agent SDK TypeScript wrapper for Elixir

    ## Key Concepts
    - **Tasks**: Top-level work items that create pods
    - **Pods**: Isolated supervisor trees managing task lifecycle
    - **Workstreams**: Parallel units of work within a pod
    - **Workspaces**: Isolated filesystems for agent execution
    """
  end

  def get_block(:task_context) do
    """
    # Task Context

    Task ID: {{task_id}}
    Title: {{task_title}}

    ## Specification
    {{task_spec}}

    ## Your Role
    You are an AI agent working on this task. Follow the specification above and coordinate with other agents as needed.
    """
  end

  def get_block(:workstream_context) do
    """
    # Workstream Context

    Workstream ID: {{workstream_id}}
    Title: {{workstream_title}}

    ## Specification
    {{workstream_spec}}

    ## Dependencies
    {{workstream_dependencies}}

    ## Your Role
    Focus on completing this workstream. Coordinate with dependent workstreams if needed.
    """
  end

  def get_block(:code_guidelines) do
    """
    # Code Guidelines

    ## Elixir Conventions
    - Use pattern matching and guards over conditionals
    - Prefer pipes for data transformations
    - Use with statements for sequential operations that may fail
    - Follow the "let it crash" philosophy with proper supervision

    ## Phoenix Conventions
    - Keep controllers thin, logic in contexts
    - Use changesets for data validation
    - Leverage LiveView for real-time UI updates

    ## Code Quality
    - Run `mix format` before committing
    - Ensure tests pass with `mix test`
    - Use descriptive function and variable names
    """
  end

  def get_block(:testing_guidelines) do
    """
    # Testing Guidelines

    ## Running Tests
    ```bash
    # Run all tests
    mix test

    # Run specific test file
    mix test test/path/to/test_file.exs

    # Run specific test by line number
    mix test test/path/to/test_file.exs:42
    ```

    ## Test Structure
    - Unit tests for individual functions
    - Integration tests for module interactions
    - Use ExUnit's describe blocks to group related tests
    - Use setup blocks for common test fixtures
    """
  end

  def get_block(:git_workflow) do
    """
    # Git Workflow

    ## Branch Naming
    - Feature branches: `feature/description`
    - Bug fixes: `fix/description`
    - Refactoring: `refactor/description`

    ## Commit Messages
    - Use present tense ("Add feature" not "Added feature")
    - Keep first line under 72 characters
    - Include context in body if needed

    ## Pull Requests
    - Use `gh pr create` to create PRs
    - Include summary of changes
    - Reference related issues
    """
  end

  def get_block(_unknown), do: ""

  @doc """
  Composes an agent file from selected content blocks.

  Blocks are concatenated in the order provided, with variables interpolated.

  ## Parameters
  - `block_ids` - List of block IDs to include
  - `variables` - Map of variable values for interpolation

  ## Example

      ContentBlock.compose(
        [:project_context, :task_context],
        %{task_id: "task-123", task_title: "Build auth", task_spec: "..."}
      )
  """
  @spec compose([block_id()], variables()) :: String.t()
  def compose(block_ids, variables \\ %{}) do
    block_ids
    |> Enum.map(&get_block/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n---\n\n")
    |> interpolate_variables(variables)
  end

  @doc """
  Composes an agent file with default blocks for a base workspace.
  """
  @spec compose_for_base_workspace(variables()) :: String.t()
  def compose_for_base_workspace(variables) do
    compose([:workspace_rules, :project_context, :task_context, :code_guidelines], variables)
  end

  @doc """
  Composes an agent file with default blocks for a sub-workspace.
  """
  @spec compose_for_sub_workspace(variables()) :: String.t()
  def compose_for_sub_workspace(variables) do
    compose(
      [:workspace_rules, :project_context, :task_context, :workstream_context, :code_guidelines, :git_workflow],
      variables
    )
  end

  @doc """
  Composes an agent file for a spec generator workspace.
  Only includes workspace rules since the agent prompt contains all the spec-specific instructions.
  """
  @spec compose_for_spec_generator(variables()) :: String.t()
  def compose_for_spec_generator(variables) do
    compose([:workspace_rules, :project_context, :task_context], variables)
  end

  # Private functions

  defp interpolate_variables(content, variables) do
    Enum.reduce(variables, content, fn {key, value}, acc ->
      placeholder = "{{#{key}}}"
      replacement = format_value(value)
      String.replace(acc, placeholder, replacement)
    end)
  end

  defp format_value(nil), do: "N/A"
  defp format_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
