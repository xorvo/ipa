defmodule Ipa.Pod.Machine do
  @moduledoc """
  Defines the pod phase state machine.

  Phases represent the lifecycle of a task:
  - `:spec_clarification` - Initial phase, gathering requirements
  - `:planning` - Breaking work into workstreams
  - `:workstream_execution` - Running workstreams in parallel
  - `:review` - Reviewing completed work
  - `:completed` - All work finished successfully
  - `:cancelled` - Task was cancelled

  ## Transitions

  ```
  spec_clarification ──→ planning ──→ workstream_execution ──→ review ──→ completed
         │                  │                  │                 │
         └──────────────────┴──────────────────┴─────────────────┴──→ cancelled
  ```
  """

  @type phase ::
          :spec_clarification
          | :planning
          | :workstream_execution
          | :review
          | :completed
          | :cancelled

  @transitions %{
    spec_clarification: [:planning, :cancelled],
    planning: [:workstream_execution, :spec_clarification, :cancelled],
    workstream_execution: [:review, :planning, :cancelled],
    review: [:completed, :workstream_execution, :cancelled],
    completed: [],
    cancelled: []
  }

  @all_phases Map.keys(@transitions)

  @doc "Returns all valid phases."
  @spec phases() :: [phase()]
  def phases, do: @all_phases

  @doc "Returns valid transitions from a given phase."
  @spec valid_transitions(phase()) :: [phase()]
  def valid_transitions(phase), do: Map.get(@transitions, phase, [])

  @doc "Checks if a transition from one phase to another is valid."
  @spec can_transition?(phase(), phase()) :: boolean()
  def can_transition?(from, to), do: to in valid_transitions(from)

  @doc "Returns true if this is a terminal phase (no further transitions)."
  @spec terminal?(phase()) :: boolean()
  def terminal?(phase), do: valid_transitions(phase) == []

  @doc "Returns true if this is the initial phase."
  @spec initial?(phase()) :: boolean()
  def initial?(:spec_clarification), do: true
  def initial?(_), do: false

  @doc "Returns true if work can be done in this phase (non-terminal, non-initial)."
  @spec active?(phase()) :: boolean()
  def active?(phase), do: phase in [:planning, :workstream_execution, :review]

  @doc "Returns the next natural phase in the workflow (happy path)."
  @spec next_phase(phase()) :: phase() | nil
  def next_phase(:spec_clarification), do: :planning
  def next_phase(:planning), do: :workstream_execution
  def next_phase(:workstream_execution), do: :review
  def next_phase(:review), do: :completed
  def next_phase(_), do: nil

  @doc "Returns the previous phase (for going back)."
  @spec previous_phase(phase()) :: phase() | nil
  def previous_phase(:planning), do: :spec_clarification
  def previous_phase(:workstream_execution), do: :planning
  def previous_phase(:review), do: :workstream_execution
  def previous_phase(_), do: nil
end
