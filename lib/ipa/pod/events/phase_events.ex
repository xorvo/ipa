defmodule Ipa.Pod.Events.TransitionRequested do
  @moduledoc "Event emitted when a phase transition is requested."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :from_phase, :to_phase, :reason]
  defstruct [:task_id, :from_phase, :to_phase, :reason, :requested_by]

  @type phase ::
          :spec_clarification
          | :planning
          | :workstream_execution
          | :review
          | :completed
          | :cancelled

  @type t :: %__MODULE__{
          task_id: String.t(),
          from_phase: phase(),
          to_phase: phase(),
          reason: String.t(),
          requested_by: String.t() | nil
        }

  @impl true
  def event_type, do: "transition_requested"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      from_phase: event.from_phase,
      to_phase: event.to_phase,
      reason: event.reason,
      requested_by: event.requested_by
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      from_phase: normalize_phase(get_field(data, :from_phase)),
      to_phase: normalize_phase(get_field(data, :to_phase)),
      reason: get_field(data, :reason),
      requested_by: get_field(data, :requested_by)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  # Only allow valid phase atoms - crash on invalid data
  @valid_phases ~w(spec_clarification planning workstream_execution review completed cancelled)a
  defp normalize_phase(phase) when phase in @valid_phases, do: phase

  defp normalize_phase(phase) when is_binary(phase) do
    atom = String.to_existing_atom(phase)

    if atom in @valid_phases do
      atom
    else
      raise ArgumentError, "Invalid phase: #{inspect(phase)}, valid phases: #{inspect(@valid_phases)}"
    end
  end

  defp normalize_phase(other) do
    raise ArgumentError, "Invalid phase type: #{inspect(other)}, expected atom or string"
  end
end

defmodule Ipa.Pod.Events.TransitionApproved do
  @moduledoc "Event emitted when a phase transition is approved."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :to_phase, :approved_by]
  defstruct [:task_id, :to_phase, :approved_by, :comment]

  @type t :: %__MODULE__{
          task_id: String.t(),
          to_phase: atom(),
          approved_by: String.t(),
          comment: String.t() | nil
        }

  @impl true
  def event_type, do: "transition_approved"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      to_phase: event.to_phase,
      approved_by: event.approved_by,
      comment: event.comment
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      to_phase: normalize_phase(get_field(data, :to_phase)),
      approved_by: get_field(data, :approved_by),
      comment: get_field(data, :comment)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  # Only allow valid phase atoms - crash on invalid data
  @valid_phases ~w(spec_clarification planning workstream_execution review completed cancelled)a
  defp normalize_phase(phase) when phase in @valid_phases, do: phase

  defp normalize_phase(phase) when is_binary(phase) do
    atom = String.to_existing_atom(phase)

    if atom in @valid_phases do
      atom
    else
      raise ArgumentError, "Invalid phase: #{inspect(phase)}, valid phases: #{inspect(@valid_phases)}"
    end
  end

  defp normalize_phase(other) do
    raise ArgumentError, "Invalid phase type: #{inspect(other)}, expected atom or string"
  end
end

defmodule Ipa.Pod.Events.PhaseChanged do
  @moduledoc "Event emitted when the phase actually changes (direct change without approval)."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :from_phase, :to_phase]
  defstruct [:task_id, :from_phase, :to_phase, :changed_at]

  @type t :: %__MODULE__{
          task_id: String.t(),
          from_phase: atom(),
          to_phase: atom(),
          changed_at: integer() | nil
        }

  @impl true
  def event_type, do: "phase_changed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      from_phase: event.from_phase,
      to_phase: event.to_phase,
      changed_at: event.changed_at
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      from_phase: normalize_phase(get_field(data, :from_phase)),
      to_phase: normalize_phase(get_field(data, :to_phase)),
      changed_at: get_field(data, :changed_at)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  # Only allow valid phase atoms - crash on invalid data
  @valid_phases ~w(spec_clarification planning workstream_execution review completed cancelled)a
  defp normalize_phase(phase) when phase in @valid_phases, do: phase

  defp normalize_phase(phase) when is_binary(phase) do
    atom = String.to_existing_atom(phase)

    if atom in @valid_phases do
      atom
    else
      raise ArgumentError, "Invalid phase: #{inspect(phase)}, valid phases: #{inspect(@valid_phases)}"
    end
  end

  defp normalize_phase(other) do
    raise ArgumentError, "Invalid phase type: #{inspect(other)}, expected atom or string"
  end
end
