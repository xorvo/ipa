defmodule Ipa.Pod.Commands.AgentCommands do
  @moduledoc """
  Commands for agent lifecycle management.
  """

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    AgentStarted,
    AgentCompleted,
    AgentFailed
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

  # Helpers

  defp find_agent(state, agent_id) do
    Enum.find(state.agents, fn a -> a.agent_id == agent_id end)
  end

  defp validate_agent_id(nil), do: {:ok, Ecto.UUID.generate()}
  defp validate_agent_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_agent_id(_), do: {:error, :invalid_agent_id}

  defp validate_agent_type(type) when type in [:planning, :workstream, :review], do: {:ok, type}

  defp validate_agent_type(type) when is_binary(type) do
    case type do
      "planning" -> {:ok, :planning}
      "workstream" -> {:ok, :workstream}
      "review" -> {:ok, :review}
      _ -> {:error, :invalid_agent_type}
    end
  end

  defp validate_agent_type(_), do: {:error, :invalid_agent_type}
end
