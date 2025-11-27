# Pod State Machine Refactoring Specification

## Overview

This specification defines a comprehensive refactoring of the IPA Pod state management system. The goal is to create a clean, maintainable architecture with clear separation of concerns between:

1. **Events** - Typed, immutable facts about what happened
2. **State** - Projections built by replaying events
3. **Commands** - Actions that validate and produce events
4. **Machine** - Phase transitions and guards
5. **Manager** - Thin orchestration layer

## Current Problems

1. **Monolithic `apply_event/2`** - 150+ line function handling all event types
2. **String-based events** - No compile-time guarantees about event structure
3. **Mixed concerns** - State projection, phase transitions, and scheduling all in one module
4. **Duplicate state** - `CommunicationsManager` caches state from `Pod.Manager`
5. **Implicit contracts** - Event data shapes are not enforced

## Architecture

### Directory Structure

```
lib/ipa/pod/
├── events/                        # Event type definitions
│   ├── event.ex                   # Base event behavior/protocol
│   ├── task_events.ex             # Task lifecycle events
│   ├── phase_events.ex            # Phase transition events
│   ├── workstream_events.ex       # Workstream events
│   └── communication_events.ex    # Message/notification events
│
├── state/                         # State projection (read model)
│   ├── state.ex                   # Main state struct
│   ├── projector.ex               # Event → State application
│   └── projections/
│       ├── task_projection.ex     # Task-related state
│       ├── phase_projection.ex    # Phase state
│       ├── workstream_projection.ex
│       └── communication_projection.ex
│
├── machine/                       # State machine logic
│   ├── machine.ex                 # Phase definitions & transitions
│   ├── guards.ex                  # Transition guards
│   └── evaluator.ex               # Scheduler evaluation logic
│
├── commands/                      # Command handlers (write path)
│   ├── command.ex                 # Command behavior
│   ├── task_commands.ex           # Task-related commands
│   ├── phase_commands.ex          # Phase transition commands
│   ├── workstream_commands.ex     # Workstream commands
│   └── communication_commands.ex  # Message commands
│
├── manager.ex                     # Thin GenServer orchestrator
└── registry.ex                    # Process registry helpers
```

### Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                           External Caller                           │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          Pod.Manager (GenServer)                    │
│  - Routes commands to appropriate handler                           │
│  - Maintains in-memory state                                        │
│  - Schedules evaluations                                            │
│  - Broadcasts state changes                                         │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
┌─────────────────────────────┐   ┌─────────────────────────────────┐
│     Commands (Write Path)    │   │        State (Read Path)        │
│                              │   │                                 │
│  1. Validate against state   │   │  Projector.apply_event/2        │
│  2. Check machine guards     │   │    ├── TaskProjection           │
│  3. Return list of events    │   │    ├── PhaseProjection          │
│                              │   │    ├── WorkstreamProjection     │
│  TaskCommands                │   │    └── CommunicationProjection  │
│  PhaseCommands               │   │                                 │
│  WorkstreamCommands          │   │  Returns updated state struct   │
│  CommunicationCommands       │   │                                 │
└──────────────────────────────┘   └─────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          EventStore                                 │
│  - Persists events to database                                      │
│  - Provides event replay for recovery                               │
└─────────────────────────────────────────────────────────────────────┘
```

## Module Specifications

### 1. Events Module

Events are typed structs representing immutable facts. Each event type enforces its required fields at compile time.

#### Base Event Protocol

```elixir
# lib/ipa/pod/events/event.ex
defmodule Ipa.Pod.Event do
  @moduledoc """
  Protocol for all pod events. Every event must implement:
  - event_type/1 - Returns the string type for storage
  - to_map/1 - Serializes to map for EventStore
  - from_map/1 - Deserializes from EventStore data
  """

  @callback event_type() :: String.t()
  @callback to_map(struct()) :: map()
  @callback from_map(map()) :: struct()

  # Helper to convert stored events to typed structs
  def decode(%{event_type: type, data: data}) do
    module = type_to_module(type)
    module.from_map(data)
  end

  defp type_to_module("task_created"), do: Ipa.Pod.Events.TaskCreated
  defp type_to_module("spec_updated"), do: Ipa.Pod.Events.SpecUpdated
  # ... etc
end
```

#### Task Events

```elixir
# lib/ipa/pod/events/task_events.ex
defmodule Ipa.Pod.Events.TaskCreated do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :title]
  defstruct [
    :task_id,
    :title,
    :description,
    requirements: [],
    acceptance_criteria: []
  ]

  @type t :: %__MODULE__{
    task_id: String.t(),
    title: String.t(),
    description: String.t() | nil,
    requirements: [String.t()],
    acceptance_criteria: [String.t()]
  }

  @impl true
  def event_type, do: "task_created"

  @impl true
  def to_map(%__MODULE__{} = event) do
    Map.from_struct(event)
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: data[:task_id] || data["task_id"],
      title: data[:title] || data["title"],
      description: data[:description] || data["description"],
      requirements: data[:requirements] || data["requirements"] || [],
      acceptance_criteria: data[:acceptance_criteria] || data["acceptance_criteria"] || []
    }
  end
end

defmodule Ipa.Pod.Events.SpecUpdated do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id]
  defstruct [
    :task_id,
    :description,
    :requirements,
    :acceptance_criteria,
    :external_references
  ]

  @type t :: %__MODULE__{
    task_id: String.t(),
    description: String.t() | nil,
    requirements: [String.t()] | nil,
    acceptance_criteria: [String.t()] | nil,
    external_references: map() | nil
  }

  @impl true
  def event_type, do: "spec_updated"

  # ... to_map/from_map
end

defmodule Ipa.Pod.Events.SpecApproved do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :approved_by]
  defstruct [:task_id, :approved_by, :comment]

  @type t :: %__MODULE__{
    task_id: String.t(),
    approved_by: String.t(),
    comment: String.t() | nil
  }

  @impl true
  def event_type, do: "spec_approved"
end
```

#### Phase Events

```elixir
# lib/ipa/pod/events/phase_events.ex
defmodule Ipa.Pod.Events.TransitionRequested do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :from_phase, :to_phase, :reason]
  defstruct [:task_id, :from_phase, :to_phase, :reason, :requested_by]

  @type phase :: :spec_clarification | :planning | :workstream_execution | :review | :completed | :cancelled

  @type t :: %__MODULE__{
    task_id: String.t(),
    from_phase: phase(),
    to_phase: phase(),
    reason: String.t(),
    requested_by: String.t() | nil
  }

  @impl true
  def event_type, do: "transition_requested"
end

defmodule Ipa.Pod.Events.TransitionApproved do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :to_phase, :approved_by]
  defstruct [:task_id, :to_phase, :approved_by]

  @impl true
  def event_type, do: "transition_approved"
end

defmodule Ipa.Pod.Events.PhaseChanged do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :from_phase, :to_phase]
  defstruct [:task_id, :from_phase, :to_phase, :changed_at]

  @impl true
  def event_type, do: "phase_changed"
end
```

#### Workstream Events

```elixir
# lib/ipa/pod/events/workstream_events.ex
defmodule Ipa.Pod.Events.WorkstreamCreated do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :workstream_id, :title]
  defstruct [
    :task_id,
    :workstream_id,
    :title,
    :spec,
    dependencies: [],
    priority: :normal
  ]

  @type t :: %__MODULE__{
    task_id: String.t(),
    workstream_id: String.t(),
    title: String.t(),
    spec: String.t() | nil,
    dependencies: [String.t()],
    priority: :low | :normal | :high
  }

  @impl true
  def event_type, do: "workstream_created"
end

defmodule Ipa.Pod.Events.WorkstreamStarted do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :workstream_id, :agent_id]
  defstruct [:task_id, :workstream_id, :agent_id, :workspace_path]

  @impl true
  def event_type, do: "workstream_started"
end

defmodule Ipa.Pod.Events.WorkstreamCompleted do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :workstream_id]
  defstruct [:task_id, :workstream_id, :result_summary, :artifacts]

  @impl true
  def event_type, do: "workstream_completed"
end

defmodule Ipa.Pod.Events.WorkstreamFailed do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :workstream_id, :error]
  defstruct [:task_id, :workstream_id, :error, :recoverable?]

  @type t :: %__MODULE__{
    task_id: String.t(),
    workstream_id: String.t(),
    error: String.t(),
    recoverable?: boolean()
  }

  @impl true
  def event_type, do: "workstream_failed"
end
```

#### Communication Events

```elixir
# lib/ipa/pod/events/communication_events.ex
defmodule Ipa.Pod.Events.MessagePosted do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :message_id, :author, :content, :message_type]
  defstruct [
    :task_id,
    :message_id,
    :author,
    :content,
    :message_type,
    :thread_id,
    :workstream_id
  ]

  @type message_type :: :question | :update | :blocker

  @type t :: %__MODULE__{
    task_id: String.t(),
    message_id: String.t(),
    author: String.t(),
    content: String.t(),
    message_type: message_type(),
    thread_id: String.t() | nil,
    workstream_id: String.t() | nil
  }

  @impl true
  def event_type, do: "message_posted"
end

defmodule Ipa.Pod.Events.ApprovalRequested do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :message_id, :author, :question, :options]
  defstruct [
    :task_id,
    :message_id,
    :author,
    :question,
    :options,
    :workstream_id,
    blocking?: true
  ]

  @type t :: %__MODULE__{
    task_id: String.t(),
    message_id: String.t(),
    author: String.t(),
    question: String.t(),
    options: [String.t()],
    workstream_id: String.t() | nil,
    blocking?: boolean()
  }

  @impl true
  def event_type, do: "approval_requested"
end

defmodule Ipa.Pod.Events.ApprovalGiven do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :message_id, :approved_by, :choice]
  defstruct [:task_id, :message_id, :approved_by, :choice, :comment]

  @impl true
  def event_type, do: "approval_given"
end

defmodule Ipa.Pod.Events.NotificationCreated do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :notification_id, :recipient, :notification_type]
  defstruct [
    :task_id,
    :notification_id,
    :recipient,
    :notification_type,
    :message_id,
    :preview
  ]

  @type notification_type :: :needs_approval | :question_asked | :blocker_raised | :workstream_completed

  @impl true
  def event_type, do: "notification_created"
end

defmodule Ipa.Pod.Events.NotificationRead do
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :notification_id]
  defstruct [:task_id, :notification_id]

  @impl true
  def event_type, do: "notification_read"
end
```

### 2. State Module

The State module defines the read model and projections.

#### Main State Struct

```elixir
# lib/ipa/pod/state/state.ex
defmodule Ipa.Pod.State do
  @moduledoc """
  The Pod state struct. This is the read model built by projecting events.
  """

  alias Ipa.Pod.State.{Workstream, Message, Notification, Agent}

  @type phase :: :spec_clarification | :planning | :workstream_execution | :review | :completed | :cancelled

  defstruct [
    :task_id,
    :title,
    :version,
    :created_at,
    :updated_at,
    phase: :spec_clarification,
    spec: %{
      description: nil,
      requirements: [],
      acceptance_criteria: [],
      approved?: false,
      approved_by: nil,
      approved_at: nil
    },
    plan: nil,
    workstreams: %{},           # workstream_id => Workstream.t()
    agents: [],                  # [Agent.t()]
    messages: %{},               # message_id => Message.t()
    notifications: [],           # [Notification.t()]
    pending_transitions: [],     # [%{to_phase, reason, requested_at}]
    config: %{
      max_concurrent_agents: 3,
      evaluation_interval: 5_000
    }
  ]

  @type t :: %__MODULE__{
    task_id: String.t(),
    title: String.t() | nil,
    version: integer(),
    created_at: integer() | nil,
    updated_at: integer() | nil,
    phase: phase(),
    spec: map(),
    plan: map() | nil,
    workstreams: %{String.t() => Workstream.t()},
    agents: [Agent.t()],
    messages: %{String.t() => Message.t()},
    notifications: [Notification.t()],
    pending_transitions: [map()],
    config: map()
  }

  @doc "Creates a new empty state for a task"
  def new(task_id) do
    %__MODULE__{
      task_id: task_id,
      version: 0,
      created_at: System.system_time(:second)
    }
  end
end

# Nested structs for cleaner typing
defmodule Ipa.Pod.State.Workstream do
  @type status :: :pending | :in_progress | :completed | :failed

  defstruct [
    :workstream_id,
    :title,
    :spec,
    :agent_id,
    :workspace_path,
    :started_at,
    :completed_at,
    :error,
    status: :pending,
    dependencies: [],
    blocking_on: []
  ]

  @type t :: %__MODULE__{
    workstream_id: String.t(),
    title: String.t(),
    spec: String.t() | nil,
    status: status(),
    dependencies: [String.t()],
    blocking_on: [String.t()],
    agent_id: String.t() | nil,
    workspace_path: String.t() | nil,
    started_at: integer() | nil,
    completed_at: integer() | nil,
    error: String.t() | nil
  }
end

defmodule Ipa.Pod.State.Message do
  @type message_type :: :question | :update | :blocker | :approval

  defstruct [
    :message_id,
    :author,
    :content,
    :thread_id,
    :workstream_id,
    :posted_at,
    message_type: :update,
    # Approval-specific fields
    approval_options: nil,
    approved?: false,
    approved_by: nil,
    approval_choice: nil,
    blocking?: false
  ]

  @type t :: %__MODULE__{}
end

defmodule Ipa.Pod.State.Notification do
  defstruct [
    :notification_id,
    :recipient,
    :notification_type,
    :message_id,
    :preview,
    :created_at,
    read?: false
  ]

  @type t :: %__MODULE__{}
end

defmodule Ipa.Pod.State.Agent do
  @type agent_type :: :planning | :workstream | :review
  @type status :: :running | :completed | :failed

  defstruct [
    :agent_id,
    :agent_type,
    :workstream_id,
    :workspace_path,
    :started_at,
    :completed_at,
    :error,
    status: :running
  ]

  @type t :: %__MODULE__{}
end
```

#### Projector (Event Application)

```elixir
# lib/ipa/pod/state/projector.ex
defmodule Ipa.Pod.State.Projector do
  @moduledoc """
  Applies events to state. Delegates to specific projection modules.
  """

  alias Ipa.Pod.State
  alias Ipa.Pod.State.Projections.{
    TaskProjection,
    PhaseProjection,
    WorkstreamProjection,
    CommunicationProjection
  }
  alias Ipa.Pod.Event

  @doc """
  Applies a single event to state, returning updated state.
  """
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, event) do
    state
    |> apply_to_projection(event)
    |> update_metadata(event)
  end

  @doc """
  Replays a list of events to build state from scratch.
  """
  @spec replay([struct()], State.t()) :: State.t()
  def replay(events, initial_state) do
    Enum.reduce(events, initial_state, &apply(&2, &1))
  end

  # Route events to appropriate projection
  defp apply_to_projection(state, event) do
    cond do
      task_event?(event) -> TaskProjection.apply(state, event)
      phase_event?(event) -> PhaseProjection.apply(state, event)
      workstream_event?(event) -> WorkstreamProjection.apply(state, event)
      communication_event?(event) -> CommunicationProjection.apply(state, event)
      true -> state
    end
  end

  defp update_metadata(state, %{version: v, inserted_at: t}) do
    %{state | version: v, updated_at: t}
  end
  defp update_metadata(state, _), do: state

  # Event type checks
  defp task_event?(%Ipa.Pod.Events.TaskCreated{}), do: true
  defp task_event?(%Ipa.Pod.Events.SpecUpdated{}), do: true
  defp task_event?(%Ipa.Pod.Events.SpecApproved{}), do: true
  defp task_event?(_), do: false

  defp phase_event?(%Ipa.Pod.Events.TransitionRequested{}), do: true
  defp phase_event?(%Ipa.Pod.Events.TransitionApproved{}), do: true
  defp phase_event?(%Ipa.Pod.Events.PhaseChanged{}), do: true
  defp phase_event?(_), do: false

  defp workstream_event?(%Ipa.Pod.Events.WorkstreamCreated{}), do: true
  defp workstream_event?(%Ipa.Pod.Events.WorkstreamStarted{}), do: true
  defp workstream_event?(%Ipa.Pod.Events.WorkstreamCompleted{}), do: true
  defp workstream_event?(%Ipa.Pod.Events.WorkstreamFailed{}), do: true
  defp workstream_event?(_), do: false

  defp communication_event?(%Ipa.Pod.Events.MessagePosted{}), do: true
  defp communication_event?(%Ipa.Pod.Events.ApprovalRequested{}), do: true
  defp communication_event?(%Ipa.Pod.Events.ApprovalGiven{}), do: true
  defp communication_event?(%Ipa.Pod.Events.NotificationCreated{}), do: true
  defp communication_event?(%Ipa.Pod.Events.NotificationRead{}), do: true
  defp communication_event?(_), do: false
end
```

#### Individual Projections

```elixir
# lib/ipa/pod/state/projections/task_projection.ex
defmodule Ipa.Pod.State.Projections.TaskProjection do
  @moduledoc "Projects task-related events onto state"

  alias Ipa.Pod.State
  alias Ipa.Pod.Events.{TaskCreated, SpecUpdated, SpecApproved}

  def apply(state, %TaskCreated{} = event) do
    %{state |
      task_id: event.task_id,
      title: event.title,
      spec: %{
        description: event.description,
        requirements: event.requirements,
        acceptance_criteria: event.acceptance_criteria,
        approved?: false
      },
      phase: :spec_clarification
    }
  end

  def apply(state, %SpecUpdated{} = event) do
    updated_spec = state.spec
      |> maybe_update(:description, event.description)
      |> maybe_update(:requirements, event.requirements)
      |> maybe_update(:acceptance_criteria, event.acceptance_criteria)

    %{state | spec: updated_spec}
  end

  def apply(state, %SpecApproved{} = event) do
    updated_spec = state.spec
      |> Map.put(:approved?, true)
      |> Map.put(:approved_by, event.approved_by)
      |> Map.put(:approved_at, System.system_time(:second))

    %{state | spec: updated_spec}
  end

  def apply(state, _event), do: state

  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)
end

# lib/ipa/pod/state/projections/phase_projection.ex
defmodule Ipa.Pod.State.Projections.PhaseProjection do
  @moduledoc "Projects phase transition events onto state"

  alias Ipa.Pod.Events.{TransitionRequested, TransitionApproved, PhaseChanged}

  def apply(state, %TransitionRequested{} = event) do
    transition = %{
      to_phase: event.to_phase,
      reason: event.reason,
      requested_by: event.requested_by,
      requested_at: System.system_time(:second)
    }

    # Avoid duplicate pending transitions
    if Enum.any?(state.pending_transitions, &(&1.to_phase == event.to_phase)) do
      state
    else
      %{state | pending_transitions: [transition | state.pending_transitions]}
    end
  end

  def apply(state, %TransitionApproved{to_phase: phase}) do
    %{state |
      phase: phase,
      pending_transitions: []
    }
  end

  def apply(state, %PhaseChanged{to_phase: phase}) do
    %{state | phase: phase, pending_transitions: []}
  end

  def apply(state, _), do: state
end

# lib/ipa/pod/state/projections/workstream_projection.ex
defmodule Ipa.Pod.State.Projections.WorkstreamProjection do
  @moduledoc "Projects workstream events onto state"

  alias Ipa.Pod.State.{Workstream, Agent}
  alias Ipa.Pod.Events.{
    WorkstreamCreated,
    WorkstreamStarted,
    WorkstreamCompleted,
    WorkstreamFailed
  }

  def apply(state, %WorkstreamCreated{} = event) do
    workstream = %Workstream{
      workstream_id: event.workstream_id,
      title: event.title,
      spec: event.spec,
      dependencies: event.dependencies,
      status: :pending,
      blocking_on: calculate_blocking(event.dependencies, state.workstreams)
    }

    workstreams = Map.put(state.workstreams, event.workstream_id, workstream)
    %{state | workstreams: workstreams}
  end

  def apply(state, %WorkstreamStarted{} = event) do
    state
    |> update_workstream(event.workstream_id, fn ws ->
      %{ws |
        status: :in_progress,
        agent_id: event.agent_id,
        workspace_path: event.workspace_path,
        started_at: System.system_time(:second)
      }
    end)
    |> add_agent(%Agent{
      agent_id: event.agent_id,
      agent_type: :workstream,
      workstream_id: event.workstream_id,
      workspace_path: event.workspace_path,
      status: :running,
      started_at: System.system_time(:second)
    })
  end

  def apply(state, %WorkstreamCompleted{} = event) do
    state
    |> update_workstream(event.workstream_id, fn ws ->
      %{ws |
        status: :completed,
        completed_at: System.system_time(:second)
      }
    end)
    |> update_agent_for_workstream(event.workstream_id, :completed)
    |> recalculate_blocking()
  end

  def apply(state, %WorkstreamFailed{} = event) do
    state
    |> update_workstream(event.workstream_id, fn ws ->
      %{ws |
        status: :failed,
        error: event.error,
        completed_at: System.system_time(:second)
      }
    end)
    |> update_agent_for_workstream(event.workstream_id, :failed)
  end

  def apply(state, _), do: state

  # Helpers
  defp update_workstream(state, id, update_fn) do
    case Map.get(state.workstreams, id) do
      nil -> state
      ws -> %{state | workstreams: Map.put(state.workstreams, id, update_fn.(ws))}
    end
  end

  defp add_agent(state, agent) do
    %{state | agents: [agent | state.agents]}
  end

  defp update_agent_for_workstream(state, workstream_id, status) do
    agents = Enum.map(state.agents, fn agent ->
      if agent.workstream_id == workstream_id do
        %{agent | status: status, completed_at: System.system_time(:second)}
      else
        agent
      end
    end)
    %{state | agents: agents}
  end

  defp calculate_blocking(dependencies, workstreams) do
    Enum.filter(dependencies, fn dep_id ->
      case Map.get(workstreams, dep_id) do
        nil -> false
        ws -> ws.status != :completed
      end
    end)
  end

  defp recalculate_blocking(state) do
    workstreams = Map.new(state.workstreams, fn {id, ws} ->
      blocking = calculate_blocking(ws.dependencies, state.workstreams)
      {id, %{ws | blocking_on: blocking}}
    end)
    %{state | workstreams: workstreams}
  end
end

# lib/ipa/pod/state/projections/communication_projection.ex
defmodule Ipa.Pod.State.Projections.CommunicationProjection do
  @moduledoc "Projects communication events onto state"

  alias Ipa.Pod.State.{Message, Notification}
  alias Ipa.Pod.Events.{
    MessagePosted,
    ApprovalRequested,
    ApprovalGiven,
    NotificationCreated,
    NotificationRead
  }

  def apply(state, %MessagePosted{} = event) do
    message = %Message{
      message_id: event.message_id,
      author: event.author,
      content: event.content,
      message_type: event.message_type,
      thread_id: event.thread_id,
      workstream_id: event.workstream_id,
      posted_at: System.system_time(:second)
    }

    messages = Map.put(state.messages, event.message_id, message)
    %{state | messages: messages}
  end

  def apply(state, %ApprovalRequested{} = event) do
    message = %Message{
      message_id: event.message_id,
      author: event.author,
      content: event.question,
      message_type: :approval,
      workstream_id: event.workstream_id,
      approval_options: event.options,
      blocking?: event.blocking?,
      posted_at: System.system_time(:second)
    }

    messages = Map.put(state.messages, event.message_id, message)
    %{state | messages: messages}
  end

  def apply(state, %ApprovalGiven{} = event) do
    state
    |> update_message(event.message_id, fn msg ->
      %{msg |
        approved?: true,
        approved_by: event.approved_by,
        approval_choice: event.choice
      }
    end)
    |> clear_approval_notification(event.message_id)
  end

  def apply(state, %NotificationCreated{} = event) do
    notification = %Notification{
      notification_id: event.notification_id,
      recipient: event.recipient,
      notification_type: event.notification_type,
      message_id: event.message_id,
      preview: event.preview,
      created_at: System.system_time(:second)
    }

    %{state | notifications: [notification | state.notifications]}
  end

  def apply(state, %NotificationRead{} = event) do
    notifications = Enum.map(state.notifications, fn n ->
      if n.notification_id == event.notification_id do
        %{n | read?: true}
      else
        n
      end
    end)
    %{state | notifications: notifications}
  end

  def apply(state, _), do: state

  defp update_message(state, id, update_fn) do
    case Map.get(state.messages, id) do
      nil -> state
      msg -> %{state | messages: Map.put(state.messages, id, update_fn.(msg))}
    end
  end

  defp clear_approval_notification(state, message_id) do
    notifications = Enum.reject(state.notifications, fn n ->
      n.message_id == message_id and n.notification_type == :needs_approval
    end)
    %{state | notifications: notifications}
  end
end
```

### 3. Machine Module (State Machine)

The Machine module defines phase transitions and guards.

```elixir
# lib/ipa/pod/machine/machine.ex
defmodule Ipa.Pod.Machine do
  @moduledoc """
  Defines the pod phase state machine.

  Phases:
  - :spec_clarification - Initial phase, gathering requirements
  - :planning - Breaking work into workstreams
  - :workstream_execution - Running workstreams
  - :review - Reviewing completed work
  - :completed - All work finished
  - :cancelled - Task was cancelled
  """

  @type phase :: :spec_clarification | :planning | :workstream_execution | :review | :completed | :cancelled

  @transitions %{
    spec_clarification: [:planning, :cancelled],
    planning: [:workstream_execution, :spec_clarification, :cancelled],
    workstream_execution: [:review, :planning, :cancelled],
    review: [:completed, :workstream_execution, :cancelled],
    completed: [],
    cancelled: []
  }

  @doc "Returns all valid phases"
  @spec phases() :: [phase()]
  def phases, do: Map.keys(@transitions)

  @doc "Returns valid transitions from a phase"
  @spec valid_transitions(phase()) :: [phase()]
  def valid_transitions(phase), do: Map.get(@transitions, phase, [])

  @doc "Checks if a transition is valid"
  @spec can_transition?(phase(), phase()) :: boolean()
  def can_transition?(from, to), do: to in valid_transitions(from)

  @doc "Returns true if this is a terminal phase"
  @spec terminal?(phase()) :: boolean()
  def terminal?(phase), do: valid_transitions(phase) == []

  @doc "Returns true if this is the initial phase"
  @spec initial?(phase()) :: boolean()
  def initial?(:spec_clarification), do: true
  def initial?(_), do: false
end

# lib/ipa/pod/machine/guards.ex
defmodule Ipa.Pod.Machine.Guards do
  @moduledoc """
  Guards that must pass for a transition to occur.
  """

  alias Ipa.Pod.State

  @doc """
  Checks if a transition can occur given current state.
  Returns {:ok, reason} or {:error, reason}.
  """
  @spec check_transition(State.t(), atom(), atom()) :: {:ok, String.t()} | {:error, String.t()}
  def check_transition(state, from, to) do
    with :ok <- check_machine_allows(from, to),
         :ok <- check_phase_guards(state, from, to) do
      {:ok, "Transition allowed"}
    end
  end

  defp check_machine_allows(from, to) do
    if Ipa.Pod.Machine.can_transition?(from, to) do
      :ok
    else
      {:error, "Invalid transition from #{from} to #{to}"}
    end
  end

  defp check_phase_guards(state, :spec_clarification, :planning) do
    if state.spec.approved? do
      :ok
    else
      {:error, "Spec must be approved before planning"}
    end
  end

  defp check_phase_guards(state, :planning, :workstream_execution) do
    cond do
      state.plan == nil ->
        {:error, "Plan must exist before execution"}
      not Map.get(state.plan, :approved?, false) ->
        {:error, "Plan must be approved before execution"}
      map_size(state.workstreams) == 0 ->
        {:error, "At least one workstream must be created"}
      true ->
        :ok
    end
  end

  defp check_phase_guards(state, :workstream_execution, :review) do
    all_complete? = state.workstreams
      |> Map.values()
      |> Enum.all?(fn ws -> ws.status in [:completed, :failed] end)

    if all_complete? do
      :ok
    else
      {:error, "All workstreams must be complete before review"}
    end
  end

  defp check_phase_guards(_state, _from, :cancelled), do: :ok

  defp check_phase_guards(_state, _from, _to), do: :ok
end

# lib/ipa/pod/machine/evaluator.ex
defmodule Ipa.Pod.Machine.Evaluator do
  @moduledoc """
  Evaluates the current state and determines what actions to take.
  This is the "scheduler" logic that runs periodically.
  """

  alias Ipa.Pod.State
  alias Ipa.Pod.Machine.Guards
  alias Ipa.Pod.Events.{TransitionRequested, WorkstreamStarted}

  @type action ::
    {:request_transition, atom(), String.t()} |
    {:start_workstream, String.t()} |
    {:spawn_agent, atom(), map()} |
    :noop

  @doc """
  Evaluates state and returns a list of actions to take.
  """
  @spec evaluate(State.t()) :: [action()]
  def evaluate(state) do
    case state.phase do
      :spec_clarification -> evaluate_spec_phase(state)
      :planning -> evaluate_planning_phase(state)
      :workstream_execution -> evaluate_execution_phase(state)
      :review -> evaluate_review_phase(state)
      _ -> []
    end
  end

  defp evaluate_spec_phase(state) do
    if state.spec.approved? and not transition_pending?(state, :planning) do
      [{:request_transition, :planning, "Spec approved"}]
    else
      []
    end
  end

  defp evaluate_planning_phase(state) do
    cond do
      # Plan approved, transition to execution
      state.plan && Map.get(state.plan, :approved?, false) ->
        if transition_pending?(state, :workstream_execution) do
          []
        else
          [{:request_transition, :workstream_execution, "Plan approved"}]
        end

      # No agents running and no plan, spawn planning agent
      no_running_agents?(state) and state.plan == nil ->
        [{:spawn_agent, :planning, %{spec: state.spec, title: state.title}}]

      true ->
        []
    end
  end

  defp evaluate_execution_phase(state) do
    workstreams = Map.values(state.workstreams)
    completed_count = Enum.count(workstreams, &(&1.status == :completed))
    total = length(workstreams)

    cond do
      # All done, go to review
      total > 0 and completed_count == total ->
        if transition_pending?(state, :review) do
          []
        else
          [{:request_transition, :review, "All workstreams completed"}]
        end

      # Start ready workstreams
      true ->
        ready_workstreams(state)
        |> Enum.map(&{:start_workstream, &1.workstream_id})
    end
  end

  defp evaluate_review_phase(_state) do
    # Could spawn review agent, etc.
    []
  end

  # Helpers

  defp transition_pending?(state, to_phase) do
    Enum.any?(state.pending_transitions, &(&1.to_phase == to_phase))
  end

  defp no_running_agents?(state) do
    not Enum.any?(state.agents, &(&1.status == :running))
  end

  defp ready_workstreams(state) do
    running_count = Enum.count(state.agents, &(&1.status == :running))
    max_concurrent = state.config.max_concurrent_agents
    slots = max_concurrent - running_count

    if slots > 0 do
      state.workstreams
      |> Map.values()
      |> Enum.filter(&(&1.status == :pending))
      |> Enum.filter(&(Enum.empty?(&1.blocking_on)))
      |> Enum.take(slots)
    else
      []
    end
  end
end
```

### 4. Commands Module

Commands validate intent and produce events.

```elixir
# lib/ipa/pod/commands/command.ex
defmodule Ipa.Pod.Command do
  @moduledoc """
  Behavior for commands. Commands:
  1. Validate against current state
  2. Return a list of events to emit
  """

  alias Ipa.Pod.State

  @type result :: {:ok, [struct()]} | {:error, term()}

  @callback execute(State.t(), map()) :: result()
end

# lib/ipa/pod/commands/task_commands.ex
defmodule Ipa.Pod.Commands.TaskCommands do
  @moduledoc "Commands for task lifecycle"

  alias Ipa.Pod.State
  alias Ipa.Pod.Events.{TaskCreated, SpecUpdated, SpecApproved}

  @doc "Creates a new task"
  @spec create_task(map()) :: {:ok, [TaskCreated.t()]} | {:error, term()}
  def create_task(params) do
    with {:ok, task_id} <- validate_task_id(params[:task_id]),
         {:ok, title} <- validate_title(params[:title]) do
      event = %TaskCreated{
        task_id: task_id,
        title: title,
        description: params[:description],
        requirements: params[:requirements] || [],
        acceptance_criteria: params[:acceptance_criteria] || []
      }
      {:ok, [event]}
    end
  end

  @doc "Updates the spec"
  @spec update_spec(State.t(), map()) :: {:ok, [SpecUpdated.t()]} | {:error, term()}
  def update_spec(state, params) do
    cond do
      state.spec.approved? ->
        {:error, :spec_already_approved}
      state.phase != :spec_clarification ->
        {:error, :invalid_phase}
      true ->
        event = %SpecUpdated{
          task_id: state.task_id,
          description: params[:description],
          requirements: params[:requirements],
          acceptance_criteria: params[:acceptance_criteria]
        }
        {:ok, [event]}
    end
  end

  @doc "Approves the spec"
  @spec approve_spec(State.t(), String.t(), String.t() | nil) :: {:ok, [SpecApproved.t()]} | {:error, term()}
  def approve_spec(state, approved_by, comment \\ nil) do
    cond do
      state.spec.approved? ->
        {:error, :already_approved}
      state.phase != :spec_clarification ->
        {:error, :invalid_phase}
      true ->
        event = %SpecApproved{
          task_id: state.task_id,
          approved_by: approved_by,
          comment: comment
        }
        {:ok, [event]}
    end
  end

  defp validate_task_id(nil), do: {:ok, Ecto.UUID.generate()}
  defp validate_task_id(id) when is_binary(id), do: {:ok, id}
  defp validate_task_id(_), do: {:error, :invalid_task_id}

  defp validate_title(nil), do: {:error, :title_required}
  defp validate_title(""), do: {:error, :title_required}
  defp validate_title(title) when is_binary(title), do: {:ok, title}
  defp validate_title(_), do: {:error, :invalid_title}
end

# lib/ipa/pod/commands/phase_commands.ex
defmodule Ipa.Pod.Commands.PhaseCommands do
  @moduledoc "Commands for phase transitions"

  alias Ipa.Pod.State
  alias Ipa.Pod.Machine
  alias Ipa.Pod.Machine.Guards
  alias Ipa.Pod.Events.{TransitionRequested, TransitionApproved, PhaseChanged}

  @doc "Requests a phase transition"
  @spec request_transition(State.t(), atom(), String.t(), String.t() | nil) ::
    {:ok, [TransitionRequested.t()]} | {:error, term()}
  def request_transition(state, to_phase, reason, requested_by \\ nil) do
    case Guards.check_transition(state, state.phase, to_phase) do
      {:ok, _} ->
        event = %TransitionRequested{
          task_id: state.task_id,
          from_phase: state.phase,
          to_phase: to_phase,
          reason: reason,
          requested_by: requested_by
        }
        {:ok, [event]}

      {:error, _} = error ->
        error
    end
  end

  @doc "Approves a pending transition"
  @spec approve_transition(State.t(), atom(), String.t()) ::
    {:ok, [TransitionApproved.t()]} | {:error, term()}
  def approve_transition(state, to_phase, approved_by) do
    if Enum.any?(state.pending_transitions, &(&1.to_phase == to_phase)) do
      event = %TransitionApproved{
        task_id: state.task_id,
        to_phase: to_phase,
        approved_by: approved_by
      }
      {:ok, [event]}
    else
      {:error, :no_pending_transition}
    end
  end

  @doc "Directly changes phase (for system use, bypasses approval)"
  @spec change_phase(State.t(), atom()) :: {:ok, [PhaseChanged.t()]} | {:error, term()}
  def change_phase(state, to_phase) do
    if Machine.can_transition?(state.phase, to_phase) do
      event = %PhaseChanged{
        task_id: state.task_id,
        from_phase: state.phase,
        to_phase: to_phase,
        changed_at: System.system_time(:second)
      }
      {:ok, [event]}
    else
      {:error, :invalid_transition}
    end
  end
end

# lib/ipa/pod/commands/workstream_commands.ex
defmodule Ipa.Pod.Commands.WorkstreamCommands do
  @moduledoc "Commands for workstream management"

  alias Ipa.Pod.State
  alias Ipa.Pod.Events.{WorkstreamCreated, WorkstreamStarted, WorkstreamCompleted, WorkstreamFailed}

  @doc "Creates a new workstream"
  @spec create_workstream(State.t(), map()) :: {:ok, [WorkstreamCreated.t()]} | {:error, term()}
  def create_workstream(state, params) do
    cond do
      state.phase not in [:planning, :workstream_execution] ->
        {:error, :invalid_phase}
      Map.has_key?(state.workstreams, params[:workstream_id]) ->
        {:error, :workstream_exists}
      true ->
        event = %WorkstreamCreated{
          task_id: state.task_id,
          workstream_id: params[:workstream_id] || Ecto.UUID.generate(),
          title: params[:title],
          spec: params[:spec],
          dependencies: params[:dependencies] || [],
          priority: params[:priority] || :normal
        }
        {:ok, [event]}
    end
  end

  @doc "Marks a workstream as started"
  @spec start_workstream(State.t(), String.t(), String.t(), String.t() | nil) ::
    {:ok, [WorkstreamStarted.t()]} | {:error, term()}
  def start_workstream(state, workstream_id, agent_id, workspace_path \\ nil) do
    case Map.get(state.workstreams, workstream_id) do
      nil ->
        {:error, :workstream_not_found}
      ws when ws.status != :pending ->
        {:error, :workstream_not_pending}
      ws when ws.blocking_on != [] ->
        {:error, :dependencies_not_satisfied}
      _ ->
        event = %WorkstreamStarted{
          task_id: state.task_id,
          workstream_id: workstream_id,
          agent_id: agent_id,
          workspace_path: workspace_path
        }
        {:ok, [event]}
    end
  end

  @doc "Marks a workstream as completed"
  @spec complete_workstream(State.t(), String.t(), map()) ::
    {:ok, [WorkstreamCompleted.t()]} | {:error, term()}
  def complete_workstream(state, workstream_id, result \\ %{}) do
    case Map.get(state.workstreams, workstream_id) do
      nil ->
        {:error, :workstream_not_found}
      ws when ws.status != :in_progress ->
        {:error, :workstream_not_in_progress}
      _ ->
        event = %WorkstreamCompleted{
          task_id: state.task_id,
          workstream_id: workstream_id,
          result_summary: result[:summary],
          artifacts: result[:artifacts]
        }
        {:ok, [event]}
    end
  end

  @doc "Marks a workstream as failed"
  @spec fail_workstream(State.t(), String.t(), String.t(), boolean()) ::
    {:ok, [WorkstreamFailed.t()]} | {:error, term()}
  def fail_workstream(state, workstream_id, error, recoverable? \\ false) do
    case Map.get(state.workstreams, workstream_id) do
      nil ->
        {:error, :workstream_not_found}
      _ ->
        event = %WorkstreamFailed{
          task_id: state.task_id,
          workstream_id: workstream_id,
          error: error,
          recoverable?: recoverable?
        }
        {:ok, [event]}
    end
  end
end

# lib/ipa/pod/commands/communication_commands.ex
defmodule Ipa.Pod.Commands.CommunicationCommands do
  @moduledoc "Commands for messages and notifications"

  alias Ipa.Pod.State
  alias Ipa.Pod.Events.{
    MessagePosted,
    ApprovalRequested,
    ApprovalGiven,
    NotificationCreated,
    NotificationRead
  }

  @doc "Posts a message"
  @spec post_message(State.t(), map()) :: {:ok, [MessagePosted.t()]} | {:error, term()}
  def post_message(state, params) do
    with {:ok, _} <- validate_message_type(params[:type]),
         {:ok, _} <- validate_content(params[:content]),
         {:ok, _} <- validate_author(params[:author]),
         :ok <- validate_thread(params[:thread_id], state) do
      event = %MessagePosted{
        task_id: state.task_id,
        message_id: params[:message_id] || Ecto.UUID.generate(),
        author: params[:author],
        content: params[:content],
        message_type: params[:type],
        thread_id: params[:thread_id],
        workstream_id: params[:workstream_id]
      }
      {:ok, [event]}
    end
  end

  @doc "Requests approval"
  @spec request_approval(State.t(), map()) :: {:ok, [ApprovalRequested.t()]} | {:error, term()}
  def request_approval(state, params) do
    with {:ok, _} <- validate_question(params[:question]),
         {:ok, _} <- validate_options(params[:options]),
         {:ok, _} <- validate_author(params[:author]) do
      event = %ApprovalRequested{
        task_id: state.task_id,
        message_id: params[:message_id] || Ecto.UUID.generate(),
        author: params[:author],
        question: params[:question],
        options: params[:options],
        workstream_id: params[:workstream_id],
        blocking?: Map.get(params, :blocking?, true)
      }
      {:ok, [event]}
    end
  end

  @doc "Gives approval"
  @spec give_approval(State.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
    {:ok, [ApprovalGiven.t()]} | {:error, term()}
  def give_approval(state, message_id, approved_by, choice, comment \\ nil) do
    case Map.get(state.messages, message_id) do
      nil ->
        {:error, :message_not_found}
      msg when msg.message_type != :approval ->
        {:error, :not_approval_request}
      msg when msg.approved? ->
        {:error, :already_approved}
      msg when choice not in msg.approval_options ->
        {:error, :invalid_choice}
      _ ->
        event = %ApprovalGiven{
          task_id: state.task_id,
          message_id: message_id,
          approved_by: approved_by,
          choice: choice,
          comment: comment
        }
        {:ok, [event]}
    end
  end

  @doc "Creates a notification"
  @spec create_notification(State.t(), map()) :: {:ok, [NotificationCreated.t()]} | {:error, term()}
  def create_notification(state, params) do
    event = %NotificationCreated{
      task_id: state.task_id,
      notification_id: params[:notification_id] || Ecto.UUID.generate(),
      recipient: params[:recipient],
      notification_type: params[:type],
      message_id: params[:message_id],
      preview: params[:preview]
    }
    {:ok, [event]}
  end

  @doc "Marks notification as read"
  @spec mark_notification_read(State.t(), String.t()) ::
    {:ok, [NotificationRead.t()]} | {:error, term()}
  def mark_notification_read(state, notification_id) do
    if Enum.any?(state.notifications, &(&1.notification_id == notification_id)) do
      event = %NotificationRead{
        task_id: state.task_id,
        notification_id: notification_id
      }
      {:ok, [event]}
    else
      {:error, :notification_not_found}
    end
  end

  # Validation helpers
  defp validate_message_type(type) when type in [:question, :update, :blocker], do: {:ok, type}
  defp validate_message_type(_), do: {:error, :invalid_type}

  defp validate_content(nil), do: {:error, :empty_content}
  defp validate_content(""), do: {:error, :empty_content}
  defp validate_content(c) when is_binary(c), do: {:ok, c}
  defp validate_content(_), do: {:error, :invalid_content}

  defp validate_author(nil), do: {:error, :invalid_author}
  defp validate_author(""), do: {:error, :invalid_author}
  defp validate_author(a) when is_binary(a), do: {:ok, a}
  defp validate_author(_), do: {:error, :invalid_author}

  defp validate_question(nil), do: {:error, :empty_question}
  defp validate_question(""), do: {:error, :empty_question}
  defp validate_question(q) when is_binary(q), do: {:ok, q}
  defp validate_question(_), do: {:error, :invalid_question}

  defp validate_options([]), do: {:error, :invalid_options}
  defp validate_options(opts) when is_list(opts) do
    if Enum.all?(opts, &is_binary/1), do: {:ok, opts}, else: {:error, :invalid_options}
  end
  defp validate_options(_), do: {:error, :invalid_options}

  defp validate_thread(nil, _state), do: :ok
  defp validate_thread(id, state) do
    if Map.has_key?(state.messages, id), do: :ok, else: {:error, :thread_not_found}
  end
end
```

### 5. Manager Module (Orchestrator)

The Manager is now a thin GenServer that orchestrates the other modules.

```elixir
# lib/ipa/pod/manager.ex
defmodule Ipa.Pod.Manager do
  @moduledoc """
  Thin GenServer that orchestrates pod operations.

  Responsibilities:
  - Holds in-memory state
  - Routes commands to handlers
  - Persists events to EventStore
  - Runs periodic evaluation
  - Broadcasts state changes
  """

  use GenServer
  require Logger

  alias Ipa.EventStore
  alias Ipa.Pod.State
  alias Ipa.Pod.State.Projector
  alias Ipa.Pod.Machine.Evaluator
  alias Ipa.Pod.Event

  # Client API

  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(task_id))
  end

  @doc "Gets current state"
  def get_state(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, :get_state)}
    end
  end

  @doc "Executes a command and persists resulting events"
  def execute(task_id, command_module, command_fn, args) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:execute, command_module, command_fn, args})
    end
  end

  @doc "Subscribes to state updates"
  def subscribe(task_id) do
    Phoenix.PubSub.subscribe(Ipa.PubSub, "pod:#{task_id}")
  end

  @doc "Triggers manual evaluation"
  def evaluate(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> :ok
      pid -> send(pid, :evaluate)
    end
    :ok
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)

    Logger.info("Pod.Manager starting for task #{task_id}")

    state = recover_state(task_id)
    schedule_evaluation(state.config.evaluation_interval)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:execute, command_module, command_fn, args}, _from, state) do
    # Execute command to get events
    case apply(command_module, command_fn, [state | args]) do
      {:ok, events} ->
        # Persist and apply events
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)
            maybe_trigger_evaluation(events)
            {:reply, {:ok, new_state.version}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:evaluate, state) do
    new_state = run_evaluation(state)
    schedule_evaluation(state.config.evaluation_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private Functions

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:manager, task_id}}}
  end

  defp recover_state(task_id) do
    case EventStore.read_stream(task_id) do
      {:ok, events} when events != [] ->
        Logger.info("Recovering state from #{length(events)} events")
        typed_events = Enum.map(events, &Event.decode/1)
        Projector.replay(typed_events, State.new(task_id))

      _ ->
        Logger.info("No events found, starting fresh")
        State.new(task_id)
    end
  end

  defp persist_and_apply_events(state, events) do
    # Build batch for EventStore
    event_batch = Enum.map(events, fn event ->
      module = event.__struct__
      %{
        event_type: module.event_type(),
        data: module.to_map(event),
        opts: []
      }
    end)

    case EventStore.append_batch(state.task_id, event_batch) do
      {:ok, new_version} ->
        # Apply events to state
        new_state = Enum.reduce(events, state, &Projector.apply(&2, &1))
        {:ok, %{new_state | version: new_version}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_evaluation(state) do
    actions = Evaluator.evaluate(state)

    Enum.reduce(actions, state, fn action, acc ->
      execute_action(acc, action)
    end)
  end

  defp execute_action(state, {:request_transition, to_phase, reason}) do
    alias Ipa.Pod.Commands.PhaseCommands

    case PhaseCommands.request_transition(state, to_phase, reason, "scheduler") do
      {:ok, events} ->
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)
            new_state
          _ -> state
        end
      _ -> state
    end
  end

  defp execute_action(state, {:start_workstream, workstream_id}) do
    # Start agent via Agent.Supervisor
    ws = Map.get(state.workstreams, workstream_id)

    context = %{
      task_id: state.task_id,
      workstream_id: workstream_id,
      workstream_spec: ws.spec
    }

    case Ipa.Agent.Supervisor.start_agent(state.task_id, Ipa.Agent.Types.Workstream, context) do
      {:ok, agent_id} ->
        alias Ipa.Pod.Commands.WorkstreamCommands

        case WorkstreamCommands.start_workstream(state, workstream_id, agent_id) do
          {:ok, events} ->
            case persist_and_apply_events(state, events) do
              {:ok, new_state} ->
                broadcast_state_update(new_state)
                new_state
              _ -> state
            end
          _ -> state
        end

      {:error, _} -> state
    end
  end

  defp execute_action(state, {:spawn_agent, :planning, context}) do
    case Ipa.Agent.Supervisor.start_agent(state.task_id, Ipa.Agent.Types.Planning, context) do
      {:ok, _agent_id} -> state
      {:error, _} -> state
    end
  end

  defp execute_action(state, :noop), do: state

  defp schedule_evaluation(interval) do
    Process.send_after(self(), :evaluate, interval)
  end

  defp broadcast_state_update(state) do
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      "pod:#{state.task_id}",
      {:state_updated, state.task_id, state}
    )
  end

  defp maybe_trigger_evaluation(events) do
    trigger_types = [
      Ipa.Pod.Events.SpecApproved,
      Ipa.Pod.Events.TransitionApproved,
      Ipa.Pod.Events.WorkstreamCompleted,
      Ipa.Pod.Events.WorkstreamFailed
    ]

    if Enum.any?(events, fn e -> e.__struct__ in trigger_types end) do
      send(self(), :evaluate)
    end
  end
end
```

## Migration Plan

### Phase 1: Create New Modules (Non-Breaking)

1. Create `lib/ipa/pod/events/` directory with all event structs
2. Create `lib/ipa/pod/state/` directory with State struct and projections
3. Create `lib/ipa/pod/machine/` directory with Machine, Guards, Evaluator
4. Create `lib/ipa/pod/commands/` directory with all command modules
5. Write tests for each new module in isolation

### Phase 2: Parallel Operation

1. Create new `Ipa.Pod.ManagerV2` using new architecture
2. Run both old and new managers in parallel (read from same EventStore)
3. Verify state consistency between old and new

### Phase 3: Switchover

1. Update `CommunicationsManager` to use new command pattern
2. Update `WorkspaceManager` to use new event pattern
3. Update LiveView to work with new state structure
4. Remove old `Pod.Manager`

### Phase 4: Cleanup

1. Remove `CommunicationsManager` local state caching (no longer needed)
2. Update all callers to use new API
3. Remove deprecated modules
4. Update tests

## Testing Strategy

### Unit Tests

- Each event struct: serialization/deserialization
- Each projection: event → state transformation
- Each command: validation + event generation
- Machine: transition validity
- Guards: transition conditions
- Evaluator: action generation

### Integration Tests

- Manager: command → persist → project flow
- Event replay: consistency verification
- PubSub: state broadcast verification

### Property-Based Tests

- Event replay produces same state regardless of timing
- Commands are idempotent where expected
- State machine never reaches invalid states

## Summary

This refactoring:

1. **Separates concerns** - Events, State, Commands, Machine, Manager all have clear responsibilities
2. **Adds type safety** - Typed event structs with `@enforce_keys`
3. **Simplifies projections** - Small, focused projection modules instead of one giant function
4. **Makes state machine explicit** - Clear phase definitions and transition rules
5. **Enables easier testing** - Each module can be tested in isolation
6. **Maintains event sourcing** - Same EventStore, just better organization above it
