defmodule Ipa.Pod.State.Projections.AgentProjection do
  @moduledoc "Projects agent lifecycle events onto state."

  alias Ipa.Pod.State
  alias Ipa.Pod.State.Agent

  alias Ipa.Pod.Events.{
    AgentStarted,
    AgentCompleted,
    AgentFailed
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
