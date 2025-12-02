defmodule Ipa.Pod.Commands.TrackerCommands do
  @moduledoc """
  Commands for managing the progress tracker.

  This module provides the interface for creating and modifying trackers.
  Some operations (add/update/remove items) are executed via the approval
  system and called by the ApprovalExecutor.

  ## Direct Operations (no approval needed)

  - `create_tracker/3` - Create initial tracker (planning agent)
  - `update_item_status/4` - Workstream updates its own item status
  - `add_comment/4` - Anyone can add comments
  - `update_phase_eta/4` - Update phase ETA

  ## Approval-Required Operations

  These are called by ApprovalExecutor after admin approval:

  - `add_item/3` - Add new item to phase
  - `update_item/3` - Update item properties (summary, workstream)
  - `remove_item/3` - Remove item from phase
  """

  alias Ipa.EventStore
  alias Ipa.Pod.State.Tracker
  require Logger

  # ============================================================================
  # Direct Operations (no approval needed)
  # ============================================================================

  @doc """
  Creates the initial tracker for a task.

  Called by the planning agent when it generates the tracker.
  The phases list should include all phases with their items.
  """
  @spec create_tracker(String.t(), [map()], String.t() | nil) :: :ok | {:error, term()}
  def create_tracker(task_id, phases, actor_id \\ "planning_agent") do
    Logger.info("Creating tracker",
      task_id: task_id,
      phase_count: length(phases)
    )

    case EventStore.append(
           task_id,
           "tracker_created",
           %{task_id: task_id, phases: phases},
           actor_id: actor_id
         ) do
      {:ok, _version} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Updates an item's status.

  Workstreams can directly update the status of items they own.
  Returns error if the workstream doesn't own the item.
  """
  @spec update_item_status(String.t(), String.t(), atom(), String.t()) ::
          :ok | {:error, term()}
  def update_item_status(task_id, item_id, new_status, changed_by) do
    with {:ok, state} <- Ipa.Pod.Manager.get_state_from_events(task_id),
         {:ok, {_phase, item}} <- get_item(state.tracker, item_id),
         :ok <- validate_ownership(item, changed_by) do
      Logger.info("Updating item status",
        task_id: task_id,
        item_id: item_id,
        from: item.status,
        to: new_status
      )

      EventStore.append(
        task_id,
        "tracker_item_status_changed",
        %{
          task_id: task_id,
          item_id: item_id,
          from_status: item.status,
          to_status: new_status,
          changed_by: changed_by
        },
        actor_id: changed_by
      )
      |> result_to_ok()
    end
  end

  @doc """
  Adds a comment to a tracker item.

  Comments are visible to everyone.
  """
  @spec add_comment(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def add_comment(task_id, item_id, content, author) do
    comment_id = Ecto.UUID.generate()

    Logger.info("Adding comment to item",
      task_id: task_id,
      item_id: item_id,
      author: author
    )

    case EventStore.append(
           task_id,
           "tracker_item_comment_added",
           %{
             task_id: task_id,
             item_id: item_id,
             comment_id: comment_id,
             content: content,
             author: author
           },
           actor_id: author
         ) do
      {:ok, _version} -> {:ok, comment_id}
      {:error, _} = error -> error
    end
  end

  @doc """
  Updates a phase's ETA.
  """
  @spec update_phase_eta(String.t(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, term()}
  def update_phase_eta(task_id, phase_id, eta, updated_by) do
    Logger.info("Updating phase ETA",
      task_id: task_id,
      phase_id: phase_id,
      eta: eta
    )

    EventStore.append(
      task_id,
      "tracker_phase_eta_updated",
      %{
        task_id: task_id,
        phase_id: phase_id,
        eta: eta,
        updated_by: updated_by
      },
      actor_id: updated_by
    )
    |> result_to_ok()
  end

  # ============================================================================
  # Approval-Required Operations (called by ApprovalExecutor)
  # ============================================================================

  @doc """
  Adds a new item to a phase.

  This is called by ApprovalExecutor after admin approval.
  """
  @spec add_item(String.t(), map(), String.t() | nil) :: :ok | {:error, term()}
  def add_item(task_id, payload, actor_id) do
    item_id = Ecto.UUID.generate()
    phase_id = payload[:phase_id] || payload["phase_id"]
    summary = payload[:summary] || payload["summary"]
    workstream_id = payload[:workstream_id] || payload["workstream_id"]

    Logger.info("Adding item to tracker",
      task_id: task_id,
      phase_id: phase_id,
      item_id: item_id
    )

    EventStore.append(
      task_id,
      "tracker_item_added",
      %{
        task_id: task_id,
        phase_id: phase_id,
        item_id: item_id,
        summary: summary,
        workstream_id: workstream_id
      },
      actor_id: actor_id || "system"
    )
    |> result_to_ok()
  end

  @doc """
  Updates an item's properties (summary, workstream_id).

  This is called by ApprovalExecutor after admin approval.
  """
  @spec update_item(String.t(), map(), String.t() | nil) :: :ok | {:error, term()}
  def update_item(task_id, payload, actor_id) do
    item_id = payload[:item_id] || payload["item_id"]

    # Build changes map from payload
    changes =
      %{}
      |> maybe_add_change(:summary, payload[:summary] || payload["summary"])
      |> maybe_add_change(:workstream_id, payload[:workstream_id] || payload["workstream_id"])

    Logger.info("Updating tracker item",
      task_id: task_id,
      item_id: item_id,
      changes: Map.keys(changes)
    )

    EventStore.append(
      task_id,
      "tracker_item_updated",
      %{
        task_id: task_id,
        item_id: item_id,
        changes: changes,
        updated_by: actor_id
      },
      actor_id: actor_id || "system"
    )
    |> result_to_ok()
  end

  @doc """
  Removes an item from the tracker.

  This is called by ApprovalExecutor after admin approval.
  """
  @spec remove_item(String.t(), map(), String.t() | nil) :: :ok | {:error, term()}
  def remove_item(task_id, payload, actor_id) do
    item_id = payload[:item_id] || payload["item_id"]
    phase_id = payload[:phase_id] || payload["phase_id"]
    reason = payload[:reason] || payload["reason"]

    Logger.info("Removing tracker item",
      task_id: task_id,
      item_id: item_id,
      phase_id: phase_id
    )

    EventStore.append(
      task_id,
      "tracker_item_removed",
      %{
        task_id: task_id,
        item_id: item_id,
        phase_id: phase_id,
        removed_by: actor_id,
        reason: reason
      },
      actor_id: actor_id || "system"
    )
    |> result_to_ok()
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_item(nil, _item_id), do: {:error, :no_tracker}

  defp get_item(tracker, item_id) do
    case Tracker.get_item(tracker, item_id) do
      nil -> {:error, :item_not_found}
      result -> {:ok, result}
    end
  end

  defp validate_ownership(%{workstream_id: ws_id}, ws_id), do: :ok
  defp validate_ownership(%{workstream_id: nil}, _), do: :ok
  defp validate_ownership(_, _), do: {:error, :not_owner}

  defp result_to_ok({:ok, _version}), do: :ok
  defp result_to_ok({:error, _} = error), do: error

  defp maybe_add_change(changes, _key, nil), do: changes
  defp maybe_add_change(changes, key, value), do: Map.put(changes, key, value)
end
