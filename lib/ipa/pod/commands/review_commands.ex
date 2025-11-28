defmodule Ipa.Pod.Commands.ReviewCommands do
  @moduledoc """
  Commands for managing review threads (resolve/reopen).
  """

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    ReviewThreadResolved,
    ReviewThreadReopened
  }

  @type result :: {:ok, [struct()]} | {:error, atom() | String.t()}

  @doc """
  Resolves a review thread.

  The thread_id is the message_id of the root review comment.

  ## Required params:
  - thread_id: the message_id of the root review comment
  - resolved_by: who is resolving the thread

  ## Optional params:
  - resolution_comment: optional comment explaining the resolution
  """
  @spec resolve_thread(State.t(), map()) :: result()
  def resolve_thread(state, params) do
    with {:ok, thread_id} <- validate_thread_id(params[:thread_id]),
         {:ok, resolved_by} <- validate_actor(params[:resolved_by]),
         {:ok, thread_message} <- get_review_thread(state, thread_id),
         :ok <- validate_not_resolved(thread_message) do
      event = %ReviewThreadResolved{
        task_id: state.task_id,
        thread_id: thread_id,
        resolved_by: resolved_by,
        resolution_comment: params[:resolution_comment]
      }

      {:ok, [event]}
    end
  end

  @doc """
  Reopens a resolved review thread.

  ## Required params:
  - thread_id: the message_id of the root review comment
  - reopened_by: who is reopening the thread
  """
  @spec reopen_thread(State.t(), map()) :: result()
  def reopen_thread(state, params) do
    with {:ok, thread_id} <- validate_thread_id(params[:thread_id]),
         {:ok, reopened_by} <- validate_actor(params[:reopened_by]),
         {:ok, thread_message} <- get_review_thread(state, thread_id),
         :ok <- validate_is_resolved(thread_message) do
      event = %ReviewThreadReopened{
        task_id: state.task_id,
        thread_id: thread_id,
        reopened_by: reopened_by
      }

      {:ok, [event]}
    end
  end

  # Validation helpers

  defp validate_thread_id(nil), do: {:error, :missing_thread_id}
  defp validate_thread_id(""), do: {:error, :missing_thread_id}
  defp validate_thread_id(id) when is_binary(id), do: {:ok, id}
  defp validate_thread_id(_), do: {:error, :invalid_thread_id}

  defp validate_actor(nil), do: {:error, :missing_actor}
  defp validate_actor(""), do: {:error, :missing_actor}
  defp validate_actor(actor) when is_binary(actor), do: {:ok, actor}
  defp validate_actor(_), do: {:error, :invalid_actor}

  defp get_review_thread(state, thread_id) do
    case Map.get(state.messages, thread_id) do
      nil ->
        {:error, :thread_not_found}

      msg ->
        if msg.message_type == :review_comment do
          {:ok, msg}
        else
          {:error, :not_review_thread}
        end
    end
  end

  defp validate_not_resolved(message) do
    resolved? = get_in(message.metadata, [:resolved?]) || false

    if resolved? do
      {:error, :already_resolved}
    else
      :ok
    end
  end

  defp validate_is_resolved(message) do
    resolved? = get_in(message.metadata, [:resolved?]) || false

    if resolved? do
      :ok
    else
      {:error, :not_resolved}
    end
  end
end
