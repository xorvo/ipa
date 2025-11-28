defmodule Ipa.Agent.Types.Workstream do
  @moduledoc """
  Workstream agent implementation.

  The workstream agent is responsible for implementing a specific workstream
  within a larger task. It receives the workstream spec and dependencies,
  then executes the work in its isolated workspace.

  ## Completion Marker

  The agent signals completion by creating a `WORKSTREAM_COMPLETE.md` file
  in its workspace. This file should contain a summary of what was accomplished.

  ## Completion Handling

  On completion, this agent:
  1. Checks for the WORKSTREAM_COMPLETE.md marker file
  2. Emits a `workstream_completed` event if marker exists
  3. Emits a `workstream_failed` event if marker is missing
  """

  @behaviour Ipa.Agent
  require Logger

  @impl true
  def agent_type, do: :workstream

  @impl true
  def generate_prompt(context) do
    workstream = context[:workstream] || %{}
    task = context[:task] || %{}

    # Use safe field access that works for both maps and structs
    workstream_id = get_field(workstream, :workstream_id) || context[:workstream_id] || "unknown"
    spec = get_field(workstream, :spec) || "No spec provided"
    dependencies = get_field(workstream, :dependencies) || []
    task_title = get_field(task, :title) || get_field(task, "title") || "Untitled Task"

    dependencies_text =
      if Enum.empty?(dependencies) do
        "None - you can start immediately!"
      else
        "Your dependencies are complete: #{Enum.join(dependencies, ", ")}"
      end

    """
    You are a specialized agent working on a specific workstream within a larger task.

    ## Task Context
    #{task_title}

    ## Your Workstream
    **ID**: #{workstream_id}
    **Spec**: #{spec}

    ## Dependencies
    #{dependencies_text}

    ## Your Mission
    Implement the workstream spec above. Work in the `work/` directory if needed.
    Create high-quality code with tests when appropriate.

    When done, commit your changes with a descriptive message.

    **IMPORTANT**: Mark your work as complete by creating a file called `WORKSTREAM_COMPLETE.md`
    with a summary of what you accomplished. This file signals that you have finished your workstream.
    """
  end

  @impl true
  def configure_options(context) do
    workspace = context[:workspace] || "."

    %Ipa.Agent.Options{
      cwd: workspace,
      allowed_tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
      max_turns: 100,
      timeout_ms: 7_200_000,
      # Required for headless/non-interactive execution
      permission_mode: :accept_edits
    }
  end

  @impl true
  def handle_completion(result, context) do
    workspace = result[:workspace]
    task_id = context[:task_id] || context[:task][:task_id]
    workstream_id = context[:workstream_id]

    Logger.info("Workstream agent completed, checking for completion marker",
      task_id: task_id,
      workstream_id: workstream_id,
      workspace: workspace
    )

    # Check for completion marker
    if workstream_complete?(workspace) do
      emit_workstream_completed(task_id, workstream_id)
    else
      emit_workstream_failed(task_id, workstream_id, "No completion marker found")
    end
  end

  @impl true
  def handle_tool_call(tool_name, _args, context) do
    Logger.debug("Workstream agent tool call",
      tool: tool_name,
      workstream_id: context[:workstream_id]
    )

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Safe field access that works for both maps and structs
  defp get_field(nil, _key), do: nil
  defp get_field(data, key) when is_struct(data), do: Map.get(data, key)
  defp get_field(data, key) when is_map(data), do: data[key]
  defp get_field(_data, _key), do: nil

  defp workstream_complete?(nil) do
    # No workspace path set - can't check for completion marker
    # Return false to trigger failure handling
    false
  end

  defp workstream_complete?(workspace) do
    # Check for WORKSTREAM_COMPLETE.md marker file
    marker_paths = [
      Path.join(workspace, "WORKSTREAM_COMPLETE.md"),
      Path.join([workspace, "work", "WORKSTREAM_COMPLETE.md"])
    ]

    Enum.any?(marker_paths, &File.exists?/1)
  end

  defp emit_workstream_completed(task_id, workstream_id) do
    Logger.info("Workstream completed successfully",
      task_id: task_id,
      workstream_id: workstream_id
    )

    Ipa.EventStore.append(
      task_id,
      "workstream_completed",
      %{
        workstream_id: workstream_id,
        completed_at: DateTime.utc_now() |> DateTime.to_unix()
      },
      actor_id: "workstream_agent"
    )

    :ok
  end

  defp emit_workstream_failed(task_id, workstream_id, error) do
    Logger.warning("Workstream failed - no completion marker",
      task_id: task_id,
      workstream_id: workstream_id,
      error: error
    )

    Ipa.EventStore.append(
      task_id,
      "workstream_failed",
      %{
        workstream_id: workstream_id,
        error: error,
        failed_at: DateTime.utc_now() |> DateTime.to_unix()
      },
      actor_id: "workstream_agent"
    )

    {:error, :no_completion_marker}
  end
end
