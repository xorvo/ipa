defmodule IpaWeb.DashboardLive do
  @moduledoc """
  Central Dashboard LiveView for listing and managing tasks.

  Provides:
  - List of all tasks with status
  - Task creation
  - Navigation to individual task pods
  - Quick stats overview
  """
  use IpaWeb, :live_view

  alias Ipa.CentralManager

  @impl true
  def mount(_params, _session, socket) do
    tasks = CentralManager.list_tasks(include_completed: false)

    socket =
      socket
      |> assign(tasks: tasks)
      |> assign(show_create_modal: false)
      |> assign(new_task_title: "")
      |> assign(include_completed: false)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_completed", _params, socket) do
    include_completed = !socket.assigns.include_completed
    tasks = CentralManager.list_tasks(include_completed: include_completed)

    {:noreply,
     socket
     |> assign(include_completed: include_completed)
     |> assign(tasks: tasks)}
  end

  def handle_event("show_create_modal", _params, socket) do
    {:noreply, assign(socket, show_create_modal: true)}
  end

  def handle_event("hide_create_modal", _params, socket) do
    {:noreply, assign(socket, show_create_modal: false, new_task_title: "")}
  end

  def handle_event("update_title", %{"title" => value}, socket) do
    {:noreply, assign(socket, new_task_title: value)}
  end

  def handle_event("create_task", %{"title" => title}, socket) do
    title = String.trim(title)

    if title != "" do
      case CentralManager.create_task(title, "user") do
        {:ok, task_id} ->
          # Start the pod for the new task
          CentralManager.start_pod(task_id)

          # Refresh task list
          tasks = CentralManager.list_tasks(include_completed: socket.assigns.include_completed)

          {:noreply,
           socket
           |> assign(tasks: tasks)
           |> assign(show_create_modal: false)
           |> assign(new_task_title: "")
           |> put_flash(:info, "Task created successfully")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create task: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Task title cannot be empty")}
    end
  end

  def handle_event("start_pod", %{"task_id" => task_id}, socket) do
    case CentralManager.start_pod(task_id) do
      {:ok, _pid} ->
        tasks = CentralManager.list_tasks(include_completed: socket.assigns.include_completed)
        {:noreply, socket |> assign(tasks: tasks) |> put_flash(:info, "Pod started")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start pod: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_pod", %{"task_id" => task_id}, socket) do
    case CentralManager.stop_pod(task_id) do
      :ok ->
        tasks = CentralManager.list_tasks(include_completed: socket.assigns.include_completed)
        {:noreply, socket |> assign(tasks: tasks) |> put_flash(:info, "Pod stopped")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop pod: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh", _params, socket) do
    tasks = CentralManager.list_tasks(include_completed: socket.assigns.include_completed)
    {:noreply, assign(socket, tasks: tasks)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <!-- Header -->
      <header class="bg-base-100 shadow-sm border-b border-base-300">
        <div class="max-w-7xl mx-auto px-4 py-6">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-2xl font-bold text-base-content">IPA Dashboard</h1>
              <p class="text-sm text-base-content/60 mt-1">Intelligent Process Automation</p>
            </div>
            <button phx-click="show_create_modal" class="btn btn-primary">
              <.icon name="hero-plus" class="w-5 h-5" />
              New Task
            </button>
          </div>
        </div>
      </header>

      <!-- Stats Bar -->
      <div class="bg-base-100 border-b border-base-300">
        <div class="max-w-7xl mx-auto px-4 py-4">
          <div class="flex items-center gap-8">
            <div class="flex items-center gap-2">
              <div class="badge badge-lg badge-primary"><%= length(@tasks) %></div>
              <span class="text-sm text-base-content/60">Total Tasks</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="badge badge-lg badge-success"><%= count_running_pods(@tasks) %></div>
              <span class="text-sm text-base-content/60">Running Pods</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="badge badge-lg badge-info"><%= total_workstreams(@tasks) %></div>
              <span class="text-sm text-base-content/60">Workstreams</span>
            </div>
            <div class="flex-1"></div>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                checked={@include_completed}
                phx-click="toggle_completed"
              />
              <span class="text-sm">Show completed</span>
            </label>
            <button phx-click="refresh" class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-path" class="w-4 h-4" />
              Refresh
            </button>
          </div>
        </div>
      </div>

      <!-- Task List -->
      <main class="max-w-7xl mx-auto px-4 py-6">
        <%= if Enum.empty?(@tasks) do %>
          <div class="text-center py-16">
            <.icon name="hero-inbox" class="w-16 h-16 mx-auto text-base-content/30 mb-4" />
            <h2 class="text-xl font-medium text-base-content/60">No tasks yet</h2>
            <p class="text-base-content/40 mt-2">Create your first task to get started.</p>
            <button phx-click="show_create_modal" class="btn btn-primary mt-4">
              Create Task
            </button>
          </div>
        <% else %>
          <div class="grid gap-4">
            <%= for task <- @tasks do %>
              <.task_card task={task} />
            <% end %>
          </div>
        <% end %>
      </main>

      <!-- Create Task Modal -->
      <%= if @show_create_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg">Create New Task</h3>
            <form phx-submit="create_task" phx-change="update_title">
              <div class="py-4">
                <label class="label">
                  <span class="label-text">Task Title</span>
                </label>
                <input
                  type="text"
                  name="title"
                  placeholder="Enter task title..."
                  class="input input-bordered w-full"
                  value={@new_task_title}
                  autofocus
                />
              </div>
              <div class="modal-action">
                <button type="button" phx-click="hide_create_modal" class="btn btn-ghost">Cancel</button>
                <button type="submit" class="btn btn-primary">Create</button>
              </div>
            </form>
          </div>
          <div class="modal-backdrop" phx-click="hide_create_modal"></div>
        </div>
      <% end %>
    </div>
    """
  end

  defp task_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300 hover:shadow-md transition-shadow">
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div class="flex-1">
            <.link navigate={~p"/pods/#{@task.task_id}"} class="hover:underline">
              <h2 class="card-title text-lg"><%= @task.title %></h2>
            </.link>
            <p class="text-sm text-base-content/60 mt-1">
              <code class="bg-base-200 px-1 rounded text-xs"><%= String.slice(@task.task_id, 0, 20) %>...</code>
            </p>
          </div>

          <div class="flex items-center gap-2">
            <.phase_badge phase={@task.phase} />
            <%= if @task.pod_running do %>
              <span class="badge badge-success badge-sm">Running</span>
            <% else %>
              <span class="badge badge-ghost badge-sm">Stopped</span>
            <% end %>
          </div>
        </div>

        <div class="flex items-center justify-between mt-4 pt-4 border-t border-base-200">
          <div class="flex items-center gap-4 text-sm text-base-content/60">
            <span class="flex items-center gap-1">
              <.icon name="hero-queue-list" class="w-4 h-4" />
              <%= @task.workstream_count %> workstreams
            </span>
            <%= if @task.unread_count > 0 do %>
              <span class="flex items-center gap-1 text-warning">
                <.icon name="hero-bell" class="w-4 h-4" />
                <%= @task.unread_count %> unread
              </span>
            <% end %>
          </div>

          <div class="flex items-center gap-2">
            <%= if @task.pod_running do %>
              <button
                phx-click="stop_pod"
                phx-value-task_id={@task.task_id}
                class="btn btn-ghost btn-sm"
              >
                Stop Pod
              </button>
            <% else %>
              <button
                phx-click="start_pod"
                phx-value-task_id={@task.task_id}
                class="btn btn-ghost btn-sm"
              >
                Start Pod
              </button>
            <% end %>
            <.link navigate={~p"/pods/#{@task.task_id}"} class="btn btn-primary btn-sm">
              Open
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp phase_badge(assigns) do
    assigns = assign(assigns, :color, phase_color(assigns.phase))

    ~H"""
    <span class={"badge #{@color}"}>
      <%= format_phase(@phase) %>
    </span>
    """
  end

  defp phase_color(phase) do
    case phase do
      :spec_clarification -> "badge-info"
      :planning -> "badge-warning"
      :workstream_execution -> "badge-accent"
      :executing -> "badge-accent"
      :integration -> "badge-secondary"
      :review -> "badge-primary"
      :completed -> "badge-success"
      :cancelled -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp format_phase(phase) do
    phase
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp count_running_pods(tasks) do
    Enum.count(tasks, & &1.pod_running)
  end

  defp total_workstreams(tasks) do
    Enum.sum(Enum.map(tasks, & &1.workstream_count))
  end
end
