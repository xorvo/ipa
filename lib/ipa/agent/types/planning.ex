defmodule Ipa.Agent.Types.Planning do
  @moduledoc """
  Planning agent implementation.

  The planning agent is responsible for breaking down a task into parallel
  workstreams. It analyzes the task spec and creates a workstream plan
  that specifies:
  - Individual workstreams with clear goals
  - Dependencies between workstreams
  - Estimated hours for each workstream

  ## Output

  The planning agent writes a `workstreams_plan.json` file containing:
  ```json
  {
    "workstreams": [
      {
        "id": "ws-1",
        "title": "Set up database schema",
        "description": "...",
        "dependencies": [],
        "estimated_hours": 8
      }
    ]
  }
  ```

  ## Completion Handling

  On completion, this agent:
  1. Reads the workstreams_plan.json file
  2. Emits a `plan_updated` event with the workstream data
  """

  @behaviour Ipa.Agent
  require Logger

  @impl true
  def agent_type, do: :planning_agent

  @impl true
  def generate_prompt(context) do
    task = context[:task] || %{}

    # Handle both struct and map access for task
    spec = get_field(task, :spec) || %{}

    spec_description =
      cond do
        is_binary(get_field(spec, :description)) -> get_field(spec, :description)
        is_binary(spec["description"]) -> spec["description"]
        true -> "No spec description provided"
      end

    task_title = get_field(task, :title) || task["title"] || "Untitled Task"

    """
    Task: #{task_title}

    Spec: #{spec_description}

    Your role: Analyze this task and determine if it needs to be split into workstreams.

    ## Guidelines for Workstream Planning

    **Prefer fewer, larger workstreams over many small ones.**

    A single workstream is often best when:
    - The task is cohesive and naturally flows from one step to the next
    - Splitting would create artificial boundaries that slow down work
    - The total effort is under ~1 week for one person
    - Components are tightly coupled and share significant context

    Multiple workstreams make sense when:
    - There are truly independent components that different people could work on simultaneously
    - There's a clear separation of concerns (e.g., frontend vs backend vs infrastructure)
    - One part has significantly different dependencies or expertise requirements

    **When in doubt, keep it as one workstream.** Over-splitting creates coordination overhead.

    Each workstream should:
    - Represent a meaningful, complete unit of work
    - Have clear boundaries and deliverables
    - Be substantial enough to justify the overhead of separate execution

    IMPORTANT: You are running in an isolated workspace directory. All file operations should use RELATIVE paths only.
    Write your output to a file named `workstreams_plan.json` in the CURRENT DIRECTORY (use relative path, NOT absolute).

    Output a JSON structure to file `./workstreams_plan.json`:
    {
      "workstreams": [
        {
          "id": "ws-1",
          "title": "Implement user authentication system",
          "description": "Build the complete auth flow including login, registration, password reset, and session management",
          "dependencies": [],
          "estimated_hours": 24
        }
      ]
    }

    Note: It is perfectly acceptable to output just ONE workstream if the task doesn't benefit from splitting.
    """
  end

  @impl true
  def configure_options(context) do
    workspace = context[:workspace] || "."

    %Ipa.Agent.Options{
      cwd: workspace,
      allowed_tools: ["Read", "Write", "Bash", "Glob", "Grep"],
      max_turns: 50,
      timeout_ms: 3_600_000,
      # Required for headless/non-interactive execution
      permission_mode: :accept_edits
    }
  end

  @impl true
  def handle_completion(result, context) do
    workspace = result[:workspace]
    task = context[:task]
    task_id = context[:task_id] || get_field(task, :task_id)

    Logger.info("Planning agent completed, reading workstreams plan",
      task_id: task_id,
      workspace: workspace
    )

    # Only look for the plan file in the agent's dedicated workspace
    # The SDK's cwd option ensures files are created in the workspace
    plan_path = Path.join(workspace || ".", "workstreams_plan.json")

    case File.read(plan_path) do
      {:ok, content} ->
        Logger.info("Found workstreams plan file", path: plan_path)
        # Clean up the file after reading to avoid stale data on next run
        cleanup_plan_file(plan_path)
        process_plan_file(content, task_id)

      {:error, :enoent} ->
        Logger.error("Workstreams plan file not found",
          task_id: task_id,
          expected_path: plan_path
        )

        {:error, :plan_file_not_found}

      {:error, reason} ->
        Logger.error("Failed to read workstreams plan file",
          task_id: task_id,
          path: plan_path,
          reason: inspect(reason)
        )

        {:error, {:file_read_error, reason}}
    end
  end

  @impl true
  def handle_tool_call(tool_name, args, _context) do
    Logger.debug("Planning agent tool call", tool: tool_name, args: args)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp cleanup_plan_file(path) do
    case File.rm(path) do
      :ok ->
        Logger.debug("Cleaned up plan file", path: path)

      {:error, reason} ->
        Logger.warning("Failed to clean up plan file",
          path: path,
          reason: inspect(reason)
        )
    end
  end

  defp process_plan_file(content, task_id) do
    case Jason.decode(content) do
      {:ok, plan_data} ->
        workstreams = plan_data["workstreams"] || []

        Logger.info("Successfully read workstreams plan",
          task_id: task_id,
          workstream_count: length(workstreams)
        )

        # Emit plan_updated event with workstreams data
        Ipa.EventStore.append(
          task_id,
          "plan_updated",
          %{
            steps: [],
            workstreams: workstreams,
            total_estimated_hours: calculate_total_hours(workstreams)
          },
          actor_id: "planning_agent"
        )

        :ok

      {:error, json_error} ->
        Logger.error("Failed to parse workstreams plan JSON",
          task_id: task_id,
          error: inspect(json_error),
          content_preview: String.slice(content, 0, 200)
        )

        {:error, {:json_parse_error, json_error}}
    end
  end

  defp calculate_total_hours(workstreams) when is_list(workstreams) do
    Enum.reduce(workstreams, 0.0, fn ws, acc ->
      hours = ws["estimated_hours"] || ws[:estimated_hours] || 0
      acc + hours
    end)
  end

  defp calculate_total_hours(_), do: 0.0

  # Helper to access struct or map fields uniformly
  defp get_field(nil, _key), do: nil
  defp get_field(struct, key) when is_struct(struct), do: Map.get(struct, key)
  defp get_field(map, key) when is_map(map), do: map[key]
  defp get_field(_, _), do: nil
end
