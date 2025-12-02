defmodule Ipa.Pod.State.Projections.TrackerProjection do
  @moduledoc """
  Projects tracker events onto pod state.

  Handles all tracker-related events including:
  - TrackerCreated - Initial tracker setup with phases and items
  - TrackerPhaseAdded - Adding new phases
  - TrackerItemAdded - Adding items to phases
  - TrackerItemUpdated - Updating item properties
  - TrackerItemRemoved - Removing items
  - TrackerItemStatusChanged - Status transitions
  - TrackerItemCommentAdded - Adding comments
  - TrackerPhaseEtaUpdated - Updating phase ETAs
  """

  alias Ipa.Pod.State
  alias Ipa.Pod.State.{Tracker, TrackerPhase, TrackerItem}

  alias Ipa.Pod.Events.{
    TrackerCreated,
    TrackerPhaseAdded,
    TrackerItemAdded,
    TrackerItemUpdated,
    TrackerItemRemoved,
    TrackerItemStatusChanged,
    TrackerItemCommentAdded,
    TrackerPhaseEtaUpdated
  }

  @doc """
  Applies a tracker event to state.
  """
  @spec apply(State.t(), struct()) :: State.t()
  def apply(state, %TrackerCreated{} = event) do
    now = System.system_time(:second)

    phases =
      Enum.with_index(event.phases)
      |> Enum.map(fn {phase_data, idx} ->
        phase_id = get_field(phase_data, :phase_id) || Ecto.UUID.generate()
        items_data = get_field(phase_data, :items) || []

        items =
          Enum.map(items_data, fn item_data ->
            %TrackerItem{
              item_id: get_field(item_data, :item_id) || Ecto.UUID.generate(),
              phase_id: phase_id,
              summary: get_field(item_data, :summary) || "",
              workstream_id: get_field(item_data, :workstream_id),
              status: normalize_status(get_field(item_data, :status)) || :todo,
              comments: [],
              created_at: now,
              updated_at: now
            }
          end)

        %TrackerPhase{
          phase_id: phase_id,
          name: get_field(phase_data, :name) || "Unnamed Phase",
          summary: get_field(phase_data, :summary),
          description: get_field(phase_data, :description),
          eta: parse_eta(get_field(phase_data, :eta)),
          order: get_field(phase_data, :order) || idx,
          items: items,
          created_at: now,
          updated_at: now
        }
      end)

    tracker = %Tracker{
      task_id: event.task_id,
      phases: phases,
      created_at: now,
      updated_at: now
    }

    %{state | tracker: tracker}
  end

  def apply(state, %TrackerPhaseAdded{} = event) do
    now = System.system_time(:second)

    new_phase = %TrackerPhase{
      phase_id: event.phase_id,
      name: event.name,
      summary: Map.get(event, :summary),
      description: Map.get(event, :description),
      eta: parse_eta(event.eta),
      order: event.order,
      items: [],
      created_at: now,
      updated_at: now
    }

    tracker = state.tracker || Tracker.new(event.task_id)
    updated_phases = tracker.phases ++ [new_phase]
    updated_tracker = %{tracker | phases: updated_phases, updated_at: now}

    %{state | tracker: updated_tracker}
  end

  def apply(state, %TrackerItemAdded{} = event) do
    now = System.system_time(:second)

    new_item = %TrackerItem{
      item_id: event.item_id,
      phase_id: event.phase_id,
      summary: event.summary,
      workstream_id: event.workstream_id,
      status: :todo,
      comments: [],
      created_at: now,
      updated_at: now
    }

    tracker = state.tracker || Tracker.new(event.task_id)

    updated_phases =
      Enum.map(tracker.phases, fn phase ->
        if phase.phase_id == event.phase_id do
          %{phase | items: phase.items ++ [new_item], updated_at: now}
        else
          phase
        end
      end)

    updated_tracker = %{tracker | phases: updated_phases, updated_at: now}
    %{state | tracker: updated_tracker}
  end

  def apply(state, %TrackerItemUpdated{} = event) do
    now = System.system_time(:second)
    tracker = state.tracker || Tracker.new(event.task_id)

    updated_phases =
      Enum.map(tracker.phases, fn phase ->
        updated_items =
          Enum.map(phase.items, fn item ->
            if item.item_id == event.item_id do
              apply_changes(item, event.changes, now)
            else
              item
            end
          end)

        if updated_items != phase.items do
          %{phase | items: updated_items, updated_at: now}
        else
          phase
        end
      end)

    updated_tracker = %{tracker | phases: updated_phases, updated_at: now}
    %{state | tracker: updated_tracker}
  end

  def apply(state, %TrackerItemRemoved{} = event) do
    now = System.system_time(:second)
    tracker = state.tracker || Tracker.new(event.task_id)

    updated_phases =
      Enum.map(tracker.phases, fn phase ->
        if phase.phase_id == event.phase_id do
          updated_items = Enum.reject(phase.items, &(&1.item_id == event.item_id))
          %{phase | items: updated_items, updated_at: now}
        else
          phase
        end
      end)

    updated_tracker = %{tracker | phases: updated_phases, updated_at: now}
    %{state | tracker: updated_tracker}
  end

  def apply(state, %TrackerItemStatusChanged{} = event) do
    now = System.system_time(:second)
    tracker = state.tracker || Tracker.new(event.task_id)

    updated_phases =
      Enum.map(tracker.phases, fn phase ->
        updated_items =
          Enum.map(phase.items, fn item ->
            if item.item_id == event.item_id do
              %{item | status: event.to_status, updated_at: now}
            else
              item
            end
          end)

        if updated_items != phase.items do
          %{phase | items: updated_items, updated_at: now}
        else
          phase
        end
      end)

    updated_tracker = %{tracker | phases: updated_phases, updated_at: now}
    %{state | tracker: updated_tracker}
  end

  def apply(state, %TrackerItemCommentAdded{} = event) do
    now = System.system_time(:second)
    tracker = state.tracker || Tracker.new(event.task_id)

    comment = %{
      comment_id: event.comment_id,
      content: event.content,
      author: event.author,
      created_at: now
    }

    updated_phases =
      Enum.map(tracker.phases, fn phase ->
        updated_items =
          Enum.map(phase.items, fn item ->
            if item.item_id == event.item_id do
              %{item | comments: item.comments ++ [comment], updated_at: now}
            else
              item
            end
          end)

        if updated_items != phase.items do
          %{phase | items: updated_items, updated_at: now}
        else
          phase
        end
      end)

    updated_tracker = %{tracker | phases: updated_phases, updated_at: now}
    %{state | tracker: updated_tracker}
  end

  def apply(state, %TrackerPhaseEtaUpdated{} = event) do
    now = System.system_time(:second)
    tracker = state.tracker || Tracker.new(event.task_id)

    updated_phases =
      Enum.map(tracker.phases, fn phase ->
        if phase.phase_id == event.phase_id do
          %{phase | eta: parse_eta(event.eta), updated_at: now}
        else
          phase
        end
      end)

    updated_tracker = %{tracker | phases: updated_phases, updated_at: now}
    %{state | tracker: updated_tracker}
  end

  # Helper to access struct or map fields
  defp get_field(nil, _key), do: nil
  defp get_field(struct, key) when is_struct(struct), do: Map.get(struct, key)
  defp get_field(map, key) when is_map(map), do: map[key] || map[to_string(key)]
  defp get_field(_, _), do: nil

  # Apply changes map to an item
  defp apply_changes(item, changes, now) when is_map(changes) do
    item
    |> maybe_update(:summary, get_field(changes, :summary))
    |> maybe_update(:workstream_id, get_field(changes, :workstream_id))
    |> maybe_update(:status, normalize_status(get_field(changes, :status)))
    |> Map.put(:updated_at, now)
  end

  defp maybe_update(item, _key, nil), do: item
  defp maybe_update(item, key, value), do: Map.put(item, key, value)

  # Parse ETA string to Date
  defp parse_eta(nil), do: nil
  defp parse_eta(%Date{} = date), do: date

  defp parse_eta(eta_string) when is_binary(eta_string) do
    case Date.from_iso8601(eta_string) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_eta(_), do: nil

  # Normalize status to atom
  defp normalize_status(nil), do: nil
  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status("todo"), do: :todo
  defp normalize_status("wip"), do: :wip
  defp normalize_status("done"), do: :done
  defp normalize_status("blocked"), do: :blocked
  defp normalize_status(_), do: :todo
end
