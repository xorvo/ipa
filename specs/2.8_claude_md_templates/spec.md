# Component Spec: 2.8 CLAUDE.md Template System

**Status**: Spec Complete (Ready for Review)
**Dependencies**: 2.2 (Pod State Manager)
**Estimated Effort**: 1 week

## Overview

The CLAUDE.md Template System generates contextual instruction files at multiple levels to ensure agents have appropriate context when executing tasks. It provides a hierarchical system of instructions from system-wide conventions down to specific workstream details.

## Purpose

- Provide system-level conventions and architecture documentation to all agents
- Inject task-specific context into pod-level CLAUDE.md files
- Generate workstream-specific CLAUDE.md files with relevant context
- Ensure agents understand the IPA system, their task, and their workstream
- Maintain consistency across all generated CLAUDE.md files

## Dependencies

- **External**: Elixir EEx (Embedded Elixir templating)
- **Internal**: Ipa.Pod.State (to query task/workstream state)
- **Used By**: Ipa.Pod.Scheduler, Ipa.Pod.WorkspaceManager

## Module Structure

```
lib/ipa/pod/
  └── claude_md_templates.ex        # Main template generator module

priv/claude_md_templates/
  ├── system_level.md.eex            # Static system-level template
  ├── pod_level.md.eex               # Pod-level template (with task context)
  └── workstream_level.md.eex        # Workstream-level template
```

## Core Concepts

### Three-Level Hierarchy

**1. System-Level** (Static)
- Overall IPA architecture and design patterns
- Spec-driven development workflow
- Event sourcing concepts
- Pod, workstream, and communications concepts
- Common Elixir/Phoenix commands
- Testing strategy

**2. Pod-Level** (Task Context)
- Task title and description
- Task spec and requirements
- Project repository information
- Related workstreams (overview)
- Task phase and status

**3. Workstream-Level** (Workstream Context)
- Includes pod-level context
- Workstream-specific spec
- Workstream dependencies
- Related workstreams (detailed)
- Workstream's role in the larger task

### Template Rendering Flow

```
1. Pod Scheduler creates workstream
2. Scheduler calls ClaudeMdTemplates.generate_workstream_level()
3. Template system queries Pod State for context
4. Template system renders EEx template with context
5. Returns generated CLAUDE.md content as string
6. Scheduler passes content to WorkspaceManager
7. WorkspaceManager writes CLAUDE.md to workspace
```

## API Specification

### Public Functions

#### `get_system_level/0`

```elixir
@spec get_system_level() :: {:ok, content :: String.t()} | {:error, term()}
```

Returns the static system-level CLAUDE.md content.

**Returns**:
- `{:ok, content}` - System-level CLAUDE.md content as string
- `{:error, :template_not_found}` - System template file is missing
- `{:error, reason}` - File read error

**Example**:
```elixir
{:ok, content} = Ipa.Pod.ClaudeMdTemplates.get_system_level()
# Returns: "# IPA System Context\n\n## Architecture\n..."
```

**Implementation**:
- Reads static file from `priv/claude_md_templates/system_level.md.eex`
- No template variables (static content)
- Cached in memory after first read

#### `generate_pod_level/2`

```elixir
@spec generate_pod_level(
  task_id :: String.t(),
  opts :: keyword()
) :: {:ok, content :: String.t()} | {:error, term()}
```

Generates pod-level CLAUDE.md with task context.

**Parameters**:
- `task_id` - Task UUID
- `opts` - Optional overrides:
  - `task_title` - Override task title from state
  - `task_spec` - Override task spec from state
  - `repo_url` - Git repository URL (default: from config)
  - `branch` - Git branch (default: "main")

**Returns**:
- `{:ok, content}` - Generated CLAUDE.md content
- `{:error, :task_not_found}` - Task doesn't exist in Pod State
- `{:error, :template_not_found}` - Pod template file is missing
- `{:error, reason}` - Template rendering error

**Example**:
```elixir
{:ok, content} = Ipa.Pod.ClaudeMdTemplates.generate_pod_level(
  task_id,
  repo_url: "git@github.com:xorvo/ipa.git",
  branch: "feature/auth"
)
```

**Behavior**:
1. Queries `Ipa.Pod.State.get_state(task_id)` for task context
2. Merges state data with opts (opts take precedence)
3. Renders `pod_level.md.eex` template with context
4. Returns rendered content

#### `generate_workstream_level/3`

```elixir
@spec generate_workstream_level(
  task_id :: String.t(),
  workstream_id :: String.t(),
  opts :: keyword()
) :: {:ok, content :: String.t()} | {:error, term()}
```

Generates workstream-level CLAUDE.md with full context hierarchy.

**Parameters**:
- `task_id` - Task UUID
- `workstream_id` - Workstream UUID
- `opts` - Optional overrides:
  - `workstream_spec` - Override workstream spec from state
  - `dependencies` - Override dependencies from state
  - `repo_url` - Git repository URL
  - `branch` - Git branch

**Returns**:
- `{:ok, content}` - Generated CLAUDE.md content
- `{:error, :task_not_found}` - Task doesn't exist
- `{:error, :workstream_not_found}` - Workstream doesn't exist
- `{:error, :template_not_found}` - Workstream template file is missing
- `{:error, reason}` - Template rendering error

**Example**:
```elixir
{:ok, content} = Ipa.Pod.ClaudeMdTemplates.generate_workstream_level(
  task_id,
  "ws-1"
)
```

**Behavior**:
1. Queries `Ipa.Pod.State.get_state(task_id)` for task context
2. Queries `Ipa.Pod.State.get_workstream(task_id, workstream_id)` for workstream context
3. Queries other workstreams to build related_workstreams list
4. Merges all context with opts (opts take precedence)
5. Renders `workstream_level.md.eex` template with context
6. Returns rendered content

## Template Structure

### System-Level Template (`system_level.md.eex`)

This is a static file with no variables. Contains:

- IPA architecture overview
- Pod, workstream, and communications concepts
- Spec-driven development workflow
- Event sourcing patterns
- Common Elixir/Phoenix/Git commands
- Testing strategy
- IMPORTANT: Spec-driven development process
- IMPORTANT: File organization (specs/, tracker.md, review.md)

**Example Structure**:
```markdown
# IPA System Context

This file provides context about the IPA (Intelligent Process Automation) system.

## Architecture

IPA uses a pod-based architecture where each task runs in an isolated pod...

## Workstreams

Tasks are broken down into multiple workstreams that can be worked on in parallel...

## Communications

Agents and humans coordinate via a structured messaging system...

## Development Workflow

1. Spec: Write detailed specification
2. Review: Get spec reviewed
3. Code: Implement the component
4. Test: Test locally
5. Review: Code review
6. PR: Create pull request
7. Merge: After approval

## Common Commands

\`\`\`bash
# Run tests
mix test

# Start server
mix phx.server
\`\`\`

...
```

### Pod-Level Template (`pod_level.md.eex`)

Variables available:
- `<%= @task_title %>` - Task title
- `<%= @task_spec %>` - Task specification
- `<%= @task_phase %>` - Current task phase
- `<%= @repo_url %>` - Git repository URL
- `<%= @branch %>` - Git branch
- `<%= @workstream_count %>` - Number of workstreams
- `<%= @workstream_list %>` - List of workstream IDs and titles

**Example Structure**:
```markdown
# Task Context: <%= @task_title %>

## Task Overview

<%= @task_spec %>

**Current Phase**: <%= @task_phase %>

## Repository

- **URL**: <%= @repo_url %>
- **Branch**: <%= @branch %>

## Workstreams

This task has been broken down into <%= @workstream_count %> workstreams:

<%= for {ws_id, ws} <- @workstream_list do %>
- **<%= ws_id %>**: <%= ws.spec |> String.slice(0, 100) %>
<% end %>

## Your Role

You are working on this task. Follow the spec-driven development process...

## Important Files

- `specs/` - Specifications for all components
- `STATUS.md` - Project status tracker

...
```

### Workstream-Level Template (`workstream_level.md.eex`)

Variables available:
- All pod-level variables
- `<%= @workstream_id %>` - Workstream UUID
- `<%= @workstream_spec %>` - Workstream specification
- `<%= @workstream_dependencies %>` - List of dependency workstream IDs
- `<%= @related_workstreams %>` - Other workstreams in the task
- `<%= @workspace_path %>` - Workspace directory path

**Example Structure**:
```markdown
# Workstream Context: <%= @workstream_id %>

## Task: <%= @task_title %>

<%= @task_spec %>

## Your Workstream

**ID**: <%= @workstream_id %>
**Workspace**: <%= @workspace_path %>

### Specification

<%= @workstream_spec %>

### Dependencies

<%= if Enum.empty?(@workstream_dependencies) do %>
This workstream has no dependencies. You can start immediately.
<% else %>
This workstream depends on:
<%= for dep_id <- @workstream_dependencies do %>
- **<%= dep_id %>**: Must complete before you can proceed
<% end %>
<% end %>

## Related Workstreams

<%= for {ws_id, ws} <- @related_workstreams do %>
### <%= ws_id %>
<%= ws.spec |> String.slice(0, 200) %>
Status: <%= ws.status %>
<% end %>

## Your Responsibilities

1. Follow the specification above
2. Update `specs/<workstream>/tracker.md` with your progress
3. Use the Communications Manager to ask questions or report blockers
4. Create PRs when ready for review

## File Organization

Your workspace is at: <%= @workspace_path %>

Important files:
- `specs/<workstream>/spec.md` - Your detailed specification
- `specs/<workstream>/tracker.md` - Track your todos and progress
- `CLAUDE.md` - This file (system context)

...
```

## Context Data Structure

### Pod-Level Context

```elixir
%{
  task_title: String.t(),
  task_spec: String.t(),
  task_phase: atom(),
  repo_url: String.t(),
  branch: String.t(),
  workstream_count: integer(),
  workstream_list: [
    {workstream_id, %{spec: String.t(), status: atom()}}
  ]
}
```

### Workstream-Level Context

```elixir
%{
  # Pod-level context (inherited)
  task_title: String.t(),
  task_spec: String.t(),
  task_phase: atom(),
  repo_url: String.t(),
  branch: String.t(),
  workstream_count: integer(),
  workstream_list: [...],

  # Workstream-specific context
  workstream_id: String.t(),
  workstream_spec: String.t(),
  workstream_dependencies: [String.t()],
  related_workstreams: [
    {workstream_id, %{
      spec: String.t(),
      status: atom(),
      dependencies: [String.t()]
    }}
  ],
  workspace_path: String.t()
}
```

## Implementation Details

### Template Rendering

Use Elixir's built-in `EEx` module for template rendering:

```elixir
defmodule Ipa.Pod.ClaudeMdTemplates do
  @moduledoc """
  Generates contextual CLAUDE.md files for different levels.
  """

  @templates_dir "priv/claude_md_templates"

  def generate_workstream_level(task_id, workstream_id, opts \\ []) do
    with {:ok, task_state} <- Ipa.Pod.State.get_state(task_id),
         {:ok, workstream} <- Ipa.Pod.State.get_workstream(task_id, workstream_id),
         {:ok, template} <- load_template("workstream_level.md.eex") do

      context = build_workstream_context(task_state, workstream, opts)
      rendered = EEx.eval_string(template, assigns: context)

      {:ok, rendered}
    end
  end

  defp build_workstream_context(task_state, workstream, opts) do
    %{
      task_title: task_state.title,
      task_spec: render_spec(task_state.spec),
      task_phase: task_state.phase,
      repo_url: Keyword.get(opts, :repo_url, Application.get_env(:ipa, :default_repo_url)),
      branch: Keyword.get(opts, :branch, "main"),
      workstream_count: map_size(task_state.workstreams),
      workstream_list: Map.to_list(task_state.workstreams),
      workstream_id: workstream.workstream_id,
      workstream_spec: Keyword.get(opts, :workstream_spec, workstream.spec),
      workstream_dependencies: Keyword.get(opts, :dependencies, workstream.dependencies),
      related_workstreams: build_related_workstreams(task_state.workstreams, workstream.workstream_id),
      workspace_path: workstream.workspace || "/ipa/workspaces/#{task_state.task_id}/#{workstream.workstream_id}"
    }
  end

  defp load_template(filename) do
    path = Path.join(@templates_dir, filename)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :template_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_spec(spec) when is_map(spec) do
    """
    #{spec.description}

    Requirements:
    #{Enum.map_join(spec.requirements, "\n", fn req -> "- #{req}" end)}
    """
  end

  defp build_related_workstreams(workstreams, current_ws_id) do
    workstreams
    |> Enum.reject(fn {ws_id, _ws} -> ws_id == current_ws_id end)
    |> Enum.map(fn {ws_id, ws} ->
      {ws_id, Map.take(ws, [:spec, :status, :dependencies])}
    end)
  end
end
```

### Template Caching

For performance, cache system-level template in memory:

```elixir
@system_template_cache :ets.new(:system_template_cache, [:set, :public, :named_table])

defp get_system_template_cached() do
  case :ets.lookup(@system_template_cache, :content) do
    [{:content, cached}] ->
      cached

    [] ->
      {:ok, content} = load_template("system_level.md.eex")
      :ets.insert(@system_template_cache, {:content, content})
      content
  end
end
```

## Error Handling

### Template Not Found

```elixir
{:error, :template_not_found}
```

Occurs when template file is missing from `priv/claude_md_templates/`.

**Recovery**:
- Log error with file path
- Return helpful error message to caller
- Caller should fail gracefully and notify user

### Task/Workstream Not Found

```elixir
{:error, :task_not_found}
{:error, :workstream_not_found}
```

Occurs when querying Pod State for non-existent task/workstream.

**Recovery**:
- Log error with task_id/workstream_id
- Return error to caller
- Caller should validate IDs before calling template system

### Template Rendering Error

```elixir
{:error, {:template_error, reason}}
```

Occurs when EEx template rendering fails (syntax error, missing variable, etc.).

**Recovery**:
- Log full error with template name and context
- Return error to caller
- Requires template fix (development error)

## Testing Strategy

### Unit Tests

**Template Loading**:
```elixir
test "loads system-level template" do
  assert {:ok, content} = ClaudeMdTemplates.get_system_level()
  assert content =~ "# IPA System Context"
end

test "returns error when template file missing" do
  # Mock File.read to return :enoent
  assert {:error, :template_not_found} = ClaudeMdTemplates.get_system_level()
end
```

**Context Building**:
```elixir
test "builds pod-level context correctly" do
  task_state = %{
    title: "Implement auth",
    spec: %{description: "...", requirements: ["req1"]},
    phase: :planning,
    workstreams: %{"ws-1" => %{spec: "...", status: :pending}}
  }

  context = ClaudeMdTemplates.build_pod_context(task_state, [])

  assert context.task_title == "Implement auth"
  assert context.task_phase == :planning
  assert context.workstream_count == 1
end
```

**Template Rendering**:
```elixir
test "renders workstream-level template with all variables" do
  # Setup mocks for Pod State queries
  # Call generate_workstream_level
  assert {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, ws_id)

  # Verify rendered content
  assert content =~ "Workstream Context: ws-1"
  assert content =~ "Task: Implement auth"
  assert content =~ "Dependencies:"
end
```

### Integration Tests

**With Pod State**:
```elixir
test "generates workstream CLAUDE.md from real pod state" do
  # Create task with workstreams in Pod State
  task_id = create_test_task_with_workstreams()

  # Generate CLAUDE.md
  {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, "ws-1")

  # Verify content has real data from state
  assert content =~ "Test Task Title"
  assert content =~ "ws-2"  # Related workstream
end
```

**With Workspace Manager**:
```elixir
test "workspace manager can inject generated CLAUDE.md" do
  {:ok, content} = ClaudeMdTemplates.generate_workstream_level(task_id, ws_id)

  {:ok, workspace_path} = WorkspaceManager.create_workspace(
    task_id,
    ws_id,
    agent_id,
    %{claude_md: content}
  )

  # Verify CLAUDE.md was written to workspace
  assert File.exists?(Path.join(workspace_path, "CLAUDE.md"))
end
```

## Performance Considerations

1. **Template Caching**: System-level template cached in memory (static, never changes)
2. **State Queries**: Pod-level and workstream-level templates query Pod State (fast in-memory reads)
3. **Template Rendering**: EEx rendering is fast (<1ms for typical templates)
4. **File I/O**: Only on first template load, then cached

**Expected Performance**:
- `get_system_level/0`: <1ms (cached)
- `generate_pod_level/2`: <5ms (state query + render)
- `generate_workstream_level/3`: <10ms (2 state queries + render)

## Configuration

Add to `config/config.exs`:

```elixir
config :ipa, Ipa.Pod.ClaudeMdTemplates,
  templates_dir: "priv/claude_md_templates",
  default_repo_url: "git@github.com:xorvo/ipa.git",
  default_branch: "main",
  cache_templates: true  # Cache system template in memory
```

## Example Usage Flow

### When Pod Scheduler Creates Workstream

```elixir
# In Pod Scheduler
def create_workstream(task_id, workstream_spec, dependencies) do
  # 1. Create workstream in state
  workstream_id = UUID.uuid4()
  {:ok, _version} = Ipa.Pod.State.append_event(
    task_id,
    "workstream_created",
    %{workstream_id: workstream_id, spec: workstream_spec, dependencies: dependencies}
  )

  # 2. Generate CLAUDE.md for this workstream
  {:ok, claude_md_content} = Ipa.Pod.ClaudeMdTemplates.generate_workstream_level(
    task_id,
    workstream_id
  )

  # 3. Create workspace with CLAUDE.md
  {:ok, workspace_path} = Ipa.Pod.WorkspaceManager.create_workspace(
    task_id,
    workstream_id,
    nil,  # No agent yet
    %{
      repo: "git@github.com:xorvo/ipa.git",
      branch: "main",
      claude_md: claude_md_content
    }
  )

  # 4. Spawn agent to work in workspace
  spawn_agent_for_workstream(task_id, workstream_id, workspace_path)
end
```

## Implementation Checklist

- [ ] Create `lib/ipa/pod/claude_md_templates.ex` module
- [ ] Create `priv/claude_md_templates/` directory
- [ ] Write `system_level.md.eex` template (static)
- [ ] Write `pod_level.md.eex` template (task context)
- [ ] Write `workstream_level.md.eex` template (workstream context)
- [ ] Implement `get_system_level/0`
- [ ] Implement `generate_pod_level/2`
- [ ] Implement `generate_workstream_level/3`
- [ ] Implement context building helpers
- [ ] Implement template loading and caching
- [ ] Add configuration
- [ ] Write unit tests for template loading
- [ ] Write unit tests for context building
- [ ] Write unit tests for template rendering
- [ ] Write integration tests with Pod State
- [ ] Write integration tests with Workspace Manager
- [ ] Update tracker.md with progress
- [ ] Get spec review

## Future Enhancements

1. **Template Versioning**: Support multiple template versions for backward compatibility
2. **Custom Templates**: Allow users to provide custom CLAUDE.md templates
3. **Template Validation**: Validate templates on startup (check for required variables)
4. **Hot Reload**: Reload templates without restarting (development mode)
5. **Localization**: Support multiple languages for CLAUDE.md
6. **Template Inheritance**: Allow workstream templates to extend/override pod templates

## Notes

- This is a simple, stateless utility module (no GenServer needed)
- Templates use EEx (Embedded Elixir) for rendering
- All context comes from Pod State (single source of truth)
- Templates are designed to be human-readable and agent-helpful
- CLAUDE.md files are static once generated (not updated dynamically)
