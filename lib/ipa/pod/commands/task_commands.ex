defmodule Ipa.Pod.Commands.TaskCommands do
  @moduledoc """
  Commands for task lifecycle management.

  Commands validate against current state and return events to be persisted.
  """

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    TaskCreated,
    SpecUpdated,
    SpecApproved,
    SpecGenerationStarted,
    SpecGenerationCompleted,
    PlanCreated,
    PlanUpdated,
    PlanApproved
  }

  @type result :: {:ok, [struct()]} | {:error, atom() | String.t()}

  @doc """
  Creates a new task. This is special - it doesn't require existing state.
  """
  @spec create_task(map()) :: result()
  def create_task(params) do
    with {:ok, task_id} <- validate_task_id(params[:task_id]),
         {:ok, title} <- validate_required_string(params[:title], :title_required) do
      event = %TaskCreated{
        task_id: task_id,
        title: title,
        description: params[:description],
        requirements: params[:requirements] || [],
        acceptance_criteria: params[:acceptance_criteria] || [],
        external_references: params[:external_references] || %{}
      }

      {:ok, [event]}
    end
  end

  @doc """
  Updates the task spec content (markdown).
  """
  @spec update_spec(State.t(), map()) :: result()
  def update_spec(state, params) do
    cond do
      State.spec_approved?(state) ->
        {:error, :spec_already_approved}

      state.phase != :spec_clarification ->
        {:error, :invalid_phase}

      true ->
        event = %SpecUpdated{
          task_id: state.task_id,
          content: params[:content],
          workspace_path: params[:workspace_path]
        }

        {:ok, [event]}
    end
  end

  @doc """
  Approves the task spec.
  """
  @spec approve_spec(State.t(), String.t(), String.t() | nil) :: result()
  def approve_spec(state, approved_by, comment \\ nil) do
    cond do
      State.spec_approved?(state) ->
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

  @doc """
  Starts spec generation with an agent.
  """
  @spec start_spec_generation(State.t(), map()) :: result()
  def start_spec_generation(state, params) do
    cond do
      State.spec_approved?(state) ->
        {:error, :spec_already_approved}

      state.phase != :spec_clarification ->
        {:error, :invalid_phase}

      get_in(state.spec, [:generation_status]) == :generating ->
        {:error, :generation_in_progress}

      true ->
        event = %SpecGenerationStarted{
          task_id: state.task_id,
          agent_id: params[:agent_id] || Ecto.UUID.generate(),
          workspace_path: params[:workspace_path],
          input_content: params[:input_content]
        }

        {:ok, [event]}
    end
  end

  @doc """
  Marks spec generation as complete.
  Called when the spec generator agent finishes.
  """
  @spec complete_spec_generation(State.t(), map()) :: result()
  def complete_spec_generation(state, params) do
    cond do
      state.phase != :spec_clarification ->
        {:error, :invalid_phase}

      get_in(state.spec, [:generation_status]) != :generating ->
        {:error, :not_generating}

      true ->
        event = %SpecGenerationCompleted{
          task_id: state.task_id,
          agent_id: params[:agent_id],
          workspace_path: params[:workspace_path]
        }

        {:ok, [event]}
    end
  end

  @doc """
  Creates a plan for the task.
  """
  @spec create_plan(State.t(), map()) :: result()
  def create_plan(state, params) do
    cond do
      state.phase != :planning ->
        {:error, :invalid_phase}

      state.plan != nil ->
        {:error, :plan_already_exists}

      true ->
        event = %PlanCreated{
          task_id: state.task_id,
          summary: params[:summary],
          workstreams: params[:workstreams] || [],
          created_by: params[:created_by]
        }

        {:ok, [event]}
    end
  end

  @doc """
  Updates the plan.
  """
  @spec update_plan(State.t(), map()) :: result()
  def update_plan(state, params) do
    cond do
      state.phase != :planning ->
        {:error, :invalid_phase}

      state.plan == nil ->
        {:error, :no_plan}

      State.plan_approved?(state) ->
        {:error, :plan_already_approved}

      true ->
        event = %PlanUpdated{
          task_id: state.task_id,
          summary: params[:summary],
          workstreams: params[:workstreams],
          updated_by: params[:updated_by]
        }

        {:ok, [event]}
    end
  end

  @doc """
  Approves the plan.
  """
  @spec approve_plan(State.t(), String.t(), String.t() | nil) :: result()
  def approve_plan(state, approved_by, comment \\ nil) do
    cond do
      state.phase != :planning ->
        {:error, :invalid_phase}

      state.plan == nil ->
        {:error, :no_plan}

      State.plan_approved?(state) ->
        {:error, :already_approved}

      true ->
        event = %PlanApproved{
          task_id: state.task_id,
          approved_by: approved_by,
          comment: comment
        }

        {:ok, [event]}
    end
  end

  # Validation helpers

  defp validate_task_id(nil), do: {:ok, Ecto.UUID.generate()}
  defp validate_task_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_task_id(_), do: {:error, :invalid_task_id}

  defp validate_required_string(nil, error), do: {:error, error}
  defp validate_required_string("", error), do: {:error, error}
  defp validate_required_string(s, _error) when is_binary(s), do: {:ok, s}
  defp validate_required_string(_, error), do: {:error, error}
end
