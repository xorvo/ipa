defmodule Ipa.Pod.Events.AgentStarted do
  @moduledoc "Event emitted when an agent is started."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id, :agent_type]
  defstruct [
    :task_id,
    :agent_id,
    :agent_type,
    :workstream_id,
    :workspace_path
  ]

  @type agent_type :: :planning | :workstream | :review

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          agent_type: agent_type(),
          workstream_id: String.t() | nil,
          workspace_path: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_started"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      agent_type: event.agent_type,
      workstream_id: event.workstream_id,
      workspace_path: event.workspace_path
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      agent_type: normalize_agent_type(get_field(data, :agent_type)),
      workstream_id: get_field(data, :workstream_id),
      workspace_path: get_field(data, :workspace_path) || get_field(data, :workspace)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_agent_type(:planning), do: :planning
  defp normalize_agent_type(:planning_agent), do: :planning
  defp normalize_agent_type(:workstream), do: :workstream
  defp normalize_agent_type(:review), do: :review
  defp normalize_agent_type(:workstream_executor), do: :workstream
  defp normalize_agent_type("planning"), do: :planning
  defp normalize_agent_type("planning_agent"), do: :planning
  defp normalize_agent_type("workstream"), do: :workstream
  defp normalize_agent_type("review"), do: :review
  defp normalize_agent_type("workstream_executor"), do: :workstream

  defp normalize_agent_type(other) do
    require Logger
    Logger.warning("Unknown agent_type: #{inspect(other)}, defaulting to :workstream")
    :workstream
  end
end

defmodule Ipa.Pod.Events.AgentCompleted do
  @moduledoc "Event emitted when an agent completes."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id]
  defstruct [:task_id, :agent_id, :result_summary, :output]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          result_summary: String.t() | nil,
          output: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_completed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      result_summary: event.result_summary,
      output: event.output
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      result_summary: get_field(data, :result_summary),
      output: get_field(data, :output)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.AgentFailed do
  @moduledoc "Event emitted when an agent fails."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id, :error]
  defstruct [:task_id, :agent_id, :error]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          error: String.t()
        }

  @impl true
  def event_type, do: "agent_failed"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      error: event.error
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      error: get_field(data, :error)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.AgentInterrupted do
  @moduledoc "Event emitted when an agent is interrupted."
  @behaviour Ipa.Pod.Event

  @enforce_keys [:agent_id]
  defstruct [:task_id, :agent_id, :interrupted_by, :reason]

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          agent_id: String.t(),
          interrupted_by: String.t() | nil,
          reason: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_interrupted"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      interrupted_by: event.interrupted_by,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      interrupted_by: get_field(data, :interrupted_by),
      reason: get_field(data, :reason)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.AgentPendingStart do
  @moduledoc """
  Event emitted when an agent is created but waiting for manual start.
  Used when auto_start_agents is disabled or when restarting a failed agent.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id, :agent_type]
  defstruct [
    :task_id,
    :agent_id,
    :agent_type,
    :workstream_id,
    :workspace_path,
    :prompt,
    :restarted_from,
    :restarted_by,
    interactive: true
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          agent_type: atom(),
          workstream_id: String.t() | nil,
          workspace_path: String.t() | nil,
          prompt: String.t() | nil,
          restarted_from: String.t() | nil,
          restarted_by: String.t() | nil,
          interactive: boolean()
        }

  @impl true
  def event_type, do: "agent_pending_start"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      agent_type: event.agent_type,
      workstream_id: event.workstream_id,
      workspace_path: event.workspace_path,
      prompt: event.prompt,
      interactive: event.interactive,
      restarted_from: event.restarted_from,
      restarted_by: event.restarted_by
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      agent_type: normalize_agent_type(get_field(data, :agent_type)),
      workstream_id: get_field(data, :workstream_id),
      workspace_path: get_field(data, :workspace_path),
      prompt: get_field(data, :prompt),
      interactive: get_field(data, :interactive) != false,
      restarted_from: get_field(data, :restarted_from),
      restarted_by: get_field(data, :restarted_by)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_agent_type(type) when is_atom(type), do: type
  defp normalize_agent_type("planning"), do: :planning
  defp normalize_agent_type("planning_agent"), do: :planning_agent
  defp normalize_agent_type("workstream"), do: :workstream
  defp normalize_agent_type("review"), do: :review
  defp normalize_agent_type(other), do: String.to_atom(other)
end

defmodule Ipa.Pod.Events.AgentManuallyStarted do
  @moduledoc """
  Event emitted when an agent is manually started by a user.
  Transitions agent from pending_start to running.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id]
  defstruct [:task_id, :agent_id, :started_by]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          started_by: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_manually_started"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      started_by: event.started_by
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      started_by: get_field(data, :started_by)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.AgentAwaitingInput do
  @moduledoc """
  Event emitted when an agent pauses execution awaiting user input.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id]
  defstruct [:task_id, :agent_id, :prompt_for_user, :current_output]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          prompt_for_user: String.t() | nil,
          current_output: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_awaiting_input"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      prompt_for_user: event.prompt_for_user,
      current_output: event.current_output
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      prompt_for_user: get_field(data, :prompt_for_user),
      current_output: get_field(data, :current_output)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.AgentMessageSent do
  @moduledoc """
  Event emitted when a message is sent to an agent.

  This includes:
  - Initial prompt (role: :system, sent_by: "system")
  - User messages during conversation (role: :user)
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id, :message]
  defstruct [:task_id, :agent_id, :message, :sent_by, :batch_id, role: :user]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          message: String.t(),
          sent_by: String.t() | nil,
          batch_id: String.t() | nil,
          role: :user | :system
        }

  @impl true
  def event_type, do: "agent_message_sent"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      message: event.message,
      sent_by: event.sent_by,
      batch_id: event.batch_id,
      role: event.role
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      message: get_field(data, :message),
      sent_by: get_field(data, :sent_by),
      batch_id: get_field(data, :batch_id),
      role: normalize_role(get_field(data, :role))
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]

  defp normalize_role(:system), do: :system
  defp normalize_role("system"), do: :system
  defp normalize_role(_), do: :user
end

defmodule Ipa.Pod.Events.AgentResponseReceived do
  @moduledoc """
  Event emitted when an agent produces a response (completes a turn).
  This stores the agent's response in the conversation history.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id, :response]
  defstruct [:task_id, :agent_id, :response, :turn_number]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          response: String.t(),
          turn_number: integer() | nil
        }

  @impl true
  def event_type, do: "agent_response_received"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      response: event.response,
      turn_number: event.turn_number
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      response: get_field(data, :response),
      turn_number: get_field(data, :turn_number)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end

defmodule Ipa.Pod.Events.AgentMarkedDone do
  @moduledoc """
  Event emitted when a user marks an interactive agent's work as done/approved.
  This allows the agent to proceed without further review.
  """
  @behaviour Ipa.Pod.Event

  @enforce_keys [:task_id, :agent_id]
  defstruct [:task_id, :agent_id, :marked_by, :reason]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: String.t(),
          marked_by: String.t() | nil,
          reason: String.t() | nil
        }

  @impl true
  def event_type, do: "agent_marked_done"

  @impl true
  def to_map(%__MODULE__{} = event) do
    %{
      task_id: event.task_id,
      agent_id: event.agent_id,
      marked_by: event.marked_by,
      reason: event.reason
    }
  end

  @impl true
  def from_map(data) do
    %__MODULE__{
      task_id: get_field(data, :task_id),
      agent_id: get_field(data, :agent_id),
      marked_by: get_field(data, :marked_by),
      reason: get_field(data, :reason)
    }
  end

  defp get_field(data, key), do: data[key] || data[to_string(key)]
end
