defmodule IpaWeb.Pod.DocumentReviewLive do
  @moduledoc """
  LiveView for reviewing documents (Spec, Plan, Report) with threaded discussions.

  Features:
  - Document preview with text selection for comments
  - Threaded comments (human feedback) and questions (agent clarifications)
  - Resolve threads to exclude from future agent interactions
  - Spec generation via AI agent
  """
  use IpaWeb, :live_view

  alias Ipa.Pod.Manager
  alias Ipa.Pod.State

  require Logger

  @impl true
  def mount(%{"task_id" => task_id, "doc_type" => doc_type_str}, _session, socket) do
    doc_type = parse_doc_type(doc_type_str)

    if doc_type do
      case Manager.get_state_from_events(task_id) do
        {:ok, state} ->
          if connected?(socket) do
            Ipa.EventStore.subscribe(task_id)
            Manager.subscribe(task_id)
          end

          {:ok, init_assigns(socket, task_id, doc_type, state)}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "Task not found")
           |> push_navigate(to: "/")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Invalid document type")
       |> push_navigate(to: "/")}
    end
  end

  defp init_assigns(socket, task_id, doc_type, state) do
    document_content = get_document_content(state, doc_type)
    review_threads = State.get_review_threads(state, doc_type)
    generation_status = get_in(state.spec, [:generation_status]) || :idle
    related_agents = get_related_agents(state, doc_type)

    socket
    |> assign(:task_id, task_id)
    |> assign(:doc_type, doc_type)
    |> assign(:state, state)
    |> assign(:document_content, document_content)
    |> assign(:review_threads, review_threads)
    |> assign(:related_agents, related_agents)
    # Text selection for comments (needs state because it comes from JS hook)
    |> assign(:selected_text, nil)
    |> assign(:selection_anchor, nil)
    # Thread interaction
    |> assign(:active_thread_id, nil)
    # UI state
    |> assign(:show_resolved, false)
    |> assign(:questions_collapsed, false)
    |> assign(:agent_history_expanded, false)
    # Spec generation
    |> assign(:generation_status, generation_status)
    # Agent detail modal
    |> assign(:selected_agent_id, nil)
  end

  defp parse_doc_type("spec"), do: :spec
  defp parse_doc_type("plan"), do: :plan
  defp parse_doc_type("report"), do: :report
  defp parse_doc_type(_), do: nil

  defp get_document_content(state, :spec) do
    spec = state.spec || %{}
    content = spec[:content] || spec["content"]
    if content && content != "", do: content, else: nil
  end

  defp get_document_content(state, :plan) do
    case state.plan do
      nil -> nil
      plan when is_map(plan) -> format_plan_content(plan)
      plan when is_binary(plan) -> plan
      _ -> nil
    end
  end

  defp format_plan_content(plan) do
    workstreams = plan[:workstreams] || plan["workstreams"] || []

    if Enum.empty?(workstreams) do
      "No workstreams defined yet."
    else
      workstreams
      |> Enum.map(&format_workstream/1)
      |> Enum.join("\n\n")
    end
  end

  defp format_workstream(ws) do
    id = ws[:id] || ws["id"] || "unknown"
    title = ws[:title] || ws["title"] || "Untitled"
    description = ws[:description] || ws["description"] || ""
    deps = ws[:dependencies] || ws["dependencies"] || []
    hours = ws[:estimated_hours] || ws["estimated_hours"]

    deps_str = if Enum.empty?(deps), do: "None", else: Enum.join(deps, ", ")
    hours_str = if hours, do: "#{hours} hours", else: "Not estimated"

    """
    ## #{id}: #{title}

    #{description}

    Dependencies: #{deps_str}
    Estimated: #{hours_str}
    """
    |> String.trim()
  end
  defp get_document_content(_state, :report), do: nil

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("text_selected", params, socket) do
    anchor = %{
      selected_text: params["text"],
      surrounding_text: params["surrounding"],
      line_start: params["lineStart"] || 1,
      line_end: params["lineEnd"] || params["lineStart"] || 1
    }

    {:noreply,
     socket
     |> assign(:selected_text, params["text"])
     |> assign(:selection_anchor, anchor)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_text, nil)
     |> assign(:selection_anchor, nil)}
  end

  def handle_event("post_comment", %{"content" => content}, socket) do
    %{task_id: task_id, doc_type: doc_type, selection_anchor: anchor} = socket.assigns

    if String.trim(content) != "" and anchor do
      params = %{
        author: "user",
        content: content,
        document_type: doc_type,
        document_anchor: anchor
      }

      with :ok <- ensure_pod_running(task_id),
           {:ok, _version} <-
             Manager.execute(
               task_id,
               Ipa.Pod.Commands.CommunicationCommands,
               :post_review_comment,
               [params]
             ) do
        {:noreply,
         socket
         |> assign(:selected_text, nil)
         |> assign(:selection_anchor, nil)
         |> put_flash(:info, "Comment posted")}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to post comment: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_thread", %{"id" => thread_id}, socket) do
    new_active =
      if socket.assigns.active_thread_id == thread_id, do: nil, else: thread_id

    {:noreply, assign(socket, :active_thread_id, new_active)}
  end

  def handle_event("post_reply", %{"thread_id" => thread_id, "content" => content}, socket) do
    %{task_id: task_id, doc_type: doc_type} = socket.assigns

    if String.trim(content) != "" do
      params = %{
        author: "user",
        content: content,
        document_type: doc_type,
        thread_id: thread_id,
        document_anchor: %{
          selected_text: "[Reply]",
          surrounding_text: "[Thread reply]",
          line_start: 0,
          line_end: 0
        }
      }

      with :ok <- ensure_pod_running(task_id),
           {:ok, _version} <-
             Manager.execute(
               task_id,
               Ipa.Pod.Commands.CommunicationCommands,
               :post_review_comment,
               [params]
             ) do
        {:noreply, put_flash(socket, :info, "Reply posted")}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to post reply: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("resolve_thread", %{"id" => thread_id}, socket) do
    %{task_id: task_id} = socket.assigns

    with :ok <- ensure_pod_running(task_id),
         {:ok, _version} <-
           Manager.execute(
             task_id,
             Ipa.Pod.Commands.ReviewCommands,
             :resolve_thread,
             [%{thread_id: thread_id, resolved_by: "user"}]
           ) do
      {:noreply,
       socket
       |> assign(:active_thread_id, nil)
       |> put_flash(:info, "Thread resolved")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resolve: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_resolved", _params, socket) do
    {:noreply, assign(socket, :show_resolved, !socket.assigns.show_resolved)}
  end

  def handle_event("toggle_questions", _params, socket) do
    {:noreply, assign(socket, :questions_collapsed, !socket.assigns.questions_collapsed)}
  end

  def handle_event("toggle_agent_history", _params, socket) do
    {:noreply, assign(socket, :agent_history_expanded, !socket.assigns.agent_history_expanded)}
  end

  def handle_event("scroll_to_questions", _params, socket) do
    # Expand questions section and scroll to it via JS hook
    {:noreply,
     socket
     |> assign(:questions_collapsed, false)
     |> push_event("scroll_to", %{target: "questions-section"})}
  end

  def handle_event("view_agent", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, :selected_agent_id, agent_id)}
  end

  def handle_event("close_agent_modal", _params, socket) do
    {:noreply, assign(socket, :selected_agent_id, nil)}
  end

  def handle_event("generate_spec", %{"input" => input}, socket) do
    %{task_id: task_id, state: state} = socket.assigns

    cond do
      String.trim(input) == "" ->
        {:noreply, put_flash(socket, :error, "Please provide initial requirements")}

      State.spec_approved?(state) ->
        {:noreply, put_flash(socket, :error, "Spec is already approved")}

      true ->
        with :ok <- ensure_pod_running(task_id),
             {:ok, _agent_id} <- Manager.spawn_spec_generator(task_id, input) do
          {:noreply,
           socket
           |> assign(:generation_status, :generating)
           |> put_flash(:info, "Spec generation started")}
        else
          {:error, :generation_in_progress} ->
            {:noreply, put_flash(socket, :error, "Generation already in progress")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("generate_plan", %{"input" => input}, socket) do
    %{task_id: task_id, state: state} = socket.assigns

    cond do
      String.trim(input) == "" ->
        {:noreply, put_flash(socket, :error, "Please provide planning requirements")}

      State.plan_approved?(state) ->
        {:noreply, put_flash(socket, :error, "Plan is already approved")}

      true ->
        with :ok <- ensure_pod_running(task_id),
             {:ok, _agent_id} <- Manager.spawn_planning_agent(task_id, input) do
          {:noreply,
           socket
           |> assign(:generation_status, :generating)
           |> put_flash(:info, "Plan generation started")}
        else
          {:error, :generation_in_progress} ->
            {:noreply, put_flash(socket, :error, "Generation already in progress")}

          {:error, :invalid_phase} ->
            {:noreply, put_flash(socket, :error, "Must be in planning phase to generate plan")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
        end
    end
  end

  # ============================================================================
  # PubSub Handlers
  # ============================================================================

  @impl true
  def handle_info({:state_updated, _task_id, new_state}, socket) do
    doc_type = socket.assigns.doc_type

    {:noreply,
     socket
     |> assign(:state, new_state)
     |> assign(:document_content, get_document_content(new_state, doc_type))
     |> assign(:review_threads, State.get_review_threads(new_state, doc_type))
     |> assign(:related_agents, get_related_agents(new_state, doc_type))
     |> assign(:generation_status, get_in(new_state.spec, [:generation_status]) || :idle)}
  end

  def handle_info({:event_appended, _stream_id, _event}, socket) do
    case Manager.get_state_from_events(socket.assigns.task_id) do
      {:ok, new_state} ->
        doc_type = socket.assigns.doc_type

        {:noreply,
         socket
         |> assign(:state, new_state)
         |> assign(:document_content, get_document_content(new_state, doc_type))
         |> assign(:review_threads, State.get_review_threads(new_state, doc_type))
         |> assign(:related_agents, get_related_agents(new_state, doc_type))
         |> assign(:generation_status, get_in(new_state.spec, [:generation_status]) || :idle)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ============================================================================
  # Helpers
  # ============================================================================

  defp ensure_pod_running(task_id) do
    if Ipa.PodSupervisor.pod_running?(task_id) do
      :ok
    else
      case Ipa.CentralManager.start_pod(task_id) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:pod_start_failed, reason}}
      end
    end
  end

  defp format_doc_type(:spec), do: "Specification"
  defp format_doc_type(:plan), do: "Plan"
  defp format_doc_type(:report), do: "Report"
  defp format_doc_type(other), do: to_string(other)

  defp format_timestamp(unix) when is_integer(unix) do
    DateTime.from_unix!(unix) |> Calendar.strftime("%b %d, %H:%M")
  end

  defp format_timestamp(_), do: ""

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."

  defp spec_approved?(state), do: State.spec_approved?(state)
  defp plan_approved?(state), do: State.plan_approved?(state)

  # Get agents related to this document type based on their context
  # Safely handles agents created before the context field was added
  defp get_related_agents(state, doc_type) do
    doc_type_str = to_string(doc_type)

    state.agents
    |> Enum.filter(fn agent ->
      # Safely get context, defaulting to empty map for older agents
      context = Map.get(agent, :context, %{}) || %{}
      # Check if agent's context matches this document type (handle both atom and string values)
      agent_doc_type = context[:document_type] || context["document_type"]
      to_string(agent_doc_type) == doc_type_str
    end)
    |> Enum.sort_by(& &1.started_at, :desc)
  end

  defp format_agent_status(:running), do: {"Running", "badge-info"}
  defp format_agent_status(:awaiting_input), do: {"Awaiting Input", "badge-accent"}
  defp format_agent_status(:completed), do: {"Completed", "badge-success"}
  defp format_agent_status(:failed), do: {"Failed", "badge-error"}
  defp format_agent_status(:pending_start), do: {"Pending", "badge-warning"}
  defp format_agent_status(_), do: {"Unknown", "badge-ghost"}

  defp format_agent_type(:spec_generator), do: "Spec Generator"
  defp format_agent_type(:planning), do: "Planning Agent"
  defp format_agent_type(:planning_agent), do: "Planning Agent"
  defp format_agent_type(:workstream), do: "Workstream Agent"
  defp format_agent_type(type) when is_atom(type), do: type |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  defp format_agent_type(type), do: to_string(type)

  defp split_threads(threads, show_resolved) do
    {questions, comments} =
      Enum.split_with(threads, fn {_id, messages} ->
        first = List.first(messages)
        first && first.metadata && (first.metadata[:is_question] || first.metadata["is_question"])
      end)

    filter_fn = fn {_id, messages} ->
      resolved? = thread_resolved?(messages)
      show_resolved or not resolved?
    end

    {
      Enum.filter(questions, filter_fn) |> Map.new(),
      Enum.filter(comments, filter_fn) |> Map.new()
    }
  end

  defp thread_resolved?(messages) do
    first = List.first(messages)
    !!(first && first.metadata && (first.metadata[:resolved?] || first.metadata["resolved?"]))
  end

  defp count_unanswered(question_threads) do
    Enum.count(question_threads, fn {_id, messages} -> not thread_resolved?(messages) end)
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    {questions, comments} = split_threads(assigns.review_threads, assigns.show_resolved)

    assigns =
      assigns
      |> assign(:questions, questions)
      |> assign(:comments, comments)
      |> assign(:unanswered_count, count_unanswered(questions))

    ~H"""
    <div class="min-h-screen bg-base-200">
      <header class="bg-base-100 shadow-sm border-b border-base-300">
        <div class="px-4 py-3 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <a href={~p"/pods/#{@task_id}"} class="text-base-content/60 hover:text-base-content">
              <.icon name="hero-arrow-left" class="w-5 h-5" />
            </a>
            <h1 class="text-xl font-semibold">{format_doc_type(@doc_type)} Review</h1>
          </div>
          <label class="label cursor-pointer gap-2">
            <span class="label-text text-sm">Show resolved</span>
            <input
              type="checkbox"
              class="toggle toggle-sm"
              checked={@show_resolved}
              phx-click="toggle_resolved"
            />
          </label>
        </div>
      </header>

      <main class="p-4 space-y-4">
        <!-- AI Workflow Section (Top Priority) -->
        <%= if @doc_type == :spec and not spec_approved?(@state) do %>
          <.ai_workflow_section
            doc_type={:spec}
            generation_status={@generation_status}
            related_agents={@related_agents}
            unanswered_count={@unanswered_count}
            agent_history_expanded={@agent_history_expanded}
          />
        <% end %>
        <%= if @doc_type == :plan and not plan_approved?(@state) do %>
          <.ai_workflow_section
            doc_type={:plan}
            generation_status={@generation_status}
            related_agents={@related_agents}
            unanswered_count={@unanswered_count}
            agent_history_expanded={@agent_history_expanded}
          />
        <% end %>
        <!-- Show agent activity when document is approved -->
        <%= if (@doc_type == :spec and spec_approved?(@state)) or (@doc_type == :plan and plan_approved?(@state)) do %>
          <%= if length(@related_agents) > 0 do %>
            <.agent_activity_bar related_agents={@related_agents} />
          <% end %>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Document Panel -->
          <div class="lg:col-span-2 space-y-4">
            <div class="card bg-base-100 shadow-sm border border-base-300">
              <div class="card-body p-0">
                <div class="p-4 border-b border-base-300 flex justify-between items-center">
                  <h2 class="font-semibold">Document</h2>
                  <span class="text-sm text-base-content/60">Select text to comment</span>
                </div>
                <%= if @document_content do %>
                  <div
                    id="document-content"
                    class="p-4 font-mono text-sm leading-relaxed overflow-x-auto max-h-[60vh] overflow-y-auto"
                    phx-hook="TextSelection"
                  >
                    <pre class="whitespace-pre-wrap break-words m-0"><%= @document_content %></pre>
                  </div>
                <% else %>
                  <div class="p-8 text-center text-base-content/60">
                    <.icon name="hero-document" class="w-12 h-12 mx-auto mb-4 opacity-50" />
                    <p>No content yet. Use the AI generator above to create one.</p>
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Comment Form (when text selected) -->
            <%= if @selected_text do %>
              <div class="card bg-base-100 shadow-sm border border-primary">
                <div class="card-body">
                  <div class="flex justify-between items-start">
                    <h3 class="font-semibold">Add Comment</h3>
                    <button phx-click="clear_selection" class="btn btn-ghost btn-xs btn-circle">
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                  <div class="bg-base-200 rounded p-2 mt-2">
                    <span class="text-xs text-base-content/60">Selected:</span>
                    <p class="text-sm font-mono mt-1 line-clamp-2">{@selected_text}</p>
                  </div>
                  <form phx-submit="post_comment" class="mt-3">
                    <textarea
                      name="content"
                      class="textarea textarea-bordered w-full"
                      placeholder="Your comment..."
                      rows="3"
                      required
                    ></textarea>
                    <div class="flex justify-end mt-2">
                      <button type="submit" class="btn btn-primary btn-sm">Post Comment</button>
                    </div>
                  </form>
                </div>
              </div>
            <% end %>
          </div>

          <!-- Threads Panel -->
          <div class="space-y-4" id="threads-panel">
            <!-- Agent Questions (Priority) -->
            <%= if map_size(@questions) > 0 do %>
              <div class="card bg-base-100 shadow-sm border-2 border-warning" id="questions-section">
                <div class="card-body p-0">
                  <div
                    class="p-4 cursor-pointer hover:bg-base-200/50 flex justify-between items-center bg-warning/10"
                    phx-click="toggle_questions"
                  >
                    <h2 class="font-semibold flex items-center gap-2">
                      <.icon name="hero-question-mark-circle" class="w-5 h-5 text-warning" />
                      Agent Questions
                      <%= if @unanswered_count > 0 do %>
                        <span class="badge badge-warning badge-sm">{@unanswered_count} need response</span>
                      <% end %>
                    </h2>
                    <.icon
                      name={if @questions_collapsed, do: "hero-chevron-down", else: "hero-chevron-up"}
                      class="w-4 h-4"
                    />
                  </div>

                  <%= unless @questions_collapsed do %>
                    <div class="px-4 pb-4 space-y-2">
                      <%= for {thread_id, messages} <- @questions do %>
                        <.thread_card
                          thread_id={thread_id}
                          messages={messages}
                          active={@active_thread_id == thread_id}
                        />
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <!-- Comments -->
            <div class="card bg-base-100 shadow-sm border border-base-300">
              <div class="card-body">
                <h2 class="font-semibold flex items-center gap-2 mb-4">
                  <.icon name="hero-chat-bubble-left-right" class="w-5 h-5" />
                  Comments
                  <span class="badge badge-sm">{map_size(@comments)}</span>
                </h2>

                <%= if map_size(@comments) == 0 do %>
                  <div class="text-center py-6 text-base-content/60">
                    <.icon name="hero-chat-bubble-left" class="w-10 h-10 mx-auto mb-2 opacity-50" />
                    <p class="text-sm">No comments yet</p>
                  </div>
                <% else %>
                  <div class="space-y-2">
                    <%= for {thread_id, messages} <- @comments do %>
                      <.thread_card
                        thread_id={thread_id}
                        messages={messages}
                        active={@active_thread_id == thread_id}
                      />
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </main>

      <!-- Agent Detail Modal -->
      <%= if @selected_agent_id do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-4xl h-[80vh] p-0 flex flex-col">
            <div class="flex justify-between items-center p-4 border-b border-base-300">
              <h3 class="font-bold text-lg">Agent Details</h3>
              <button phx-click="close_agent_modal" class="btn btn-ghost btn-sm btn-circle">
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>
            <div class="flex-1 overflow-hidden">
              {live_render(@socket, IpaWeb.Pod.AgentDetailLive,
                id: "agent-detail-#{@selected_agent_id}",
                session: %{"task_id" => @task_id, "agent_id" => @selected_agent_id}
              )}
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_agent_modal"></div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Components
  # ============================================================================

  attr :thread_id, :string, required: true
  attr :messages, :list, required: true
  attr :active, :boolean, default: false

  defp thread_card(assigns) do
    first_msg = List.first(assigns.messages)
    resolved? = thread_resolved?(assigns.messages)
    reply_count = length(assigns.messages) - 1
    anchor = first_msg && first_msg.metadata && (first_msg.metadata[:document_anchor] || first_msg.metadata["document_anchor"])

    assigns =
      assigns
      |> assign(:first_msg, first_msg)
      |> assign(:resolved?, resolved?)
      |> assign(:reply_count, reply_count)
      |> assign(:anchor, anchor)

    ~H"""
    <div class={"border rounded-lg overflow-hidden #{if @resolved?, do: "border-success/30 bg-success/5", else: "border-base-300"}"}>
      <div
        class="p-3 cursor-pointer hover:bg-base-200"
        phx-click="select_thread"
        phx-value-id={@thread_id}
      >
        <div class="flex items-start justify-between">
          <div class="flex-1 min-w-0">
            <%= if @resolved? do %>
              <span class="badge badge-success badge-xs mb-1">Resolved</span>
            <% end %>
            <p class="text-sm font-medium">{@first_msg && @first_msg.author}</p>
            <p class="text-xs text-base-content/70 line-clamp-2 mt-1">
              {truncate(@first_msg && @first_msg.content, 120)}
            </p>
          </div>
          <%= if @reply_count > 0 do %>
            <span class="badge badge-ghost badge-sm ml-2">{@reply_count}</span>
          <% end %>
        </div>
        <%= if @anchor && @anchor[:line_start] && @anchor[:line_start] > 0 do %>
          <div class="text-xs text-base-content/50 mt-1">
            Line {@anchor[:line_start] || @anchor["line_start"]}
          </div>
        <% end %>
      </div>

      <%= if @active do %>
        <div class="border-t border-base-300 bg-base-200/50">
          <div class="p-3 space-y-2 max-h-64 overflow-y-auto">
            <%= for msg <- @messages do %>
              <div class="bg-base-100 rounded p-2">
                <div class="flex justify-between items-center">
                  <span class="text-sm font-medium">{msg.author}</span>
                  <span class="text-xs text-base-content/50">{format_timestamp(msg.posted_at)}</span>
                </div>
                <p class="text-sm mt-1 whitespace-pre-wrap">{msg.content}</p>
              </div>
            <% end %>
          </div>

          <form phx-submit="post_reply" class="p-3 border-t border-base-300">
            <input type="hidden" name="thread_id" value={@thread_id} />
            <textarea
              name="content"
              class="textarea textarea-bordered textarea-sm w-full"
              placeholder="Write a reply..."
              rows="2"
              required
            ></textarea>
            <div class="flex justify-between items-center mt-2">
              <%= unless @resolved? do %>
                <button
                  type="button"
                  phx-click="resolve_thread"
                  phx-value-id={@thread_id}
                  class="btn btn-ghost btn-xs text-success"
                >
                  <.icon name="hero-check" class="w-3 h-3" /> Resolve
                </button>
              <% else %>
                <div></div>
              <% end %>
              <button type="submit" class="btn btn-primary btn-xs">Reply</button>
            </div>
          </form>
        </div>
      <% end %>
    </div>
    """
  end

  # AI Workflow Section - Dynamic for spec or plan generation
  attr :doc_type, :atom, required: true
  attr :generation_status, :atom, required: true
  attr :related_agents, :list, required: true
  attr :unanswered_count, :integer, required: true
  attr :agent_history_expanded, :boolean, required: true

  defp ai_workflow_section(assigns) do
    active_agent = Enum.find(assigns.related_agents, fn a -> a.status in [:running, :awaiting_input] end)
    has_completed = Enum.any?(assigns.related_agents, fn a -> a.status == :completed end)
    # Completed agents for history (exclude currently active)
    completed_agents = Enum.filter(assigns.related_agents, fn a ->
      a.status in [:completed, :failed] and (active_agent == nil or a.agent_id != active_agent.agent_id)
    end)

    # Dynamic content based on doc_type
    {title, description_new, description_iterate, placeholder_new, placeholder_iterate, submit_event, generating_text} =
      case assigns.doc_type do
        :spec ->
          {"AI Spec Generator",
           "Generate a specification from your requirements",
           "Iterate on your spec with AI assistance",
           "e.g., A REST API for user management...",
           "e.g., Add error handling section...",
           "generate_spec",
           "Generating specification..."}
        :plan ->
          {"AI Plan Generator",
           "Generate a workstream plan from the specification",
           "Iterate on your plan with AI assistance",
           "e.g., Break this into parallel workstreams...",
           "e.g., Split the database workstream further...",
           "generate_plan",
           "Generating plan..."}
        _ ->
          {"AI Generator", "Generate content", "Iterate on content", "...", "...", "generate_content", "Generating..."}
      end

    assigns =
      assigns
      |> assign(:active_agent, active_agent)
      |> assign(:has_completed, has_completed)
      |> assign(:completed_agents, completed_agents)
      |> assign(:title, title)
      |> assign(:description_new, description_new)
      |> assign(:description_iterate, description_iterate)
      |> assign(:placeholder_new, placeholder_new)
      |> assign(:placeholder_iterate, placeholder_iterate)
      |> assign(:submit_event, submit_event)
      |> assign(:generating_text, generating_text)

    ~H"""
    <div class="card bg-base-100 shadow-sm border border-primary/20">
      <div class="card-body p-4">
        <!-- Header -->
        <div class="flex items-center gap-3">
          <div class="w-10 h-10 rounded-xl bg-primary/10 flex items-center justify-center">
            <.icon name="hero-sparkles" class="w-5 h-5 text-primary" />
          </div>
          <div class="flex-1">
            <h3 class="text-sm font-semibold">{@title}</h3>
            <p class="text-xs text-base-content/60">
              <%= if @has_completed, do: @description_iterate, else: @description_new %>
            </p>
          </div>
          <.generation_status_badge status={@generation_status} />
        </div>

        <!-- Active Agent Status -->
        <%= if @active_agent do %>
          <div class={[
            "rounded-lg px-3 py-3 mt-4",
            @active_agent.status == :running && "bg-info/10 border border-info/20",
            @active_agent.status == :awaiting_input && "bg-warning/10 border border-warning/20"
          ]}>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <%= if @active_agent.status == :running do %>
                  <span class="loading loading-spinner loading-sm text-info"></span>
                  <span class="text-xs font-medium">{@generating_text}</span>
                <% else %>
                  <.icon name="hero-chat-bubble-left-ellipsis" class="w-4 h-4 text-warning" />
                  <span class="text-xs">
                    <span class="font-medium">{@unanswered_count}</span> question(s) need your response
                  </span>
                <% end %>
              </div>
              <button
                class="btn btn-ghost btn-xs"
                phx-click="view_agent"
                phx-value-agent-id={@active_agent.agent_id}
              >
                View <.icon name="hero-arrow-right" class="w-3 h-3" />
              </button>
            </div>
          </div>
        <% end %>

        <!-- Input Form -->
        <%= if @generation_status in [:idle, :completed] and @active_agent == nil do %>
          <form phx-submit={@submit_event} class="mt-4">
            <label class="text-xs text-base-content/70 mb-1 block">
              <%= if @has_completed, do: "Describe changes or additional requirements", else: "What should this cover?" %>
            </label>
            <div class="flex gap-2">
              <input
                type="text"
                name="input"
                class="input input-bordered input-sm flex-1 text-sm"
                placeholder={if @has_completed, do: @placeholder_iterate, else: @placeholder_new}
                required
              />
              <button type="submit" class="btn btn-primary btn-sm gap-1">
                <.icon name="hero-sparkles" class="w-4 h-4" />
                <%= if @has_completed, do: "Iterate", else: "Generate" %>
              </button>
            </div>
          </form>
        <% end %>

        <!-- Previous Runs (Collapsed by default) -->
        <%= if length(@completed_agents) > 0 do %>
          <div class="mt-4 pt-3 border-t border-base-200">
            <button
              class="flex items-center justify-between w-full text-xs text-base-content/60 hover:text-base-content"
              phx-click="toggle_agent_history"
            >
              <span class="flex items-center gap-1">
                <.icon name="hero-clock" class="w-3 h-3" />
                Previous runs ({length(@completed_agents)})
              </span>
              <.icon
                name={if @agent_history_expanded, do: "hero-chevron-up", else: "hero-chevron-down"}
                class="w-3 h-3"
              />
            </button>

            <%= if @agent_history_expanded do %>
              <div class="mt-2 space-y-1">
                <%= for agent <- @completed_agents do %>
                  <% {status_text, badge_class} = format_agent_status(agent.status) %>
                  <button
                    class="flex items-center justify-between w-full p-2 rounded hover:bg-base-200 text-left"
                    phx-click="view_agent"
                    phx-value-agent-id={agent.agent_id}
                  >
                    <div class="flex items-center gap-2">
                      <span class={"badge badge-xs #{badge_class}"}>{status_text}</span>
                      <span class="text-xs text-base-content/70">{format_agent_type(agent.agent_type)}</span>
                    </div>
                    <span class="text-xs text-base-content/50">
                      <%= if agent.completed_at do %>
                        {format_timestamp(agent.completed_at)}
                      <% end %>
                    </span>
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Compact agent activity bar for when spec is approved
  attr :related_agents, :list, required: true

  defp agent_activity_bar(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body py-3 px-4">
        <div class="flex items-center justify-between">
          <h3 class="text-sm font-medium flex items-center gap-2">
            <.icon name="hero-cpu-chip" class="w-4 h-4 text-base-content/70" />
            Agent Activity
          </h3>
          <div class="flex flex-wrap gap-2">
            <%= for agent <- @related_agents do %>
              <% {status_text, badge_class} = format_agent_status(agent.status) %>
              <button
                class={"badge badge-sm #{badge_class} gap-1 cursor-pointer hover:opacity-80"}
                phx-click="view_agent"
                phx-value-agent-id={agent.agent_id}
              >
                {format_agent_type(agent.agent_type)}
                <span class="text-xs opacity-70">{status_text}</span>
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Generation status badge
  attr :status, :atom, required: true

  defp generation_status_badge(assigns) do
    ~H"""
    <%= case @status do %>
      <% :generating -> %>
        <span class="badge badge-info gap-1">
          <span class="loading loading-spinner loading-xs"></span>
          Generating
        </span>
      <% :completed -> %>
        <span class="badge badge-success gap-1">
          <.icon name="hero-check" class="w-3 h-3" />
          Generated
        </span>
      <% _ -> %>
        <span class="badge badge-ghost">Ready</span>
    <% end %>
    """
  end
end
