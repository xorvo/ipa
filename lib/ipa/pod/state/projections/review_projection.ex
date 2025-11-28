defmodule Ipa.Pod.State.Projections.ReviewProjection do
  @moduledoc "Projects review events onto state (thread resolution)."

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    ReviewThreadResolved,
    ReviewThreadReopened
  }

  @doc "Applies a review event to state."
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, %ReviewThreadResolved{} = event) do
    # Find the root message of this thread and update its metadata
    update_thread_metadata(state, event.thread_id, fn metadata ->
      metadata
      |> Map.put(:resolved?, true)
      |> Map.put(:resolved_by, event.resolved_by)
      |> Map.put(:resolved_at, System.system_time(:second))
      |> maybe_put(:resolution_comment, event.resolution_comment)
    end)
  end

  def apply(state, %ReviewThreadReopened{} = event) do
    # Find the root message of this thread and update its metadata
    update_thread_metadata(state, event.thread_id, fn metadata ->
      metadata
      |> Map.put(:resolved?, false)
      |> Map.delete(:resolved_by)
      |> Map.delete(:resolved_at)
      |> Map.delete(:resolution_comment)
    end)
  end

  def apply(state, _event), do: state

  # Helpers

  defp update_thread_metadata(state, thread_id, update_fn) do
    # The thread_id is the message_id of the root message
    case Map.get(state.messages, thread_id) do
      nil ->
        state

      msg when msg.message_type == :review_comment ->
        updated_metadata = update_fn.(msg.metadata || %{})
        updated_msg = %{msg | metadata: updated_metadata}
        %{state | messages: Map.put(state.messages, thread_id, updated_msg)}

      _msg ->
        # Not a review comment, ignore
        state
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
