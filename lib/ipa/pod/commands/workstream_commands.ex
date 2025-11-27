defmodule Ipa.Pod.Commands.WorkstreamCommands do
  @moduledoc """
  Commands for workstream management.

  Workstreams are units of work that can be executed in parallel.
  """

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    WorkstreamCreated,
    WorkstreamStarted,
    WorkstreamCompleted,
    WorkstreamFailed
  }

  @type result :: {:ok, [struct()]} | {:error, atom() | String.t()}

  @doc """
  Creates a new workstream.
  """
  @spec create_workstream(State.t(), map()) :: result()
  def create_workstream(state, params) do
    workstream_id = params[:workstream_id] || Ecto.UUID.generate()

    cond do
      state.phase not in [:planning, :workstream_execution] ->
        {:error, :invalid_phase}

      Map.has_key?(state.workstreams, workstream_id) ->
        {:error, :workstream_exists}

      params[:title] == nil or params[:title] == "" ->
        {:error, :title_required}

      not valid_dependencies?(params[:dependencies], state) ->
        {:error, :invalid_dependencies}

      true ->
        event = %WorkstreamCreated{
          task_id: state.task_id,
          workstream_id: workstream_id,
          title: params[:title],
          spec: params[:spec],
          dependencies: params[:dependencies] || [],
          priority: params[:priority] || :normal
        }

        {:ok, [event]}
    end
  end

  @doc """
  Marks a workstream as started.
  """
  @spec start_workstream(State.t(), String.t(), String.t(), String.t() | nil) :: result()
  def start_workstream(state, workstream_id, agent_id, workspace_path \\ nil) do
    case State.get_workstream(state, workstream_id) do
      nil ->
        {:error, :workstream_not_found}

      ws when ws.status != :pending ->
        {:error, :workstream_not_pending}

      ws when ws.blocking_on != [] ->
        {:error, :dependencies_not_satisfied}

      _ws ->
        event = %WorkstreamStarted{
          task_id: state.task_id,
          workstream_id: workstream_id,
          agent_id: agent_id,
          workspace_path: workspace_path
        }

        {:ok, [event]}
    end
  end

  @doc """
  Marks a workstream as completed.
  """
  @spec complete_workstream(State.t(), String.t(), map()) :: result()
  def complete_workstream(state, workstream_id, result \\ %{}) do
    case State.get_workstream(state, workstream_id) do
      nil ->
        {:error, :workstream_not_found}

      ws when ws.status != :in_progress ->
        {:error, :workstream_not_in_progress}

      _ws ->
        event = %WorkstreamCompleted{
          task_id: state.task_id,
          workstream_id: workstream_id,
          result_summary: result[:summary],
          artifacts: result[:artifacts]
        }

        {:ok, [event]}
    end
  end

  @doc """
  Marks a workstream as failed.
  """
  @spec fail_workstream(State.t(), String.t(), String.t(), boolean()) :: result()
  def fail_workstream(state, workstream_id, error, recoverable? \\ false) do
    case State.get_workstream(state, workstream_id) do
      nil ->
        {:error, :workstream_not_found}

      _ws ->
        event = %WorkstreamFailed{
          task_id: state.task_id,
          workstream_id: workstream_id,
          error: error,
          recoverable?: recoverable?
        }

        {:ok, [event]}
    end
  end

  @doc """
  Retries a failed workstream by resetting it to pending.

  Note: This would need a WorkstreamRetried event - for now, we'd need to
  create a new workstream or handle this differently.
  """
  @spec retry_workstream(State.t(), String.t()) :: result()
  def retry_workstream(state, workstream_id) do
    case State.get_workstream(state, workstream_id) do
      nil ->
        {:error, :workstream_not_found}

      ws when ws.status != :failed ->
        {:error, :workstream_not_failed}

      _ws ->
        # For now, we don't have a retry event - this would need to be added
        {:error, :not_implemented}
    end
  end

  # Validation helpers

  defp valid_dependencies?(nil, _state), do: true
  defp valid_dependencies?([], _state), do: true

  defp valid_dependencies?(deps, _state) when is_list(deps) do
    # Check that all dependencies reference existing workstreams
    # (or will be created - can't check that here)
    # For now, just validate it's a list of strings
    Enum.all?(deps, &is_binary/1)
  end

  defp valid_dependencies?(_, _state), do: false
end
