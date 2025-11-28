defmodule IpaWeb.Pod.DocumentReviewLive do
  @moduledoc """
  LiveView for reviewing documents (Spec, Plan, Report) with inline commenting.

  Features:
  - Read-only document display with line numbers
  - Text selection to attach comments
  - Threaded comment discussions
  - Mark threads as resolved/reopen
  - Real-time updates via PubSub
  """
  use IpaWeb, :live_view

  alias Ipa.Pod.Manager
  alias Ipa.Pod.State

  require Logger

  @valid_doc_types ~w(spec plan report)a

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

          document_content = get_document_content(state, doc_type)
          review_threads = State.get_review_threads(state, doc_type)

          socket =
            socket
            |> assign(task_id: task_id)
            |> assign(doc_type: doc_type)
            |> assign(state: state)
            |> assign(document_content: document_content)
            |> assign(document_lines: split_into_lines(document_content))
            |> assign(review_threads: review_threads)
            |> assign(selected_text: nil)
            |> assign(selection_anchor: nil)
            |> assign(comment_input: "")
            |> assign(active_thread_id: nil)
            |> assign(reply_input: "")
            |> assign(show_resolved: false)

          {:ok, socket}

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

  defp parse_doc_type("spec"), do: :spec
  defp parse_doc_type("plan"), do: :plan
  defp parse_doc_type("report"), do: :report
  defp parse_doc_type(_), do: nil

  defp get_document_content(state, :spec) do
    spec = state.spec || %{}

    description = spec[:description] || spec["description"] || ""
    requirements = spec[:requirements] || spec["requirements"] || []
    acceptance_criteria = spec[:acceptance_criteria] || spec["acceptance_criteria"] || []

    """
    # Specification

    ## Description

    #{description}

    ## Requirements

    #{format_list(requirements)}

    ## Acceptance Criteria

    #{format_list(acceptance_criteria)}
    """
  end

  defp get_document_content(state, :plan) do
    plan = state.plan

    if plan do
      workstreams = plan[:workstreams] || plan["workstreams"] || []
      steps = plan[:steps] || plan["steps"] || []

      workstreams_md =
        workstreams
        |> Enum.map(fn ws ->
          id = ws[:id] || ws["id"]
          title = ws[:title] || ws["title"]
          desc = ws[:description] || ws["description"]
          deps = ws[:dependencies] || ws["dependencies"] || []
          deps_str = if Enum.empty?(deps), do: "None", else: Enum.join(deps, ", ")

          """
          ### #{id}: #{title}

          #{desc}

          **Dependencies:** #{deps_str}
          """
        end)
        |> Enum.join("\n")

      steps_md =
        if Enum.empty?(steps) do
          ""
        else
          steps_list =
            steps
            |> Enum.with_index(1)
            |> Enum.map(fn {step, i} ->
              step_text = if is_binary(step), do: step, else: step[:description] || step["description"] || inspect(step)
              "#{i}. #{step_text}"
            end)
            |> Enum.join("\n")

          """
          ## Steps

          #{steps_list}
          """
        end

      """
      # Plan

      ## Workstreams

      #{workstreams_md}

      #{steps_md}
      """
    else
      "# Plan\n\nNo plan has been created yet."
    end
  end

  defp get_document_content(_state, :report) do
    "# Final Report\n\nNo report available yet."
  end

  defp format_list([]), do: "_No items_"

  defp format_list(items) do
    items
    |> Enum.map(fn item ->
      text = if is_binary(item), do: item, else: item[:text] || item["text"] || inspect(item)
      "- #{text}"
    end)
    |> Enum.join("\n")
  end

  defp split_into_lines(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, num} -> %{number: num, content: line} end)
  end

  defp split_into_lines(_), do: []

  # Real-time updates
  @impl true
  def handle_info({:event_appended, task_id, _event}, socket)
      when task_id == socket.assigns.task_id do
    reload_state(socket)
  end

  def handle_info({:state_updated, _task_id, new_state}, socket) when not is_nil(new_state) do
    doc_type = socket.assigns.doc_type
    document_content = get_document_content(new_state, doc_type)
    review_threads = State.get_review_threads(new_state, doc_type)

    {:noreply,
     socket
     |> assign(state: new_state)
     |> assign(document_content: document_content)
     |> assign(document_lines: split_into_lines(document_content))
     |> assign(review_threads: review_threads)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload_state(socket) do
    task_id = socket.assigns.task_id
    doc_type = socket.assigns.doc_type

    case Manager.get_state_from_events(task_id) do
      {:ok, state} ->
        document_content = get_document_content(state, doc_type)
        review_threads = State.get_review_threads(state, doc_type)

        {:noreply,
         socket
         |> assign(state: state)
         |> assign(document_content: document_content)
         |> assign(document_lines: split_into_lines(document_content))
         |> assign(review_threads: review_threads)}

      _ ->
        {:noreply, socket}
    end
  end

  # Event handlers

  @impl true
  def handle_event("text_selected", params, socket) do
    selected_text = params["text"]
    surrounding_text = params["surrounding"]
    line_start = params["lineStart"] |> parse_int(1)
    line_end = params["lineEnd"] |> parse_int(line_start)

    anchor = %{
      selected_text: selected_text,
      surrounding_text: surrounding_text,
      line_start: line_start,
      line_end: line_end
    }

    {:noreply,
     socket
     |> assign(selected_text: selected_text)
     |> assign(selection_anchor: anchor)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(selected_text: nil)
     |> assign(selection_anchor: nil)
     |> assign(comment_input: "")}
  end

  def handle_event("update_comment", %{"value" => value}, socket) do
    {:noreply, assign(socket, comment_input: value)}
  end

  def handle_event("post_comment", _params, socket) do
    %{
      task_id: task_id,
      doc_type: doc_type,
      selection_anchor: anchor,
      comment_input: content
    } = socket.assigns

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
         |> assign(selected_text: nil)
         |> assign(selection_anchor: nil)
         |> assign(comment_input: "")
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
    {:noreply, assign(socket, active_thread_id: thread_id)}
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply,
     socket
     |> assign(active_thread_id: nil)
     |> assign(reply_input: "")}
  end

  def handle_event("update_reply", %{"value" => value}, socket) do
    {:noreply, assign(socket, reply_input: value)}
  end

  def handle_event("post_reply", _params, socket) do
    %{
      task_id: task_id,
      doc_type: doc_type,
      active_thread_id: thread_id,
      reply_input: content,
      review_threads: threads
    } = socket.assigns

    if String.trim(content) != "" and thread_id do
      # Get the original thread's anchor from the first message
      thread_messages = Map.get(threads, thread_id, [])
      first_message = List.first(thread_messages)

      anchor =
        if first_message && first_message.metadata do
          first_message.metadata[:document_anchor] || first_message.metadata["document_anchor"]
        end

      if anchor do
        params = %{
          author: "user",
          content: content,
          document_type: doc_type,
          document_anchor: anchor,
          thread_id: thread_id
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
           |> assign(reply_input: "")
           |> put_flash(:info, "Reply posted")}
        else
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to post reply: #{inspect(reason)}")}
        end
      else
        {:noreply, put_flash(socket, :error, "Could not find thread anchor")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("resolve_thread", %{"id" => thread_id}, socket) do
    %{task_id: task_id} = socket.assigns

    params = %{
      thread_id: thread_id,
      resolved_by: "user"
    }

    with :ok <- ensure_pod_running(task_id),
         {:ok, _version} <-
           Manager.execute(
             task_id,
             Ipa.Pod.Commands.ReviewCommands,
             :resolve_thread,
             [params]
           ) do
      {:noreply, put_flash(socket, :info, "Thread resolved")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resolve: #{inspect(reason)}")}
    end
  end

  def handle_event("reopen_thread", %{"id" => thread_id}, socket) do
    %{task_id: task_id} = socket.assigns

    params = %{
      thread_id: thread_id,
      reopened_by: "user"
    }

    with :ok <- ensure_pod_running(task_id),
         {:ok, _version} <-
           Manager.execute(
             task_id,
             Ipa.Pod.Commands.ReviewCommands,
             :reopen_thread,
             [params]
           ) do
      {:noreply, put_flash(socket, :info, "Thread reopened")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reopen: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_resolved", _params, socket) do
    {:noreply, assign(socket, show_resolved: !socket.assigns.show_resolved)}
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <!-- Header -->
      <header class="bg-base-100 shadow-sm border-b border-base-300">
        <div class="px-4 py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <a href={~p"/pods/#{@task_id}"} class="text-base-content/60 hover:text-base-content">
                <.icon name="hero-arrow-left" class="w-5 h-5" />
              </a>
              <h1 class="text-xl font-semibold text-base-content">
                Review: {format_doc_type(@doc_type)}
              </h1>
              <span class={"badge #{doc_type_badge(@doc_type)}"}>
                {String.upcase(to_string(@doc_type))}
              </span>
            </div>
            <div class="flex items-center gap-2">
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
          </div>
        </div>
      </header>

      <!-- Main Content -->
      <main class="p-4">
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Document Panel -->
          <div class="lg:col-span-2">
            <div class="card bg-base-100 shadow-sm border border-base-300">
              <div class="card-body p-0">
                <div class="p-4 border-b border-base-300 flex items-center justify-between">
                  <h2 class="font-semibold">Document Content</h2>
                  <span class="text-sm text-base-content/60">
                    Select text to add a comment
                  </span>
                </div>
                <div
                  id="document-content"
                  class="p-4 font-mono text-sm overflow-x-auto"
                  phx-hook="TextSelection"
                >
                  <%= for line <- @document_lines do %>
                    <div class="flex hover:bg-base-200 group" data-line={line.number}>
                      <span class="w-12 text-right pr-4 text-base-content/40 select-none flex-shrink-0">
                        {line.number}
                      </span>
                      <span class="flex-1 whitespace-pre-wrap break-words">
                        <%= if String.trim(line.content) == "" do %>
                          <br />
                        <% else %>
                          {line.content}
                        <% end %>
                      </span>
                      <%= if has_comment_at_line?(@review_threads, line.number) do %>
                        <span class="ml-2 text-warning flex-shrink-0">
                          <.icon name="hero-chat-bubble-left" class="w-4 h-4" />
                        </span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <!-- Comment Input (shown when text is selected) -->
            <%= if @selected_text do %>
              <div class="card bg-base-100 shadow-sm border border-primary mt-4">
                <div class="card-body">
                  <div class="flex items-start justify-between">
                    <h3 class="font-semibold text-sm">Add Comment</h3>
                    <button
                      phx-click="clear_selection"
                      class="btn btn-ghost btn-xs btn-circle"
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                  <div class="bg-base-200 rounded p-2 mt-2">
                    <span class="text-xs text-base-content/60">Selected text:</span>
                    <p class="text-sm font-mono mt-1 line-clamp-3">{@selected_text}</p>
                  </div>
                  <textarea
                    class="textarea textarea-bordered w-full mt-3"
                    placeholder="Write your comment..."
                    rows="3"
                    phx-keyup="update_comment"
                  ><%= @comment_input %></textarea>
                  <div class="flex justify-end mt-2">
                    <button
                      phx-click="post_comment"
                      class="btn btn-primary btn-sm"
                      disabled={String.trim(@comment_input) == ""}
                    >
                      Post Comment
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <!-- Comments Panel -->
          <div class="lg:col-span-1">
            <div class="card bg-base-100 shadow-sm border border-base-300 sticky top-4">
              <div class="card-body">
                <h2 class="font-semibold mb-4 flex items-center gap-2">
                  <.icon name="hero-chat-bubble-left-right" class="w-5 h-5" />
                  Comments
                  <span class="badge badge-sm">{thread_count(@review_threads, @show_resolved)}</span>
                </h2>

                <%= if map_size(@review_threads) == 0 do %>
                  <div class="text-center py-8 text-base-content/60">
                    <.icon name="hero-chat-bubble-left" class="w-12 h-12 mx-auto mb-4 opacity-50" />
                    <p>No comments yet.</p>
                    <p class="text-sm">Select text in the document to add a comment.</p>
                  </div>
                <% else %>
                  <div class="space-y-3 max-h-[600px] overflow-y-auto">
                    <%= for {thread_id, messages} <- @review_threads do %>
                      <.thread_card
                        thread_id={thread_id}
                        messages={messages}
                        active={@active_thread_id == thread_id}
                        show_resolved={@show_resolved}
                        reply_input={@reply_input}
                      />
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  defp thread_card(assigns) do
    first_msg = List.first(assigns.messages)
    is_resolved = first_msg && first_msg.metadata && (first_msg.metadata[:resolved?] || first_msg.metadata["resolved?"])

    # Skip resolved threads if not showing them
    if is_resolved and not assigns.show_resolved do
      ~H"""
      """
    else
      anchor = if first_msg && first_msg.metadata do
        first_msg.metadata[:document_anchor] || first_msg.metadata["document_anchor"]
      end

      assigns =
        assigns
        |> assign(:first_msg, first_msg)
        |> assign(:is_resolved, is_resolved)
        |> assign(:anchor, anchor)
        |> assign(:reply_count, length(assigns.messages) - 1)

      ~H"""
      <div class={"border rounded-lg overflow-hidden #{if @is_resolved, do: "border-success/30 bg-success/5", else: "border-base-300"}"}>
        <!-- Thread Header -->
        <div
          class="p-3 cursor-pointer hover:bg-base-200"
          phx-click="select_thread"
          phx-value-id={@thread_id}
        >
          <div class="flex items-start justify-between">
            <div class="flex-1 min-w-0">
              <%= if @is_resolved do %>
                <span class="badge badge-success badge-sm mb-1">Resolved</span>
              <% end %>
              <p class="text-sm font-medium truncate">{@first_msg && @first_msg.author}</p>
              <p class="text-xs text-base-content/60 line-clamp-2 mt-1">
                {truncate(@first_msg && @first_msg.content, 100)}
              </p>
            </div>
            <%= if @reply_count > 0 do %>
              <span class="badge badge-sm badge-ghost ml-2">{@reply_count} replies</span>
            <% end %>
          </div>
          <%= if @anchor do %>
            <div class="mt-2 text-xs text-base-content/50">
              Lines {@anchor[:line_start] || @anchor["line_start"]}-{@anchor[:line_end] || @anchor["line_end"]}
            </div>
          <% end %>
        </div>

        <!-- Expanded Thread -->
        <%= if @active do %>
          <div class="border-t border-base-300 bg-base-200/50">
            <!-- All messages in thread -->
            <div class="p-3 space-y-3 max-h-64 overflow-y-auto">
              <%= for msg <- @messages do %>
                <div class="bg-base-100 rounded p-2">
                  <div class="flex items-center justify-between">
                    <span class="text-sm font-medium">{msg.author}</span>
                    <span class="text-xs text-base-content/50">
                      {format_timestamp(msg.posted_at)}
                    </span>
                  </div>
                  <p class="text-sm mt-1">{msg.content}</p>
                </div>
              <% end %>
            </div>

            <!-- Reply Input -->
            <div class="p-3 border-t border-base-300">
              <textarea
                class="textarea textarea-bordered textarea-sm w-full"
                placeholder="Write a reply..."
                rows="2"
                phx-keyup="update_reply"
              ><%= @reply_input %></textarea>
              <div class="flex items-center justify-between mt-2">
                <div class="flex gap-2">
                  <%= if @is_resolved do %>
                    <button
                      phx-click="reopen_thread"
                      phx-value-id={@thread_id}
                      class="btn btn-ghost btn-xs"
                    >
                      Reopen
                    </button>
                  <% else %>
                    <button
                      phx-click="resolve_thread"
                      phx-value-id={@thread_id}
                      class="btn btn-ghost btn-xs text-success"
                    >
                      <.icon name="hero-check" class="w-3 h-3" /> Resolve
                    </button>
                  <% end %>
                </div>
                <div class="flex gap-2">
                  <button
                    phx-click="close_thread"
                    class="btn btn-ghost btn-xs"
                  >
                    Close
                  </button>
                  <button
                    phx-click="post_reply"
                    class="btn btn-primary btn-xs"
                    disabled={String.trim(@reply_input) == ""}
                  >
                    Reply
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
      """
    end
  end

  defp format_doc_type(:spec), do: "Specification"
  defp format_doc_type(:plan), do: "Plan"
  defp format_doc_type(:report), do: "Final Report"
  defp format_doc_type(other), do: to_string(other)

  defp doc_type_badge(:spec), do: "badge-warning"
  defp doc_type_badge(:plan), do: "badge-info"
  defp doc_type_badge(:report), do: "badge-success"
  defp doc_type_badge(_), do: "badge-ghost"

  defp has_comment_at_line?(threads, line_number) do
    Enum.any?(threads, fn {_thread_id, messages} ->
      first_msg = List.first(messages)

      if first_msg && first_msg.metadata do
        anchor = first_msg.metadata[:document_anchor] || first_msg.metadata["document_anchor"]

        if anchor do
          line_start = anchor[:line_start] || anchor["line_start"] || 0
          line_end = anchor[:line_end] || anchor["line_end"] || line_start
          line_number >= line_start and line_number <= line_end
        else
          false
        end
      else
        false
      end
    end)
  end

  defp thread_count(threads, show_resolved) do
    if show_resolved do
      map_size(threads)
    else
      Enum.count(threads, fn {_id, messages} ->
        first_msg = List.first(messages)
        not (first_msg && first_msg.metadata && (first_msg.metadata[:resolved?] || first_msg.metadata["resolved?"]))
      end)
    end
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."

  defp format_timestamp(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%b %d, %H:%M")
  end

  defp format_timestamp(_), do: ""
end
