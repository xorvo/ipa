defmodule Ipa.Pod.Commands.ApprovalExecutor do
  @moduledoc """
  Executes approved actions based on their type.

  This module acts as the dispatcher for the generic approval system. When an action
  is approved via ActionApprovalCommands, this module examines the action_type and
  routes to the appropriate handler.

  ## Supported Action Types

  - `:tracker_add_item` - Add a new item to a tracker phase
  - `:tracker_update_item` - Update an existing tracker item
  - `:tracker_remove_item` - Remove a tracker item

  ## Adding New Action Types

  To support a new action type:
  1. Add a new clause to `execute/2` matching your action_type
  2. Implement the handler that processes action_payload and emits events
  """

  alias Ipa.Pod.State.ActionApprovalRequest
  require Logger

  @doc """
  Execute an approved action based on its type.

  Takes the task_id and the approval request struct, dispatches to the
  appropriate handler based on action_type.
  """
  @spec execute(String.t(), ActionApprovalRequest.t() | map()) :: :ok | {:error, term()}
  def execute(task_id, %ActionApprovalRequest{} = request) do
    Logger.info("Executing approved action",
      task_id: task_id,
      request_id: request.request_id,
      action_type: request.action_type
    )

    do_execute(task_id, request.action_type, request.action_payload, request)
  end

  def execute(task_id, %{action_type: action_type, action_payload: payload} = request) do
    Logger.info("Executing approved action",
      task_id: task_id,
      request_id: request[:request_id],
      action_type: action_type
    )

    do_execute(task_id, normalize_action_type(action_type), payload, request)
  end

  # Tracker actions
  defp do_execute(task_id, :tracker_add_item, payload, request) do
    Logger.info("Executing tracker_add_item",
      task_id: task_id,
      phase_id: payload[:phase_id] || payload["phase_id"]
    )

    # Delegate to TrackerCommands when available
    case Code.ensure_loaded(Ipa.Pod.Commands.TrackerCommands) do
      {:module, mod} ->
        mod.add_item(task_id, payload, request[:requested_by])

      {:error, _} ->
        Logger.warning("TrackerCommands not available yet",
          task_id: task_id,
          action: :tracker_add_item
        )

        {:error, :handler_not_available}
    end
  end

  defp do_execute(task_id, :tracker_update_item, payload, request) do
    Logger.info("Executing tracker_update_item",
      task_id: task_id,
      item_id: payload[:item_id] || payload["item_id"]
    )

    case Code.ensure_loaded(Ipa.Pod.Commands.TrackerCommands) do
      {:module, mod} ->
        mod.update_item(task_id, payload, request[:requested_by])

      {:error, _} ->
        Logger.warning("TrackerCommands not available yet",
          task_id: task_id,
          action: :tracker_update_item
        )

        {:error, :handler_not_available}
    end
  end

  defp do_execute(task_id, :tracker_remove_item, payload, request) do
    Logger.info("Executing tracker_remove_item",
      task_id: task_id,
      item_id: payload[:item_id] || payload["item_id"]
    )

    case Code.ensure_loaded(Ipa.Pod.Commands.TrackerCommands) do
      {:module, mod} ->
        mod.remove_item(task_id, payload, request[:requested_by])

      {:error, _} ->
        Logger.warning("TrackerCommands not available yet",
          task_id: task_id,
          action: :tracker_remove_item
        )

        {:error, :handler_not_available}
    end
  end

  # Fallback for unknown action types
  defp do_execute(task_id, action_type, _payload, _request) do
    Logger.error("Unknown action type",
      task_id: task_id,
      action_type: action_type
    )

    {:error, {:unknown_action_type, action_type}}
  end

  defp normalize_action_type(type) when is_atom(type), do: type
  defp normalize_action_type(type) when is_binary(type), do: String.to_existing_atom(type)
  defp normalize_action_type(_), do: :unknown
end
