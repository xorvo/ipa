defmodule Ipa.Pod.State do
  @moduledoc """
  The Pod state struct - the read model built by projecting events.

  This is the single source of truth for pod state. It is:
  - Built by replaying events from the EventStore
  - Updated in-memory as new events are appended
  - Never directly mutated - only via event application
  """

  alias Ipa.Pod.State.{Workstream, Message, Notification, Agent}

  @type phase ::
          :spec_clarification
          | :planning
          | :workstream_execution
          | :review
          | :completed
          | :cancelled

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
      external_references: %{},
      approved?: false,
      approved_by: nil,
      approved_at: nil
    },
    plan: nil,
    workstreams: %{},
    agents: [],
    messages: %{},
    notifications: [],
    pending_transitions: [],
    config: %{
      max_concurrent_agents: 3,
      evaluation_interval: 5_000
    }
  ]

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          title: String.t() | nil,
          version: integer() | nil,
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

  @doc "Creates a new empty state for a task."
  @spec new(String.t()) :: t()
  def new(task_id) do
    %__MODULE__{
      task_id: task_id,
      version: 0,
      created_at: System.system_time(:second)
    }
  end

  @doc "Returns true if spec is approved."
  @spec spec_approved?(t()) :: boolean()
  def spec_approved?(%__MODULE__{spec: spec}), do: Map.get(spec, :approved?, false)

  @doc "Returns true if plan is approved."
  @spec plan_approved?(t()) :: boolean()
  def plan_approved?(%__MODULE__{plan: nil}), do: false
  def plan_approved?(%__MODULE__{plan: plan}), do: Map.get(plan, :approved?, false)

  @doc "Counts running agents."
  @spec running_agent_count(t()) :: non_neg_integer()
  def running_agent_count(%__MODULE__{agents: agents}) do
    Enum.count(agents, fn a -> a.status == :running end)
  end

  @doc "Returns true if there are no running agents."
  @spec no_running_agents?(t()) :: boolean()
  def no_running_agents?(state), do: running_agent_count(state) == 0

  @doc "Returns true if there's a planning agent running."
  @spec planning_agent_running?(t()) :: boolean()
  def planning_agent_running?(%__MODULE__{agents: agents}) do
    Enum.any?(agents, fn a -> a.agent_type == :planning and a.status == :running end)
  end

  @doc "Returns true if there's any planning agent (running, completed, or failed)."
  @spec has_planning_agent?(t()) :: boolean()
  def has_planning_agent?(%__MODULE__{agents: agents}) do
    Enum.any?(agents, fn a -> a.agent_type == :planning end)
  end

  @doc "Gets a workstream by ID."
  @spec get_workstream(t(), String.t()) :: Workstream.t() | nil
  def get_workstream(%__MODULE__{workstreams: workstreams}, workstream_id) do
    Map.get(workstreams, workstream_id)
  end

  @doc "Gets a message by ID."
  @spec get_message(t(), String.t()) :: Message.t() | nil
  def get_message(%__MODULE__{messages: messages}, message_id) do
    Map.get(messages, message_id)
  end

  @doc "Gets unread notifications for a recipient."
  @spec unread_notifications(t(), String.t() | nil) :: [Notification.t()]
  def unread_notifications(%__MODULE__{notifications: notifications}, recipient \\ nil) do
    notifications
    |> Enum.filter(fn n -> not n.read? end)
    |> maybe_filter_recipient(recipient)
  end

  defp maybe_filter_recipient(notifications, nil), do: notifications

  defp maybe_filter_recipient(notifications, recipient) do
    Enum.filter(notifications, fn n -> n.recipient == recipient end)
  end
end

defmodule Ipa.Pod.State.Workstream do
  @moduledoc "Represents a workstream within a pod."

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
    blocking_on: [],
    priority: :normal
  ]

  @type t :: %__MODULE__{
          workstream_id: String.t(),
          title: String.t(),
          spec: String.t() | nil,
          status: status(),
          dependencies: [String.t()],
          blocking_on: [String.t()],
          priority: :low | :normal | :high,
          agent_id: String.t() | nil,
          workspace_path: String.t() | nil,
          started_at: integer() | nil,
          completed_at: integer() | nil,
          error: String.t() | nil
        }

  @doc "Returns true if workstream is ready to start (pending with no blockers)."
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{status: :pending, blocking_on: []}), do: true
  def ready?(_), do: false

  @doc "Returns true if workstream is terminal (completed or failed)."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed]
end

defmodule Ipa.Pod.State.Message do
  @moduledoc "Represents a message or approval request."

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

  @type t :: %__MODULE__{
          message_id: String.t(),
          author: String.t(),
          content: String.t(),
          message_type: message_type(),
          thread_id: String.t() | nil,
          workstream_id: String.t() | nil,
          posted_at: integer() | nil,
          approval_options: [String.t()] | nil,
          approved?: boolean(),
          approved_by: String.t() | nil,
          approval_choice: String.t() | nil,
          blocking?: boolean()
        }

  @doc "Returns true if this is an approval request."
  @spec approval?(t()) :: boolean()
  def approval?(%__MODULE__{message_type: :approval}), do: true
  def approval?(_), do: false

  @doc "Returns true if this approval is pending."
  @spec pending_approval?(t()) :: boolean()
  def pending_approval?(%__MODULE__{message_type: :approval, approved?: false}), do: true
  def pending_approval?(_), do: false
end

defmodule Ipa.Pod.State.Notification do
  @moduledoc "Represents a notification in the inbox."

  @type notification_type ::
          :needs_approval
          | :question_asked
          | :blocker_raised
          | :workstream_completed

  defstruct [
    :notification_id,
    :recipient,
    :notification_type,
    :message_id,
    :preview,
    :created_at,
    read?: false
  ]

  @type t :: %__MODULE__{
          notification_id: String.t(),
          recipient: String.t(),
          notification_type: notification_type(),
          message_id: String.t() | nil,
          preview: String.t() | nil,
          created_at: integer() | nil,
          read?: boolean()
        }
end

defmodule Ipa.Pod.State.Agent do
  @moduledoc "Represents an agent instance."

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
    :output,
    status: :running
  ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          agent_type: agent_type(),
          workstream_id: String.t() | nil,
          workspace_path: String.t() | nil,
          status: status(),
          started_at: integer() | nil,
          completed_at: integer() | nil,
          error: String.t() | nil,
          output: String.t() | nil
        }

  @doc "Returns true if agent is running."
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{status: :running}), do: true
  def running?(_), do: false
end
