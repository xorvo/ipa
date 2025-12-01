defmodule Ipa.Agent.Types.SpecGenerator do
  @moduledoc """
  Spec Generator agent implementation.

  This agent transforms rough requirements into a clear, focused technical
  specification. It acts as an expert software architect, helping users
  refine their initial ideas into actionable specs.

  ## Spec Quality Guidelines

  The agent focuses on:
  - High-level architecture and system boundaries
  - Key design decisions with rationale
  - Contracts between modules (inputs, outputs, behaviors)
  - Tech stack preferences when relevant

  And avoids:
  - Implementation details or code snippets
  - Verbose prose
  - Obvious requirements
  - Unnecessary sections

  ## Output

  The agent outputs a JSON file (`output.json`) containing:
  - `updated_content`: The complete, updated specification in markdown format
  - `new_comments`: Replies to existing user comment threads
  - `questions`: New questions for the user to help improve the spec

  ## Iteration

  The agent supports iterative refinement:
  - First run: transforms initial requirements into spec
  - Subsequent runs: refines existing spec based on user feedback and unresolved threads

  When invoked with existing spec content, the agent receives:
  - The current spec content
  - All unresolved review threads (comments and questions from the user)
  - Any unanswered questions it previously asked

  The agent then addresses the feedback and may ask new clarifying questions.
  """

  @behaviour Ipa.Agent
  require Logger

  @impl true
  def agent_type, do: :spec_generator

  @impl true
  def generate_prompt(context) do
    task = context[:task] || %{}
    current_spec = context[:current_spec]
    user_input = context[:user_input] || ""
    review_threads = context[:review_threads] || []

    task_title = get_field(task, :title) || task["title"] || "Untitled Task"

    base_prompt = """
    You are an expert software architect helping to write a technical specification.

    ## Your Role

    Transform rough requirements into a clear, focused technical specification.
    You are NOT writing code - you are writing a blueprint.

    ## Spec Quality Guidelines

    ### DO:
    - Focus on high-level architecture and system boundaries
    - Document key design decisions with rationale
    - Define contracts between modules (inputs, outputs, behaviors)
    - Specify tech stack preferences when relevant
    - Keep sections concise and scannable
    - Use diagrams (mermaid) for complex relationships

    ### DO NOT:
    - Include implementation details or code snippets (unless truly necessary to explain a concept)
    - Write verbose prose - every sentence should add value
    - Specify obvious requirements ("should be secure", "should be fast")
    - Add sections just because they're "standard"
    - Repeat information in multiple places

    ## Spec Structure (use what's relevant)

    1. **Overview** - 2-3 sentences max
    2. **Architecture** - High-level component diagram (mermaid)
    3. **Key Design Decisions** - Bullet points with rationale
    4. **Module Contracts** - Interface definitions, not implementations
    5. **Data Model** - Core entities and relationships only

    ---

    ## Task: #{task_title}

    """

    content_section =
      if current_spec && current_spec != "" do
        threads_section = format_review_threads(review_threads)

        """
        ## Current Spec (to refine)

        #{current_spec}

        #{threads_section}

        Please refine the spec based on the feedback above. Address any user comments and questions.
        """
      else
        """
        ## User's Initial Requirements

        #{user_input}

        Please transform these requirements into a well-structured technical specification.
        Focus on what's important, leave out what's obvious or unnecessary.
        """
      end

    output_section = """

    ---

    ## Output Instructions

    IMPORTANT: You MUST output a JSON file named `output.json` in the current directory.

    The JSON structure must be:
    ```json
    {
      "updated_content": "The full updated spec in markdown format",
      "new_comments": [
        {
          "thread_id": "existing-thread-id-if-replying",
          "content": "Your response to user feedback"
        }
      ],
      "questions": [
        {
          "content": "A question you need answered to improve the spec"
        }
      ]
    }
    ```

    - `updated_content`: The complete, updated specification (markdown formatted)
    - `new_comments`: Replies to existing user comment threads (use thread_id from the feedback above). Leave empty array if no replies needed.
    - `questions`: New questions for the user that will help you improve the spec. Leave empty array if you have no questions.

    Write only the JSON file. Do not create any other files.
    """

    base_prompt <> content_section <> output_section
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

  @impl true
  def configure_options(context) do
    workspace = context[:workspace] || "."

    %Ipa.Agent.Options{
      cwd: workspace,
      allowed_tools: ["Read", "Write", "Bash", "Glob", "Grep"],
      max_turns: 30,
      timeout_ms: 1_800_000,
      permission_mode: :accept_edits,
      # Non-interactive: agent completes after generating output.json
      # handle_completion is called automatically on completion
      interactive: false
    }
  end

  @impl true
  def handle_completion(result, context) do
    workspace = result[:workspace]
    task = context[:task]
    task_id = context[:task_id] || get_field(task, :task_id)

    Logger.info("Spec generator agent completed",
      task_id: task_id,
      workspace: workspace
    )

    output_path = Path.join(workspace || ".", "output.json")

    case File.read(output_path) do
      {:ok, json_content} ->
        case Jason.decode(json_content) do
          {:ok, output} ->
            Logger.info("Parsed output.json successfully", path: output_path)
            process_agent_output(task_id, workspace, output)

          {:error, decode_error} ->
            Logger.error("Failed to parse output.json",
              task_id: task_id,
              path: output_path,
              error: inspect(decode_error)
            )

            {:error, {:json_parse_error, decode_error}}
        end

      {:error, :enoent} ->
        # Fallback: try reading spec.md for backward compatibility
        Logger.warning("output.json not found, trying spec.md fallback",
          task_id: task_id,
          expected_path: output_path
        )

        spec_path = Path.join(workspace || ".", "spec.md")
        handle_legacy_output(task_id, workspace, spec_path)

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
  defp process_agent_output(task_id, workspace, output) do
    # 1. Process updated_content -> emit spec_updated event
    updated_content = output["updated_content"]

    if updated_content && updated_content != "" do
      Logger.info("Updating spec content", task_id: task_id)

      Ipa.EventStore.append(
        task_id,
        "spec_updated",
        %{
          content: updated_content,
          workspace_path: workspace
        },
        actor_id: "spec_generator_agent"
      )
    end

    # 2. Process new_comments -> post as review comment replies
    new_comments = output["new_comments"] || []
    process_new_comments(task_id, new_comments)

    # 3. Process questions -> post as new review threads with is_question flag
    questions = output["questions"] || []
    process_questions(task_id, questions)

    :ok
  end

  # Post agent's replies to existing comment threads
  defp process_new_comments(task_id, comments) do
    Enum.each(comments, fn comment ->
      thread_id = comment["thread_id"]
      content = comment["content"]

      if thread_id && content && String.trim(content) != "" do
        Logger.info("Posting agent reply to thread",
          task_id: task_id,
          thread_id: thread_id
        )

        # We need to get the original thread's document_anchor
        # For now, we'll create a minimal anchor
        case get_thread_anchor(task_id, thread_id) do
          {:ok, anchor} ->
            post_review_comment(task_id, %{
              author: "spec_generator",
              content: content,
              document_type: :spec,
              document_anchor: anchor,
              thread_id: thread_id
            })

          {:error, reason} ->
            Logger.warning("Could not find thread anchor for reply",
              task_id: task_id,
              thread_id: thread_id,
              reason: inspect(reason)
            )
        end
      end
    end)
  end

  # Post agent's questions as new review threads
  defp process_questions(task_id, questions) do
    Enum.each(questions, fn question ->
      content = question["content"]

      if content && String.trim(content) != "" do
        Logger.info("Posting agent question", task_id: task_id)

        # Create a placeholder anchor for questions (not tied to specific text)
        anchor = %{
          selected_text: "[Agent Question]",
          surrounding_text: "",
          line_start: 0,
          line_end: 0
        }

        post_review_comment(task_id, %{
          author: "spec_generator",
          content: content,
          document_type: :spec,
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
      actor_id: "spec_generator_agent"
    )
  end

  # Handle legacy spec.md output for backward compatibility
  defp handle_legacy_output(task_id, workspace, spec_path) do
    case File.read(spec_path) do
      {:ok, content} ->
        Logger.info("Found spec.md file (legacy), updating spec", path: spec_path)

        Ipa.EventStore.append(
          task_id,
          "spec_updated",
          %{
            content: content,
            workspace_path: workspace
          },
          actor_id: "spec_generator_agent"
        )

        :ok

      {:error, :enoent} ->
        Logger.error("Neither output.json nor spec.md found",
          task_id: task_id,
          expected_path: spec_path
        )

        {:error, :output_file_not_found}

      {:error, reason} ->
        Logger.error("Failed to read spec.md file",
          task_id: task_id,
          path: spec_path,
          reason: inspect(reason)
        )

        {:error, {:file_read_error, reason}}
    end
  end

  @impl true
  def handle_tool_call(tool_name, args, _context) do
    Logger.debug("Spec generator agent tool call", tool: tool_name, args: args)
    :ok
  end

  # Helper to access struct or map fields uniformly
  defp get_field(nil, _key), do: nil
  defp get_field(struct, key) when is_struct(struct), do: Map.get(struct, key)
  defp get_field(map, key) when is_map(map), do: map[key]
  defp get_field(_, _), do: nil
end
