defmodule Ipa.Agent.Types.PrCommentResolver do
  @moduledoc """
  PR Comment Resolver agent implementation.

  The PR comment resolver agent is responsible for addressing review comments
  on a pull request. It:

  1. Reads the PR comments via gh CLI
  2. Makes the requested changes
  3. Runs tests to verify changes
  4. Pushes the updates

  ## Completion Handling

  On completion, this agent emits a `pr_comments_addressed` event.
  """

  @behaviour Ipa.Agent
  require Logger

  @impl true
  def agent_type, do: :pr_comment_resolver

  @impl true
  def generate_prompt(context) do
    task = context[:task] || %{}
    external_sync = task[:external_sync] || %{}
    github = external_sync[:github] || %{}

    pr_number = github[:pr_number] || "unknown"
    task_title = task[:title] || task["title"] || "Untitled Task"

    """
    Task: #{task_title}

    PR ##{pr_number} has comments that need to be addressed.

    ## Your Mission
    1. Read PR comments: `gh pr view #{pr_number} --comments`
    2. Understand each comment and what changes are requested
    3. Make the requested changes to the code
    4. Run tests to verify your changes work correctly
    5. Commit and push the updates

    ## Guidelines
    - Address each comment systematically
    - Make minimal, focused changes to address the feedback
    - Add tests if the reviewer requested them
    - Write clear commit messages explaining what you fixed

    ## Viewing Comments
    ```bash
    gh pr view #{pr_number} --comments
    gh pr diff #{pr_number}
    ```

    ## After Making Changes
    ```bash
    git add .
    git commit -m "Address PR review comments"
    git push
    ```

    When you've addressed all comments, create a summary of what you changed.
    """
  end

  @impl true
  def configure_options(context) do
    workspace = context[:workspace] || "."

    %Ipa.Agent.Options{
      cwd: workspace,
      allowed_tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
      max_turns: 100,
      timeout_ms: 3_600_000,
      # Required for headless/non-interactive execution
      permission_mode: :accept_edits
    }
  end

  @impl true
  def handle_completion(result, context) do
    workspace = result[:workspace]
    task_id = context[:task_id] || context[:task][:task_id]

    Logger.info("PR comment resolver agent completed",
      task_id: task_id,
      workspace: workspace
    )

    # Emit event indicating comments were addressed
    emit_comments_addressed_event(task_id)
    :ok
  end

  @impl true
  def handle_tool_call(tool_name, args, _context) do
    Logger.debug("PR comment resolver agent tool call", tool: tool_name, args: args)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp emit_comments_addressed_event(task_id) do
    Logger.info("PR comments addressed", task_id: task_id)

    Ipa.EventStore.append(
      task_id,
      "pr_comments_addressed",
      %{
        addressed_at: DateTime.utc_now() |> DateTime.to_unix()
      },
      actor_id: "pr_comment_resolver_agent"
    )
  end
end
