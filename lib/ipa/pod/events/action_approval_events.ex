defmodule Ipa.Pod.Events.ActionApprovalRequested do
  @moduledoc """
  Event emitted when an action requiring approval is requested.

  This is a generic approval event for any action that needs admin authorization.
  The action_type and action_payload define what will be executed upon approval.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :request_id, :action_type, :action_payload, :requested_by]
  defstruct [
    :task_id,
    :request_id,
    :action_type,
    :action_payload,
    :requested_by,
    :reason
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          request_id: String.t(),
          action_type: atom(),
          action_payload: map(),
          requested_by: String.t(),
          reason: String.t() | nil
        }

  @impl true
  def event_type, do: "action_approval_requested"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      request_id: event.request_id,
      action_type: event.action_type,
      action_payload: event.action_payload,
      requested_by: event.requested_by,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      request_id: get_field(data, :request_id),
      action_type: normalize_action_type(get_field(data, :action_type)),
      action_payload: get_field(data, :action_payload) || %{},
      requested_by: get_field(data, :requested_by),
      reason: get_field(data, :reason)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_action_type(type) when is_atom(type), do: type
  defp normalize_action_type(type) when is_binary(type), do: String.to_existing_atom(type)
  defp normalize_action_type(_), do: :unknown
end

defmodule Ipa.Pod.Events.ActionApprovalGranted do
  @moduledoc """
  Event emitted when an action approval request is granted.

  Upon approval, the ApprovalExecutor will execute the action based on its type.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :request_id, :approved_by]
  defstruct [
    :task_id,
    :request_id,
    :approved_by,
    :comment
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          request_id: String.t(),
          approved_by: String.t(),
          comment: String.t() | nil
        }

  @impl true
  def event_type, do: "action_approval_granted"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      request_id: event.request_id,
      approved_by: event.approved_by,
      comment: event.comment
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      request_id: get_field(data, :request_id),
      approved_by: get_field(data, :approved_by),
      comment: get_field(data, :comment)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.ActionApprovalRejected do
  @moduledoc """
  Event emitted when an action approval request is rejected.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :request_id, :rejected_by]
  defstruct [
    :task_id,
    :request_id,
    :rejected_by,
    :reason
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          request_id: String.t(),
          rejected_by: String.t(),
          reason: String.t() | nil
        }

  @impl true
  def event_type, do: "action_approval_rejected"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      request_id: event.request_id,
      rejected_by: event.rejected_by,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      request_id: get_field(data, :request_id),
      rejected_by: get_field(data, :rejected_by),
      reason: get_field(data, :reason)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end
