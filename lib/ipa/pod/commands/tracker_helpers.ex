defmodule Ipa.Pod.Commands.TrackerHelpers do
  @moduledoc """
  Helper functions for agents to interact with the tracker.

  This module provides a simplified interface for workstream agents to:
  - Update their item statuses
  - Add comments to items
  - Request modifications (add/update/remove items) via the approval system

  ## Usage in Agents

  Workstream agents can import these helpers in their CLAUDE.md context:

      # Update status of your items
      TrackerHelpers.mark_item_wip(task_id, item_id, workstream_id)
      TrackerHelpers.mark_item_done(task_id, item_id, workstream_id)
      TrackerHelpers.mark_item_blocked(task_id, item_id, workstream_id, "reason")

      # Add comments
      TrackerHelpers.add_comment(task_id, item_id, "Progress update", workstream_id)

      # Request modifications (requires approval)
      TrackerHelpers.request_add_item(task_id, phase_id, "New item", workstream_id)
      TrackerHelpers.request_remove_item(task_id, item_id, phase_id, "Reason")
  """

  alias Ipa.Pod.Commands.{TrackerCommands, ActionApprovalCommands}

  # ============================================================================
  # Status Updates (direct, no approval needed)
  # ============================================================================

  @doc """
  Marks an item as work-in-progress.

  The workstream must own the item.
  """
  @spec mark_item_wip(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def mark_item_wip(task_id, item_id, workstream_id) do
    TrackerCommands.update_item_status(task_id, item_id, :wip, workstream_id)
  end

  @doc """
  Marks an item as done/completed.

  The workstream must own the item.
  """
  @spec mark_item_done(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def mark_item_done(task_id, item_id, workstream_id) do
    TrackerCommands.update_item_status(task_id, item_id, :done, workstream_id)
  end

  @doc """
  Marks an item as blocked with an optional reason.

  The workstream must own the item. Use this when waiting on external
  dependencies or encountering blockers.
  """
  @spec mark_item_blocked(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def mark_item_blocked(task_id, item_id, workstream_id, _reason \\ nil) do
    TrackerCommands.update_item_status(task_id, item_id, :blocked, workstream_id)
  end

  @doc """
  Marks a blocked item as back to work-in-progress.

  Use this when a blocker is resolved.
  """
  @spec unblock_item(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def unblock_item(task_id, item_id, workstream_id) do
    TrackerCommands.update_item_status(task_id, item_id, :wip, workstream_id)
  end

  # ============================================================================
  # Comments (direct, no approval needed)
  # ============================================================================

  @doc """
  Adds a comment to a tracker item.

  Comments are visible to everyone.
  """
  @spec add_comment(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def add_comment(task_id, item_id, content, author) do
    TrackerCommands.add_comment(task_id, item_id, content, author)
  end

  # ============================================================================
  # Modification Requests (require admin approval)
  # ============================================================================

  @doc """
  Requests to add a new item to a phase.

  This creates an approval request that must be approved by an admin.
  Returns the request_id for tracking.
  """
  @spec request_add_item(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def request_add_item(task_id, phase_id, summary, workstream_id, reason \\ nil) do
    ActionApprovalCommands.request_approval(task_id, %{
      action_type: :tracker_add_item,
      action_payload: %{
        phase_id: phase_id,
        summary: summary,
        workstream_id: workstream_id
      },
      requested_by: workstream_id,
      reason: reason || "Discovered additional item during execution"
    })
  end

  @doc """
  Requests to update an item's properties.

  Supported changes: summary, workstream_id (reassignment).
  Requires admin approval.
  """
  @spec request_update_item(String.t(), String.t(), map(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def request_update_item(task_id, item_id, changes, requested_by, reason \\ nil) do
    ActionApprovalCommands.request_approval(task_id, %{
      action_type: :tracker_update_item,
      action_payload: Map.merge(%{item_id: item_id}, changes),
      requested_by: requested_by,
      reason: reason || "Item modification requested"
    })
  end

  @doc """
  Requests to remove an item from the tracker.

  Requires admin approval.
  """
  @spec request_remove_item(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def request_remove_item(task_id, item_id, phase_id, requested_by, reason \\ nil) do
    ActionApprovalCommands.request_approval(task_id, %{
      action_type: :tracker_remove_item,
      action_payload: %{
        item_id: item_id,
        phase_id: phase_id,
        reason: reason
      },
      requested_by: requested_by,
      reason: reason || "Item removal requested"
    })
  end

  # ============================================================================
  # Query Helpers
  # ============================================================================

  @doc """
  Gets the tracker for a task.
  """
  @spec get_tracker(String.t()) :: {:ok, map()} | {:error, term()}
  def get_tracker(task_id) do
    case Ipa.Pod.Manager.get_state_from_events(task_id) do
      {:ok, state} -> {:ok, state.tracker}
      error -> error
    end
  end

  @doc """
  Gets items owned by a workstream.
  """
  @spec get_my_items(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_my_items(task_id, workstream_id) do
    case get_tracker(task_id) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, tracker} ->
        items = Ipa.Pod.State.Tracker.items_for_workstream(tracker, workstream_id)
        {:ok, items}

      error ->
        error
    end
  end

  @doc """
  Gets pending items for a workstream (todo or wip status).
  """
  @spec get_pending_items(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_pending_items(task_id, workstream_id) do
    case get_my_items(task_id, workstream_id) do
      {:ok, items} ->
        pending = Enum.filter(items, &(&1.status in [:todo, :wip]))
        {:ok, pending}

      error ->
        error
    end
  end
end
