defmodule Ipa.Pod.Commands.ActionApprovalCommands do
  @moduledoc """
  Commands for the generic action approval system.

  This module provides the interface for requesting, granting, and rejecting
  approval for actions that require admin authorization.

  ## Usage

  Workstreams or agents request actions via `request_approval/2`:

      ActionApprovalCommands.request_approval(task_id, %{
        action_type: :tracker_add_item,
        action_payload: %{phase_id: "phase-1", summary: "New item"},
        requested_by: "workstream-1",
        reason: "Discovered additional requirement"
      })

  Admins approve or reject via `grant_approval/3` or `reject_approval/3`:

      ActionApprovalCommands.grant_approval(task_id, request_id, "admin-user")

  Upon approval, the ApprovalExecutor automatically executes the action.
  """

  alias Ipa.EventStore
  require Logger

  @type approval_params :: %{
          required(:action_type) => atom(),
          required(:action_payload) => map(),
          required(:requested_by) => String.t(),
          optional(:reason) => String.t()
        }

  @doc """
  Request approval for an action.

  Creates a pending approval request that admins can approve or reject.
  Returns the request_id for tracking.
  """
  @spec request_approval(String.t(), approval_params()) ::
          {:ok, String.t()} | {:error, term()}
  def request_approval(task_id, params) do
    request_id = Ecto.UUID.generate()

    Logger.info("Action approval requested",
      task_id: task_id,
      request_id: request_id,
      action_type: params[:action_type],
      requested_by: params[:requested_by]
    )

    case EventStore.append(
           task_id,
           "action_approval_requested",
           %{
             task_id: task_id,
             request_id: request_id,
             action_type: params[:action_type],
             action_payload: params[:action_payload] || %{},
             requested_by: params[:requested_by],
             reason: params[:reason]
           },
           actor_id: params[:requested_by]
         ) do
      {:ok, _version} ->
        {:ok, request_id}

      {:error, reason} = error ->
        Logger.error("Failed to create approval request",
          task_id: task_id,
          request_id: request_id,
          error: inspect(reason)
        )

        error
    end
  end

  @doc """
  Grant approval for a pending request.

  This approves the request and triggers execution of the action via ApprovalExecutor.
  """
  @spec grant_approval(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def grant_approval(task_id, request_id, approved_by, comment \\ nil) do
    Logger.info("Granting action approval",
      task_id: task_id,
      request_id: request_id,
      approved_by: approved_by
    )

    case EventStore.append(
           task_id,
           "action_approval_granted",
           %{
             task_id: task_id,
             request_id: request_id,
             approved_by: approved_by,
             comment: comment
           },
           actor_id: approved_by
         ) do
      {:ok, _version} ->
        # Execute the approved action
        execute_approved_action(task_id, request_id)

      {:error, reason} = error ->
        Logger.error("Failed to grant approval",
          task_id: task_id,
          request_id: request_id,
          error: inspect(reason)
        )

        error
    end
  end

  @doc """
  Reject an approval request.
  """
  @spec reject_approval(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def reject_approval(task_id, request_id, rejected_by, reason \\ nil) do
    Logger.info("Rejecting action approval",
      task_id: task_id,
      request_id: request_id,
      rejected_by: rejected_by
    )

    case EventStore.append(
           task_id,
           "action_approval_rejected",
           %{
             task_id: task_id,
             request_id: request_id,
             rejected_by: rejected_by,
             reason: reason
           },
           actor_id: rejected_by
         ) do
      {:ok, _version} ->
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to reject approval",
          task_id: task_id,
          request_id: request_id,
          error: inspect(reason)
        )

        error
    end
  end

  @doc """
  Get all pending approval requests for a task.
  """
  @spec get_pending_approvals(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_pending_approvals(task_id) do
    case Ipa.Pod.Manager.get_state_from_events(task_id) do
      {:ok, state} ->
        pending =
          Ipa.Pod.State.Projections.ActionApprovalProjection.get_pending(state)

        {:ok, pending}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get a specific approval request by ID.
  """
  @spec get_request(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_request(task_id, request_id) do
    case Ipa.Pod.Manager.get_state_from_events(task_id) do
      {:ok, state} ->
        case Ipa.Pod.State.Projections.ActionApprovalProjection.get_request(state, request_id) do
          nil -> {:error, :not_found}
          request -> {:ok, request}
        end

      {:error, _} = error ->
        error
    end
  end

  # Execute the approved action via ApprovalExecutor
  defp execute_approved_action(task_id, request_id) do
    case get_request(task_id, request_id) do
      {:ok, request} ->
        Ipa.Pod.Commands.ApprovalExecutor.execute(task_id, request)

      {:error, reason} ->
        Logger.error("Cannot execute approved action - request not found",
          task_id: task_id,
          request_id: request_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end
end
