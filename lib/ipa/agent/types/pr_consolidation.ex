defmodule Ipa.Agent.Types.PrConsolidation do
  @moduledoc """
  PR Consolidation agent implementation.

  The PR consolidation agent is responsible for merging all completed workstream
  changes into a single cohesive pull request. It:

  1. Sets up a consolidated workspace (checkout main, create task branch)
  2. Cherry-picks or merges commits from each workstream workspace
  3. Resolves any conflicts
  4. Runs the full test suite
  5. Writes a comprehensive PR description
  6. Creates the PR via gh CLI

  ## Completion Handling

  On completion, this agent checks if a PR was created and emits the appropriate event.
  """

  @behaviour Ipa.Agent
  require Logger

  @impl true
  def agent_type, do: :pr_consolidation

  @impl true
  def generate_prompt(context) do
    task = context[:task] || %{}
    workstreams = task[:workstreams] || %{}

    task_title = task[:title] || task["title"] || "Untitled Task"

    # Build workstream summaries for completed workstreams
    workstream_summaries =
      workstreams
      |> Map.values()
      |> Enum.filter(fn ws -> ws.status == :completed end)
      |> Enum.map(fn ws ->
        """
        ## Workstream: #{ws.title || ws.workstream_id}
        - ID: #{ws.workstream_id}
        - Spec: #{ws.spec || "No spec"}
        - Status: Completed
        """
      end)
      |> Enum.join("\n\n")

    workstream_summaries =
      if workstream_summaries == "" do
        "No completed workstreams to consolidate."
      else
        workstream_summaries
      end

    """
    Task: #{task_title}

    Your role: Consolidate all workstream changes into a single PR.

    ## Completed Workstreams
    #{workstream_summaries}

    ## Instructions
    1. Set up consolidated workspace (checkout main, create task branch)
    2. For each workstream: cherry-pick or merge commits from workstream workspace
    3. Resolve any conflicts
    4. Run full test suite
    5. Write comprehensive PR description
    6. Create PR via gh CLI

    ## Important Guidelines
    - PR should be a single cohesive change
    - Ensure commit messages follow conventions
    - Tag PR with relevant labels
    - Include a summary of all workstream changes in the PR description

    ## Creating the PR
    Use the gh CLI to create the PR:
    ```bash
    gh pr create --title "Your PR title" --body "PR description"
    ```

    After creating the PR, note the PR number for tracking.
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
    response = result[:response] || ""
    task_id = context[:task_id] || context[:task][:task_id]

    Logger.info("PR consolidation agent completed",
      task_id: task_id,
      workspace: workspace
    )

    # Try to extract PR number from the response
    case extract_pr_number(response) do
      {:ok, pr_number} ->
        emit_pr_created_event(task_id, pr_number)
        :ok

      :not_found ->
        Logger.warning("PR number not found in agent response",
          task_id: task_id,
          response_preview: String.slice(response, 0, 500)
        )

        {:error, :pr_number_not_found}
    end
  end

  @impl true
  def handle_tool_call(tool_name, args, _context) do
    Logger.debug("PR consolidation agent tool call", tool: tool_name, args: args)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp extract_pr_number(response) do
    # Try to find PR number in various formats
    patterns = [
      # gh pr create output: "https://github.com/owner/repo/pull/123"
      ~r/github\.com\/[^\/]+\/[^\/]+\/pull\/(\d+)/,
      # Direct mention: "PR #123" or "Pull Request #123"
      ~r/(?:PR|Pull Request)\s*#(\d+)/i,
      # Created output: "Created pull request #123"
      ~r/[Cc]reated\s+pull\s+request\s+#?(\d+)/
    ]

    Enum.find_value(patterns, :not_found, fn pattern ->
      case Regex.run(pattern, response) do
        [_, pr_number] -> {:ok, String.to_integer(pr_number)}
        nil -> nil
      end
    end)
  end

  defp emit_pr_created_event(task_id, pr_number) do
    Logger.info("PR created", task_id: task_id, pr_number: pr_number)

    Ipa.EventStore.append(
      task_id,
      "pr_created",
      %{
        pr_number: pr_number,
        created_at: DateTime.utc_now() |> DateTime.to_unix()
      },
      actor_id: "pr_consolidation_agent"
    )
  end
end
