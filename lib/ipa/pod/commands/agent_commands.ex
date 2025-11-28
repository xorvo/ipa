defmodule Ipa.Pod.Commands.AgentCommands do
  @moduledoc """
  Commands for agent lifecycle management.
  """

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    AgentStarted,
    AgentCompleted,
    AgentFailed,
    AgentPendingStart,
    AgentManuallyStarted,
    AgentAwaitingInput,
    AgentMessageSent,
    AgentMarkedDone
  }

  @type result :: {:ok, [struct()]} | {:error, atom() | String.t()}

  @doc """
  Records that an agent has started.
  """
  @spec start_agent(State.t(), map()) :: result()
  def start_agent(state, params) do
    with {:ok, agent_id} <- validate_agent_id(params[:agent_id]),
         {:ok, agent_type} <- validate_agent_type(params[:agent_type]) do
      event = %AgentStarted{
        task_id: state.task_id,
        agent_id: agent_id,
        agent_type: agent_type,
        workstream_id: params[:workstream_id],
        workspace_path: params[:workspace_path]
      }

      {:ok, [event]}
    end
  end

  @doc """
  Records that an agent has completed successfully.
  """
  @spec complete_agent(State.t(), String.t(), String.t() | nil) :: result()
  def complete_agent(state, agent_id, result_summary \\ nil) do
    case find_agent(state, agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent when agent.status != :running ->
        {:error, :agent_not_running}

      _agent ->
        event = %AgentCompleted{
          task_id: state.task_id,
          agent_id: agent_id,
          result_summary: result_summary
        }

        {:ok, [event]}
    end
  end

  @doc """
  Records that an agent has failed.
  """
  @spec fail_agent(State.t(), String.t(), String.t()) :: result()
  def fail_agent(state, agent_id, error) do
    case find_agent(state, agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent when agent.status != :running ->
        {:error, :agent_not_running}

      _agent ->
        event = %AgentFailed{
          task_id: state.task_id,
          agent_id: agent_id,
          error: error
        }

        {:ok, [event]}
    end
  end

  @doc """
  Creates a pending agent (waiting for manual start).
  Used when auto_start_agents is false.
  """
  @spec prepare_agent(State.t(), map()) :: result()
  def prepare_agent(state, params) do
    with {:ok, agent_id} <- validate_agent_id(params[:agent_id]),
         {:ok, agent_type} <- validate_agent_type(params[:agent_type]) do
      event = %AgentPendingStart{
        task_id: state.task_id,
        agent_id: agent_id,
        agent_type: agent_type,
        workstream_id: params[:workstream_id],
        workspace_path: params[:workspace_path],
        prompt: params[:prompt],
        interactive: params[:interactive] != false
      }

      {:ok, [event]}
    end
  end

  @doc """
  Manually starts a pending agent.
  """
  @spec manually_start_agent(State.t(), String.t(), String.t() | nil) :: result()
  def manually_start_agent(state, agent_id, started_by \\ nil) do
    case find_agent(state, agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent when agent.status != :pending_start ->
        {:error, :agent_not_pending}

      _agent ->
        event = %AgentManuallyStarted{
          task_id: state.task_id,
          agent_id: agent_id,
          started_by: started_by
        }

        {:ok, [event]}
    end
  end

  @doc """
  Records that an agent is awaiting user input.
  """
  @spec await_input(State.t(), String.t(), String.t() | nil, String.t() | nil) :: result()
  def await_input(state, agent_id, prompt_for_user \\ nil, current_output \\ nil) do
    case find_agent(state, agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent when agent.status != :running ->
        {:error, :agent_not_running}

      _agent ->
        event = %AgentAwaitingInput{
          task_id: state.task_id,
          agent_id: agent_id,
          prompt_for_user: prompt_for_user,
          current_output: current_output
        }

        {:ok, [event]}
    end
  end

  @doc """
  Records a message sent to an agent.
  """
  @spec send_message_to_agent(State.t(), String.t(), String.t(), map()) :: result()
  def send_message_to_agent(state, agent_id, message, opts \\ %{}) do
    case find_agent(state, agent_id) do
      nil ->
        {:error, :agent_not_found}

      _agent ->
        event = %AgentMessageSent{
          task_id: state.task_id,
          agent_id: agent_id,
          message: message,
          sent_by: opts[:sent_by],
          batch_id: opts[:batch_id]
        }

        {:ok, [event]}
    end
  end

  @doc """
  Marks an agent's work as done (approved by user).
  """
  @spec mark_agent_done(State.t(), String.t(), map()) :: result()
  def mark_agent_done(state, agent_id, opts \\ %{}) do
    case find_agent(state, agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent when agent.status in [:completed, :failed, :interrupted] ->
        {:error, :agent_already_terminal}

      _agent ->
        event = %AgentMarkedDone{
          task_id: state.task_id,
          agent_id: agent_id,
          marked_by: opts[:marked_by],
          reason: opts[:reason]
        }

        {:ok, [event]}
    end
  end

  @doc """
  Restarts a failed or interrupted agent by creating a new pending agent
  with the same context (workstream, workspace, etc.) but a new agent_id.

  Returns the new agent_id in the event.
  """
  @spec restart_agent(State.t(), String.t(), String.t() | nil) :: result()
  def restart_agent(state, agent_id, restarted_by \\ nil) do
    case find_agent(state, agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent when agent.status not in [:failed, :interrupted] ->
        {:error, :agent_not_restartable}

      agent ->
        # Generate a new agent_id for the restarted agent
        new_agent_id = generate_restart_agent_id(agent.agent_type)

        # Create a new pending agent with the same context
        # Note: prompt is not stored in Agent struct, so we pass nil.
        # The prompt will be regenerated when the agent actually starts.
        event = %AgentPendingStart{
          task_id: state.task_id,
          agent_id: new_agent_id,
          agent_type: agent.agent_type,
          workstream_id: agent.workstream_id,
          workspace_path: agent.workspace_path,
          prompt: nil,
          interactive: Map.get(agent, :interactive, true),
          # Track restart lineage
          restarted_from: agent_id,
          restarted_by: restarted_by
        }

        {:ok, [event]}
    end
  end

  defp generate_restart_agent_id(:planning), do: "planning-agent-#{:rand.uniform(99999)}"
  defp generate_restart_agent_id(:planning_agent), do: "planning-agent-#{:rand.uniform(99999)}"
  defp generate_restart_agent_id(:workstream), do: "workstream-#{:rand.uniform(99999)}"
  defp generate_restart_agent_id(_), do: "agent-#{:rand.uniform(99999)}"

  # Helpers

  defp find_agent(state, agent_id) do
    Enum.find(state.agents, fn a -> a.agent_id == agent_id end)
  end

  defp validate_agent_id(nil), do: {:ok, Ecto.UUID.generate()}
  defp validate_agent_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_agent_id(_), do: {:error, :invalid_agent_id}

  defp validate_agent_type(type) when type in [:planning, :planning_agent, :workstream, :review],
    do: {:ok, type}

  defp validate_agent_type(type) when is_binary(type) do
    case type do
      "planning" -> {:ok, :planning}
      "planning_agent" -> {:ok, :planning_agent}
      "workstream" -> {:ok, :workstream}
      "review" -> {:ok, :review}
      _ -> {:error, :invalid_agent_type}
    end
  end

  defp validate_agent_type(_), do: {:error, :invalid_agent_type}
end
