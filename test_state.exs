task_id = "task-27a3d489-6dad-41f9-9f97-f05fcd77d616"

case Ipa.Pod.State.get_state_from_events(task_id) do
  {:ok, state} ->
    IO.puts("Phase: #{state.phase}")
    IO.puts("Plan exists: #{state.plan != nil}")

    if state.plan != nil do
      IO.puts("Plan approved: #{state.plan[:approved?]}")
      workstreams = state.plan[:workstreams] || []
      IO.puts("Plan workstream count: #{length(workstreams)}")
    end

    IO.puts("State workstreams count: #{map_size(state.workstreams)}")
    IO.puts("Version: #{state.version}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
