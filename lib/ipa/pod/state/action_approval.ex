defmodule Ipa.Pod.State.ActionApprovalRequest do
  @moduledoc """
  Represents a pending action that requires admin approval.

  This is a generic approval system for any action that requires authorization.
  The action_type and action_payload define what will be executed upon approval.

  ## Usage

  Workstreams or agents can request actions via the ActionApprovalCommands module.
  Once approved, the ApprovalExecutor module executes the action based on its type.

  ## Example

      %ActionApprovalRequest{
        request_id: "req-123",
        task_id: "task-456",
        action_type: :tracker_add_item,
        action_payload: %{phase_id: "phase-1", summary: "New item", workstream_id: "ws-1"},
        requested_by: "ws-1",
        reason: "Need additional item for discovered requirement",
        status: :pending,
        created_at: 1234567890
      }
  """

  @type status :: :pending | :approved | :rejected

  @type action_type ::
          :tracker_add_item
          | :tracker_update_item
          | :tracker_remove_item
          | atom()

  defstruct [
    :request_id,
    :task_id,
    # Action definition
    :action_type,
    :action_payload,
    # Context
    :requested_by,
    :reason,
    # State
    :status,
    :decided_by,
    :decided_at,
    :decision_comment,
    # Timestamps
    :created_at
  ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          task_id: String.t(),
          action_type: action_type(),
          action_payload: map(),
          requested_by: String.t(),
          reason: String.t() | nil,
          status: status(),
          decided_by: String.t() | nil,
          decided_at: integer() | nil,
          decision_comment: String.t() | nil,
          created_at: integer()
        }

  @doc "Returns true if the request is pending."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: :pending}), do: true
  def pending?(_), do: false

  @doc "Returns true if the request was approved."
  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{status: :approved}), do: true
  def approved?(_), do: false

  @doc "Returns true if the request was rejected."
  @spec rejected?(t()) :: boolean()
  def rejected?(%__MODULE__{status: :rejected}), do: true
  def rejected?(_), do: false

  @doc "Returns a human-readable description of the action."
  @spec describe_action(t()) :: String.t()
  def describe_action(%__MODULE__{action_type: :tracker_add_item, action_payload: payload}) do
    summary = payload[:summary] || payload["summary"] || "Unknown"
    "Add tracker item: #{summary}"
  end

  def describe_action(%__MODULE__{action_type: :tracker_update_item, action_payload: payload}) do
    item_id = payload[:item_id] || payload["item_id"] || "Unknown"
    "Update tracker item: #{item_id}"
  end

  def describe_action(%__MODULE__{action_type: :tracker_remove_item, action_payload: payload}) do
    item_id = payload[:item_id] || payload["item_id"] || "Unknown"
    "Remove tracker item: #{item_id}"
  end

  def describe_action(%__MODULE__{action_type: action_type}) do
    "Action: #{action_type}"
  end
end
