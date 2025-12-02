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

  The planning agent writes an `output.json` file containing:
  ```json
  {
    "updated_content": {
      "summary": "Brief summary of the plan",
      "workstreams": [
        {
          "id": "ws-1",
          "title": "Set up database schema",
          "description": "...",
          "dependencies": [],
          "estimated_hours": 8
        }
      ]
    },
    "new_comments": [],
    "questions": []
  }
  ```

  ## Iteration

  The agent supports iterative refinement:
  - First run: creates initial plan from spec
  - Subsequent runs: refines plan based on user feedback and unresolved threads

  ## Completion Handling

  On completion, this agent:
  1. Reads the output.json file
  2. Emits a `plan_updated` event with the workstream data
  3. Posts any replies to user comments
  4. Creates question threads for clarifications
  """

  @behaviour Ipa.Agent
  require Logger

  @impl true
  def agent_type, do: :planning_agent

  @impl true
  def generate_prompt(context) do
    task = context[:task] || %{}
    current_plan = context[:current_plan]
    user_input = context[:user_input] || ""
    review_threads = context[:review_threads] || []

    # Handle both struct and map access for task
    spec = get_field(task, :spec) || %{}

    spec_description =
      cond do
        is_binary(get_field(spec, :content)) -> get_field(spec, :content)
        is_binary(get_field(spec, :description)) -> get_field(spec, :description)
        is_binary(spec["content"]) -> spec["content"]
        is_binary(spec["description"]) -> spec["description"]
        true -> "No spec description provided"
      end

    task_title = get_field(task, :title) || task["title"] || "Untitled Task"

    base_prompt = """
    You are a software architect planning workstreams for a task.

    ## Task: #{task_title}

    ## Specification

    #{spec_description}

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
    """

    content_section =
      if current_plan && current_plan != %{} && has_workstreams?(current_plan) do
        threads_section = format_review_threads(review_threads)
        current_workstreams = format_current_plan(current_plan)

        """

        ---

        ## Current Plan (to refine)

        #{current_workstreams}

        #{threads_section}

        ## User Feedback

        #{user_input}

        Please refine the plan based on the feedback above. Address any user comments.
        """
      else
        """

        ---

        ## User's Planning Requirements

        #{user_input}

        Please create a workstream plan based on the spec and these requirements.
        """
      end

    output_section = """

    ---

    ## Output Instructions

    IMPORTANT: You MUST output a JSON file named `output.json` in the current directory.

    The JSON structure must be:
    ```json
    {
      "updated_content": {
        "summary": "Brief summary of the plan and approach",
        "workstreams": [
          {
            "id": "ws-1",
            "title": "Workstream title",
            "description": "Detailed description of what this workstream covers",
            "dependencies": [],
            "estimated_hours": 8
          }
        ]
      },
      "tracker": {
        "phases": [
          {
            "phase_id": "phase-1",
            "name": "Phase name",
            "summary": "Brief one-line summary of what this phase achieves",
            "description": "Detailed description of the phase goals and scope",
            "eta": "2024-12-31",
            "order": 0,
            "items": [
              {
                "item_id": "item-1",
                "summary": "Expected outcome description",
                "workstream_id": "ws-1",
                "status": "todo"
              }
            ]
          }
        ]
      },
      "new_comments": [
        {
          "thread_id": "existing-thread-id-if-replying",
          "content": "Your response to user feedback"
        }
      ],
      "questions": [
        {
          "content": "A question you need answered to improve the plan"
        }
      ]
    }
    ```

    - `updated_content`: The complete plan with summary and workstreams
    - `tracker`: Progress tracker with phases and expected outcomes (items)
      - Each phase has a name, summary, description, optional ETA, and order for display
      - `summary`: Brief one-line description of the phase
      - `description`: More detailed explanation of the phase goals and scope
      - Each item (expected outcome) MUST belong to exactly ONE workstream (workstream_id)
      - Item statuses: "todo", "wip", "done", "blocked"
      - Items track high-level deliverables, not implementation details
    - `new_comments`: Replies to existing user comment threads (use thread_id from feedback). Empty array if none.
    - `questions`: New questions for the user. Empty array if none.

    IMPORTANT: Each tracker item must be assigned to exactly ONE workstream. A workstream can own multiple items, but items cannot be shared.

    Note: It is perfectly acceptable to output just ONE workstream if the task doesn't benefit from splitting.

    Write only the JSON file. Do not create any other files.
    """

    base_prompt <> content_section <> output_section
  end

  defp has_workstreams?(plan) do
    workstreams = plan[:workstreams] || plan["workstreams"] || []
    length(workstreams) > 0
  end

  defp format_review_threads([]), do: ""

  defp format_review_threads(threads) do
    formatted =
      threads
      |> Enum.map(fn thread ->
        thread_id = thread[:thread_id] || thread["thread_id"]
        messages = thread[:messages] || thread["messages"] || []
        is_question = thread[:is_question] || thread["is_question"] || false
        type_label = if is_question, do: "[QUESTION]", else: "[COMMENT]"

        messages_text =
          messages
          |> Enum.map(fn msg ->
            author = msg[:author] || msg["author"]
            content = msg[:content] || msg["content"]
            "  - #{author}: #{content}"
          end)
          |> Enum.join("\n")

        """
        #{type_label} Thread ID: #{thread_id}
        #{messages_text}
        """
      end)
      |> Enum.join("\n")

    """
    ## Unresolved Feedback (address these)

    #{formatted}
    """
  end

  defp format_current_plan(plan) do
    workstreams = plan[:workstreams] || plan["workstreams"] || []
    summary = plan[:summary] || plan["summary"] || ""

    ws_text =
      workstreams
      |> Enum.map(fn ws ->
        id = ws[:id] || ws["id"] || "?"
        title = ws[:title] || ws["title"] || "Untitled"
        desc = ws[:description] || ws["description"] || ""
        deps = ws[:dependencies] || ws["dependencies"] || []
        hours = ws[:estimated_hours] || ws["estimated_hours"] || 0

        deps_str = if Enum.empty?(deps), do: "None", else: Enum.join(deps, ", ")

        """
        ### #{id}: #{title}
        #{desc}

        Dependencies: #{deps_str}
        Estimated: #{hours} hours
        """
      end)
      |> Enum.join("\n")

    if summary != "" do
      """
      **Summary**: #{summary}

      #{ws_text}
      """
    else
      ws_text
    end
  end

  @impl true
  def configure_options(context) do
    workspace = context[:workspace] || "."

    %Ipa.Agent.Options{
      cwd: workspace,
      allowed_tools: ["Read", "Write", "Bash", "Glob", "Grep"],
      max_turns: 50,
      timeout_ms: 3_600_000,
      permission_mode: :accept_edits,
      # Non-interactive: agent completes automatically after generating output.json
      interactive: false
    }
  end

  @impl true
  def handle_completion(result, context) do
    workspace = result[:workspace]
    task = context[:task]
    task_id = context[:task_id] || get_field(task, :task_id)

    Logger.info("Planning agent completed",
      task_id: task_id,
      workspace: workspace
    )

    output_path = Path.join(workspace || ".", "output.json")

    case File.read(output_path) do
      {:ok, json_content} ->
        case Jason.decode(json_content) do
          {:ok, output} ->
            Logger.info("Parsed output.json successfully", path: output_path)
            process_agent_output(task_id, output)

          {:error, decode_error} ->
            Logger.error("Failed to parse output.json",
              task_id: task_id,
              path: output_path,
              error: inspect(decode_error)
            )

            # Fallback to legacy format
            handle_legacy_output(task_id, workspace)
        end

      {:error, :enoent} ->
        # Fallback: try reading workstreams_plan.json for backward compatibility
        Logger.warning("output.json not found, trying legacy format",
          task_id: task_id,
          expected_path: output_path
        )

        handle_legacy_output(task_id, workspace)

      {:error, reason} ->
        Logger.error("Failed to read output.json",
          task_id: task_id,
          path: output_path,
          reason: inspect(reason)
        )

        {:error, {:file_read_error, reason}}
    end
  end

  # Process the structured JSON output from the agent
  defp process_agent_output(task_id, output) do
    # 1. Process updated_content -> emit plan_updated event
    updated_content = output["updated_content"]

    if updated_content && is_map(updated_content) do
      Logger.info("Updating plan content", task_id: task_id)

      workstreams = updated_content["workstreams"] || []
      summary = updated_content["summary"]

      Ipa.EventStore.append(
        task_id,
        "plan_updated",
        %{
          summary: summary,
          workstreams: workstreams,
          total_estimated_hours: calculate_total_hours(workstreams)
        },
        actor_id: "planning_agent"
      )
    end

    # 2. Process tracker -> emit tracker_created event
    tracker = output["tracker"]
    process_tracker(task_id, tracker)

    # 3. Process new_comments -> post as review comment replies
    new_comments = output["new_comments"] || []
    process_new_comments(task_id, new_comments)

    # 4. Process questions -> post as new review threads
    questions = output["questions"] || []
    process_questions(task_id, questions)

    :ok
  end

  # Process the tracker data and emit tracker_created event
  defp process_tracker(_task_id, nil), do: :ok

  defp process_tracker(task_id, tracker) when is_map(tracker) do
    phases = tracker["phases"] || []

    if length(phases) > 0 do
      Logger.info("Creating tracker",
        task_id: task_id,
        phase_count: length(phases)
      )

      Ipa.Pod.Commands.TrackerCommands.create_tracker(task_id, phases, "planning_agent")
    else
      :ok
    end
  end

  defp process_tracker(_task_id, _), do: :ok

  # Post agent's replies to existing comment threads
  defp process_new_comments(task_id, comments) do
    Enum.each(comments, fn comment ->
      thread_id = comment["thread_id"]
      content = comment["content"]

      if thread_id && content && String.trim(content) != "" do
        Logger.info("Posting agent reply to plan thread",
          task_id: task_id,
          thread_id: thread_id
        )

        case get_thread_anchor(task_id, thread_id) do
          {:ok, anchor} ->
            post_review_comment(task_id, %{
              author: "planning_agent",
              content: content,
              document_type: :plan,
              document_anchor: anchor,
              thread_id: thread_id
            })

          {:error, _reason} ->
            # Create minimal anchor for reply
            post_review_comment(task_id, %{
              author: "planning_agent",
              content: content,
              document_type: :plan,
              document_anchor: %{
                selected_text: "[Reply]",
                surrounding_text: "",
                line_start: 0,
                line_end: 0
              },
              thread_id: thread_id
            })
        end
      end
    end)
  end

  # Post agent's questions as new review threads
  defp process_questions(task_id, questions) do
    Enum.each(questions, fn question ->
      content = question["content"]

      if content && String.trim(content) != "" do
        Logger.info("Posting agent question for plan", task_id: task_id)

        anchor = %{
          selected_text: "[Agent Question]",
          surrounding_text: "",
          line_start: 0,
          line_end: 0
        }

        post_review_comment(task_id, %{
          author: "planning_agent",
          content: content,
          document_type: :plan,
          document_anchor: anchor,
          is_question: true
        })
      end
    end)
  end

  # Get the document anchor from an existing thread
  defp get_thread_anchor(task_id, thread_id) do
    case Ipa.Pod.Manager.get_state_from_events(task_id) do
      {:ok, state} ->
        case Map.get(state.messages, thread_id) do
          nil ->
            {:error, :thread_not_found}

          message ->
            anchor = message.metadata[:document_anchor] || message.metadata["document_anchor"]

            if anchor do
              {:ok, anchor}
            else
              {:error, :no_anchor}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Post a review comment via event store
  defp post_review_comment(task_id, params) do
    message_id = Ecto.UUID.generate()
    thread_id = params[:thread_id] || message_id

    metadata = %{
      document_type: params[:document_type],
      document_anchor: params[:document_anchor],
      resolved?: false,
      resolved_by: nil,
      resolved_at: nil,
      is_question: Map.get(params, :is_question, false)
    }

    Ipa.EventStore.append(
      task_id,
      "message_posted",
      %{
        message_id: message_id,
        author: params[:author],
        content: params[:content],
        message_type: "review_comment",
        thread_id: thread_id,
        workstream_id: nil,
        metadata: metadata
      },
      actor_id: "planning_agent"
    )
  end

  # Handle legacy workstreams_plan.json output for backward compatibility
  defp handle_legacy_output(task_id, workspace) do
    plan_path = Path.join(workspace || ".", "workstreams_plan.json")

    case File.read(plan_path) do
      {:ok, content} ->
        Logger.info("Found legacy workstreams_plan.json", path: plan_path)
        # Clean up the file after reading
        cleanup_plan_file(plan_path)
        process_legacy_plan_file(content, task_id)

      {:error, :enoent} ->
        Logger.error("Neither output.json nor workstreams_plan.json found",
          task_id: task_id
        )

        {:error, :output_file_not_found}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

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

  defp process_legacy_plan_file(content, task_id) do
    case Jason.decode(content) do
      {:ok, plan_data} ->
        workstreams = plan_data["workstreams"] || []

        Logger.info("Successfully read legacy workstreams plan",
          task_id: task_id,
          workstream_count: length(workstreams)
        )

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
        Logger.error("Failed to parse legacy workstreams plan JSON",
          task_id: task_id,
          error: inspect(json_error)
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

  @impl true
  def handle_tool_call(tool_name, args, _context) do
    Logger.debug("Planning agent tool call", tool: tool_name, args: args)
    :ok
  end

  # Helper to access struct or map fields uniformly
  defp get_field(nil, _key), do: nil
  defp get_field(struct, key) when is_struct(struct), do: Map.get(struct, key)
  defp get_field(map, key) when is_map(map), do: map[key]
  defp get_field(_, _), do: nil
end
