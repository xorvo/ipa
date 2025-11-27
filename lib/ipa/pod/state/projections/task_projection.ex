defmodule Ipa.Pod.State.Projections.TaskProjection do
  @moduledoc "Projects task-related events onto state."

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    TaskCreated,
    SpecUpdated,
    SpecApproved,
    PlanCreated,
    PlanUpdated,
    PlanApproved
  }

  @doc "Applies a task event to state."
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, %TaskCreated{} = event) do
    %{
      state
      | task_id: event.task_id,
        title: event.title,
        spec: %{
          description: event.description,
          requirements: event.requirements || [],
          acceptance_criteria: event.acceptance_criteria || [],
          external_references: event.external_references || %{},
          approved?: false,
          approved_by: nil,
          approved_at: nil
        },
        phase: :spec_clarification,
        created_at: System.system_time(:second)
    }
  end

  def apply(state, %SpecUpdated{} = event) do
    updated_spec =
      state.spec
      |> maybe_update(:description, event.description)
      |> maybe_update(:requirements, event.requirements)
      |> maybe_update(:acceptance_criteria, event.acceptance_criteria)
      |> maybe_update(:external_references, event.external_references)

    %{state | spec: updated_spec}
  end

  def apply(state, %SpecApproved{} = event) do
    updated_spec =
      state.spec
      |> Map.put(:approved?, true)
      |> Map.put(:approved_by, event.approved_by)
      |> Map.put(:approved_at, System.system_time(:second))

    %{state | spec: updated_spec}
  end

  def apply(state, %PlanCreated{} = event) do
    plan = %{
      summary: event.summary,
      workstreams: event.workstreams || [],
      created_by: event.created_by,
      approved?: false,
      approved_by: nil,
      approved_at: nil
    }

    %{state | plan: plan}
  end

  def apply(state, %PlanUpdated{} = event) do
    updated_plan =
      (state.plan || %{})
      |> maybe_update(:summary, event.summary)
      |> maybe_update(:workstreams, event.workstreams)
      |> maybe_update(:updated_by, event.updated_by)

    %{state | plan: updated_plan}
  end

  def apply(state, %PlanApproved{} = event) do
    updated_plan =
      (state.plan || %{})
      |> Map.put(:approved?, true)
      |> Map.put(:approved_by, event.approved_by)
      |> Map.put(:approved_at, System.system_time(:second))

    %{state | plan: updated_plan}
  end

  def apply(state, _event), do: state

  # Only update if value is not nil
  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)
end
