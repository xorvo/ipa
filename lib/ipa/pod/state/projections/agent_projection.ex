defmodule Ipa.Pod.State.Projections.AgentProjection do
  @moduledoc "Projects agent lifecycle events onto state."

  alias Ipa.Pod.State
  alias Ipa.Pod.State.Agent

  alias Ipa.Pod.Events.{
    AgentStarted,
    AgentCompleted,
    AgentFailed,
    AgentInterrupted,
    AgentPendingStart,
    AgentManuallyStarted,
    AgentAwaitingInput,
    AgentMessageSent,
    AgentResponseReceived,
    AgentMarkedDone
  }

  @doc "Applies an agent event to state."
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, %AgentStarted{} = event) do
    # Check if agent already exists (prevent duplicates)
    existing = Enum.find(state.agents, fn a -> a.agent_id == event.agent_id end)

    if existing do
      # Agent already exists, don't add duplicate
      state
    else
      agent = %Agent{
        agent_id: event.agent_id,
        agent_type: event.agent_type,
        workstream_id: event.workstream_id,
        workspace_path: event.workspace_path,
        status: :running,
        started_at: System.system_time(:second)
      }

      %{state | agents: [agent | state.agents]}
    end
  end

  def apply(state, %AgentCompleted{} = event) do
    update_agent(state, event.agent_id, fn agent ->
      %{
        agent
        | status: :completed,
          completed_at: System.system_time(:second),
          output: event.output
      }
    end)
  end

  def apply(state, %AgentFailed{} = event) do
    update_agent(state, event.agent_id, fn agent ->
      %{
        agent
        | status: :failed,
          error: event.error,
          completed_at: System.system_time(:second)
      }
    end)
  end

  def apply(state, %AgentInterrupted{} = event) do
    update_agent(state, event.agent_id, fn agent ->
      %{
        agent
        | status: :interrupted,
          completed_at: System.system_time(:second)
      }
    end)
  end

  def apply(state, %AgentPendingStart{} = event) do
    # Check if agent already exists (prevent duplicates)
    existing = Enum.find(state.agents, fn a -> a.agent_id == event.agent_id end)

    if existing do
      state
    else
      agent = %Agent{
        agent_id: event.agent_id,
        agent_type: event.agent_type,
        workstream_id: event.workstream_id,
        workspace_path: event.workspace_path,
        interactive: event.interactive,
        status: :pending_start,
        conversation_history: []
      }

      %{state | agents: [agent | state.agents]}
    end
  end

  def apply(state, %AgentManuallyStarted{} = event) do
    update_agent(state, event.agent_id, fn agent ->
      %{
        agent
        | status: :running,
          started_at: System.system_time(:second)
      }
    end)
  end

  def apply(state, %AgentAwaitingInput{} = event) do
    update_agent(state, event.agent_id, fn agent ->
      # Update output if provided (snapshot of current work)
      agent =
        if event.current_output do
          %{agent | output: event.current_output}
        else
          agent
        end

      %{agent | status: :awaiting_input}
    end)
  end

  def apply(state, %AgentMessageSent{} = event) do
    update_agent(state, event.agent_id, fn agent ->
      # Use the role from the event (defaults to :user, but can be :system for initial prompts)
      message = %{
        role: event.role || :user,
        content: event.message,
        sent_by: event.sent_by,
        batch_id: event.batch_id,
        timestamp: System.system_time(:second)
      }

      conversation_history = agent.conversation_history ++ [message]
      %{agent | conversation_history: conversation_history}
    end)
  end

  def apply(state, %AgentResponseReceived{} = event) do
    update_agent(state, event.agent_id, fn agent ->
      message = %{
        role: :assistant,
        content: event.response,
        timestamp: System.system_time(:second)
      }

      conversation_history = agent.conversation_history ++ [message]
      # Also update the output field with the latest response
      %{agent | conversation_history: conversation_history, output: event.response}
    end)
  end

  def apply(state, %AgentMarkedDone{} = event) do
    update_agent(state, event.agent_id, fn agent ->
      %{
        agent
        | status: :completed,
          completed_at: System.system_time(:second)
      }
    end)
  end

  def apply(state, _event), do: state

  # Helpers

  defp update_agent(state, agent_id, update_fn) do
    agents =
      Enum.map(state.agents, fn agent ->
        if agent.agent_id == agent_id do
          update_fn.(agent)
        else
          agent
        end
      end)

    %{state | agents: agents}
  end
end
