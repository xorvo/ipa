defmodule Ipa.Pod.Manager do
  @moduledoc """
  Pod Manager - orchestrates event-sourced state management.

  This is a thin GenServer that orchestrates:
  - State management (via Projector)
  - Command execution
  - Event persistence
  - Scheduler evaluation
  - PubSub broadcasting

  ## Usage

      # Start a pod
      {:ok, pid} = Manager.start_link(task_id: "task-123")

      # Get current state
      {:ok, state} = Manager.get_state("task-123")

      # Execute a command
      {:ok, version} = Manager.execute("task-123", TaskCommands, :approve_spec, ["user-1", nil])

  ## PubSub

  Subscribe to `"pod:{task_id}"` for state updates:
  - `{:state_updated, task_id, state}` - Any state change
  """

  use GenServer
  require Logger

  alias Ipa.EventStore
  alias Ipa.Pod.State
  alias Ipa.Pod.State.Projector
  alias Ipa.Pod.Machine.Evaluator
  alias Ipa.Pod.WorkspaceManager

  alias Ipa.Pod.Commands.{
    PhaseCommands,
    WorkstreamCommands,
    AgentCommands
  }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc "Starts the Pod Manager for a task."
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(task_id))
  end

  @doc "Gets the current state of the pod."
  @spec get_state(String.t()) :: {:ok, State.t()} | {:error, :not_found}
  def get_state(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, :get_state)}
    end
  end

  @doc """
  Gets state by replaying events (for when pod is not running).
  """
  @spec get_state_from_events(String.t()) :: {:ok, State.t()} | {:error, :not_found}
  def get_state_from_events(task_id) do
    # read_stream always succeeds or raises on DB error
    {:ok, events} = EventStore.read_stream(task_id)

    case events do
      [] -> {:error, :not_found}
      events -> {:ok, Projector.replay(events, State.new(task_id))}
    end
  end

  @doc """
  Executes a command and persists resulting events.

  ## Examples

      # Approve spec
      Manager.execute(task_id, TaskCommands, :approve_spec, ["user-1", nil])

      # Create workstream
      Manager.execute(task_id, WorkstreamCommands, :create_workstream, [%{title: "Setup"}])
  """
  @spec execute(String.t(), module(), atom(), list()) ::
          {:ok, integer()} | {:error, term()}
  def execute(task_id, command_module, command_fn, args \\ []) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:execute, command_module, command_fn, args})
    end
  end

  @doc "Subscribes to pod state updates."
  @spec subscribe(String.t()) :: :ok
  def subscribe(task_id) do
    Phoenix.PubSub.subscribe(Ipa.PubSub, "pod:#{task_id}")
  end

  @doc "Manually triggers scheduler evaluation."
  @spec evaluate(String.t()) :: :ok
  def evaluate(task_id) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> :ok
      pid -> send(pid, :evaluate)
    end

    :ok
  end

  @doc "Notifies the manager of an agent completion."
  @spec notify_agent_completed(String.t(), String.t(), map()) :: :ok
  def notify_agent_completed(task_id, agent_id, result) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:agent_completed, agent_id, result})
    end
  end

  @doc "Notifies the manager of an agent failure."
  @spec notify_agent_failed(String.t(), String.t(), String.t()) :: :ok
  def notify_agent_failed(task_id, agent_id, error) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:agent_failed, agent_id, error})
    end
  end

  @doc """
  Manually starts a pending agent (when auto_start_agents is disabled).
  """
  @spec manually_start_agent(String.t(), String.t(), String.t() | nil) ::
          {:ok, integer()} | {:error, term()}
  def manually_start_agent(task_id, agent_id, started_by \\ nil) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:manually_start_agent, agent_id, started_by})
    end
  end

  @doc """
  Sends a message to an interactive agent.
  """
  @spec send_agent_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_agent_message(task_id, agent_id, message, opts \\ %{}) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:send_agent_message, agent_id, message, opts})
    end
  end

  @doc """
  Marks an agent's work as done/approved.
  """
  @spec mark_agent_done(String.t(), String.t(), map()) :: {:ok, integer()} | {:error, term()}
  def mark_agent_done(task_id, agent_id, opts \\ %{}) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:mark_agent_done, agent_id, opts})
    end
  end

  @doc """
  Restarts a failed or interrupted agent.

  Creates a new pending agent with the same context (workstream, workspace, etc.)
  but a new agent_id. Returns {:ok, new_agent_id, version} on success.
  """
  @spec restart_agent(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), integer()} | {:error, term()}
  def restart_agent(task_id, agent_id, restarted_by \\ nil) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:restart_agent, agent_id, restarted_by})
    end
  end

  @doc """
  Marks an agent as failed. Used when the agent process died without proper cleanup.
  """
  @spec fail_agent(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, integer()} | {:error, term()}
  def fail_agent(task_id, agent_id, error, actor_id \\ nil) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:fail_agent, agent_id, error, actor_id})
    end
  end

  @doc """
  Spawns a spec generator agent.

  This creates the workspace, starts the agent, and records the appropriate events
  so the agent appears in the Agents tab with live progress.

  ## Parameters
    - `task_id` - Task UUID
    - `input_content` - User's initial requirements to transform into a spec

  ## Returns
    - `{:ok, agent_id}` - Agent started successfully
    - `{:error, reason}` - Failed to start agent
  """
  @spec spawn_spec_generator(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_spec_generator(task_id, input_content) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:spawn_spec_generator, input_content})
    end
  end

  @doc """
  Spawns a planning agent.

  This creates the workspace, starts the agent, and records the appropriate events
  so the agent appears in the Agents tab with live progress.

  Supports both initial plan creation and iterative refinement:
  - First run: creates plan from spec
  - Subsequent runs: refines plan based on user feedback

  ## Parameters
    - `task_id` - Task UUID
    - `input_content` - User's planning requirements or refinement feedback

  ## Returns
    - `{:ok, agent_id}` - Agent started successfully
    - `{:error, reason}` - Failed to start agent
  """
  @spec spawn_planning_agent(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_planning_agent(task_id, input_content) do
    case GenServer.whereis(via_tuple(task_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:spawn_planning_agent, input_content})
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    Logger.info("Pod.Manager starting for task #{task_id}")

    # Subscribe to EventStore broadcasts so we see events appended by other processes (e.g., LiveView)
    EventStore.subscribe(task_id)

    state = recover_state(task_id)

    # Eagerly create base workspace on pod startup
    # Sub-workspaces (planning, workstream) are created lazily when agents need them
    ensure_base_workspace(task_id)

    schedule_evaluation(state.config.evaluation_interval)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:execute, command_module, command_fn, args}, _from, state) do
    # Execute command to get events
    case apply(command_module, command_fn, [state | args]) do
      {:ok, events} ->
        # Persist and apply events
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)
            maybe_trigger_evaluation(events)
            {:reply, {:ok, new_state.version}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:manually_start_agent, agent_id, started_by}, _from, state) do
    # First, record the manual start event
    case AgentCommands.manually_start_agent(state, agent_id, started_by) do
      {:ok, events} ->
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)

            # Now actually spawn the agent process
            agent = Enum.find(new_state.agents, fn a -> a.agent_id == agent_id end)

            if agent do
              spawn_pending_agent(new_state, agent)
            end

            {:reply, {:ok, new_state.version}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:send_agent_message, agent_id, message, opts}, _from, state) do
    case AgentCommands.send_message_to_agent(state, agent_id, message, opts) do
      {:ok, events} ->
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)
            # TODO: In Phase 2, this will also send the message to the running agent session
            {:reply, {:ok, new_state.version}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:mark_agent_done, agent_id, opts}, _from, state) do
    case AgentCommands.mark_agent_done(state, agent_id, opts) do
      {:ok, events} ->
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)

            # Also complete the workstream if this agent belongs to one
            # This ensures manual "mark done" has the same effect as natural completion
            workstream_id = find_workstream_for_agent(new_state, agent_id)

            final_state =
              if workstream_id do
                case WorkstreamCommands.complete_workstream(new_state, workstream_id, %{}) do
                  {:ok, ws_events} ->
                    case persist_and_apply_events(new_state, ws_events) do
                      {:ok, updated_state} ->
                        broadcast_state_update(updated_state)
                        updated_state

                      _ ->
                        new_state
                    end

                  _ ->
                    new_state
                end
              else
                new_state
              end

            send(self(), :evaluate)
            {:reply, {:ok, final_state.version}, final_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:restart_agent, agent_id, restarted_by}, _from, state) do
    case AgentCommands.restart_agent(state, agent_id, restarted_by) do
      {:ok, events} ->
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)

            # Extract the new agent_id from the event
            [pending_event | _] = events
            new_agent_id = pending_event.agent_id

            {:reply, {:ok, new_agent_id, new_state.version}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fail_agent, agent_id, error, _actor_id}, _from, state) do
    case AgentCommands.fail_agent(state, agent_id, error) do
      {:ok, events} ->
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)
            {:reply, {:ok, new_state.version}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:spawn_spec_generator, input_content}, _from, state) do
    # Check if spec is already approved
    if State.spec_approved?(state) do
      {:reply, {:error, :spec_already_approved}, state}
    else
      # Check if we're in the right phase
      if state.phase != :spec_clarification do
        {:reply, {:error, :invalid_phase}, state}
      else
        # Check if there's already a spec generator running
        has_running_spec_gen =
          Enum.any?(state.agents, fn a ->
            a.agent_type == :spec_generator and a.status == :running
          end)

        if has_running_spec_gen do
          {:reply, {:error, :generation_in_progress}, state}
        else
          case spawn_spec_generator_impl(state, input_content) do
            {:ok, agent_id, new_state} ->
              {:reply, {:ok, agent_id}, new_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end
      end
    end
  end

  def handle_call({:spawn_planning_agent, input_content}, _from, state) do
    # Check if plan is already approved
    if State.plan_approved?(state) do
      {:reply, {:error, :plan_already_approved}, state}
    else
      # Check if we're in the right phase
      if state.phase != :planning do
        {:reply, {:error, :invalid_phase}, state}
      else
        # Check if there's already a planning agent running
        has_running_planning =
          Enum.any?(state.agents, fn a ->
            a.agent_type in [:planning, :planning_agent] and a.status == :running
          end)

        if has_running_planning do
          {:reply, {:error, :generation_in_progress}, state}
        else
          case spawn_planning_agent_impl(state, input_content) do
            {:ok, agent_id, new_state} ->
              {:reply, {:ok, agent_id}, new_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end
      end
    end
  end

  @impl true
  def handle_cast({:agent_completed, agent_id, result}, state) do
    Logger.info("Agent #{agent_id} completed", task_id: state.task_id)

    # Find workstream for this agent
    workstream_id = find_workstream_for_agent(state, agent_id)

    new_state =
      if workstream_id do
        # Complete the workstream
        case WorkstreamCommands.complete_workstream(state, workstream_id, result) do
          {:ok, events} ->
            case persist_and_apply_events(state, events) do
              {:ok, updated_state} ->
                broadcast_state_update(updated_state)
                send(self(), :evaluate)
                updated_state

              _ ->
                state
            end

          _ ->
            state
        end
      else
        state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:agent_failed, agent_id, error}, state) do
    Logger.error("Agent #{agent_id} failed: #{error}", task_id: state.task_id)

    workstream_id = find_workstream_for_agent(state, agent_id)

    new_state =
      if workstream_id do
        case WorkstreamCommands.fail_workstream(state, workstream_id, error, false) do
          {:ok, events} ->
            case persist_and_apply_events(state, events) do
              {:ok, updated_state} ->
                broadcast_state_update(updated_state)
                updated_state

              _ ->
                state
            end

          _ ->
            state
        end
      else
        state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:evaluate, state) do
    new_state = run_evaluation(state)
    schedule_evaluation(state.config.evaluation_interval)
    {:noreply, new_state}
  end

  # Handle events appended by other processes (e.g., LiveView approvals)
  # This keeps our in-memory state in sync with EventStore
  @impl true
  def handle_info({:event_appended, stream_id, event}, state) when stream_id == state.task_id do
    Logger.debug("Manager received external event: #{event.event_type} (v#{event.version})",
      task_id: state.task_id
    )

    # Only apply if this event is newer than our current state
    if event.version > state.version do
      # Apply the event using the projector
      new_state = apply_external_event(state, event)
      broadcast_state_update(new_state)

      # Trigger evaluation for significant events
      if should_evaluate_after?(event.event_type) do
        send(self(), :evaluate)
      end

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("Pod.Manager terminating for task #{state.task_id}: #{inspect(reason)}")
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:manager, task_id}}}
  end

  defp recover_state(task_id) do
    case EventStore.read_stream(task_id) do
      {:ok, events} when events != [] ->
        Logger.info("Recovering state from #{length(events)} events")
        Projector.replay(events, State.new(task_id))

      _ ->
        Logger.info("No events found, starting fresh")
        State.new(task_id)
    end
  end

  defp persist_and_apply_events(state, []), do: {:ok, state}

  defp persist_and_apply_events(state, events) do
    # Build batch for EventStore
    event_batch =
      Enum.map(events, fn event ->
        %{
          event_type: event.__struct__.event_type(),
          data: event.__struct__.to_map(event),
          opts: []
        }
      end)

    case EventStore.append_batch(state.task_id, event_batch) do
      {:ok, new_version} ->
        # Apply events to state using the projector
        new_state =
          Enum.reduce(events, state, fn event, acc ->
            Projector.apply(acc, event)
          end)

        {:ok, %{new_state | version: new_version}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_evaluation(state) do
    actions = Evaluator.evaluate(state)

    Enum.reduce(actions, state, fn action, acc ->
      execute_action(acc, action)
    end)
  end

  defp execute_action(state, {:request_transition, to_phase, reason}) do
    case PhaseCommands.request_transition(state, to_phase, reason, "scheduler") do
      {:ok, events} ->
        case persist_and_apply_events(state, events) do
          {:ok, new_state} ->
            broadcast_state_update(new_state)
            new_state

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp execute_action(state, {:start_workstream, workstream_id}) do
    ws = State.get_workstream(state, workstream_id)

    if ws do
      # Build complete workstream context for the agent
      # Convert struct to map and include all relevant data
      workstream_map = %{
        workstream_id: ws.workstream_id,
        title: ws.title,
        spec: ws.spec,
        dependencies: ws.dependencies
      }

      # Include task context as well
      task_map = %{
        task_id: state.task_id,
        title: state.title,
        spec: state.spec
      }

      context = %{
        task_id: state.task_id,
        workstream_id: workstream_id,
        workstream: workstream_map,
        task: task_map
      }

      # Try to start the agent
      case start_agent_for_workstream(state, context) do
        {:ok, agent_id, new_state} ->
          # Mark workstream as started
          case WorkstreamCommands.start_workstream(new_state, workstream_id, agent_id) do
            {:ok, events} ->
              case persist_and_apply_events(new_state, events) do
                {:ok, updated_state} ->
                  broadcast_state_update(updated_state)
                  updated_state

                _ ->
                  new_state
              end

            _ ->
              new_state
          end

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  defp execute_action(state, {:spawn_agent, :planning, context}) do
    # Create workspace for planning agent
    workspace_path = create_planning_workspace(state.task_id)

    # Build proper context for the planning agent
    agent_context = %{
      task_id: state.task_id,
      workspace: workspace_path,
      task: %{
        task_id: state.task_id,
        title: context[:title] || state.title,
        spec: context[:spec] || state.spec
      }
    }

    Logger.debug("Preparing planning agent",
      task_id: state.task_id,
      workspace: workspace_path,
      title: agent_context.task.title,
      auto_start: state.config.auto_start_agents
    )

    # Check if auto_start is enabled
    if state.config.auto_start_agents do
      # Auto-start: spawn immediately (original behavior)
      spawn_agent_immediately(
        state,
        :planning,
        Ipa.Agent.Types.Planning,
        agent_context,
        workspace_path
      )
    else
      # Manual start: create pending agent, wait for user to start
      agent_id = Ecto.UUID.generate()
      prompt = Ipa.Agent.Types.Planning.generate_prompt(agent_context)

      case AgentCommands.prepare_agent(state, %{
             agent_id: agent_id,
             agent_type: :planning_agent,
             workspace_path: workspace_path,
             prompt: prompt,
             interactive: true
           }) do
        {:ok, events} ->
          case persist_and_apply_events(state, events) do
            {:ok, new_state} ->
              broadcast_state_update(new_state)
              new_state

            _ ->
              state
          end

        _ ->
          state
      end
    end
  end

  defp execute_action(state, {:create_workstreams_from_plan, plan_workstreams}) do
    Logger.info("Creating workstreams from plan",
      task_id: state.task_id,
      count: length(plan_workstreams)
    )

    # Create WorkstreamCreated events for each workstream in the plan
    Enum.reduce(plan_workstreams, state, fn ws_data, acc_state ->
      workstream_id = ws_data["id"] || ws_data[:id] || Ecto.UUID.generate()

      params = %{
        workstream_id: workstream_id,
        title: ws_data["title"] || ws_data[:title],
        spec: ws_data["description"] || ws_data[:description],
        dependencies: ws_data["dependencies"] || ws_data[:dependencies] || [],
        priority: :normal
      }

      case WorkstreamCommands.create_workstream(acc_state, params) do
        {:ok, events} ->
          case persist_and_apply_events(acc_state, events) do
            {:ok, new_state} ->
              broadcast_state_update(new_state)
              new_state

            _ ->
              acc_state
          end

        {:error, reason} ->
          Logger.warning("Failed to create workstream #{workstream_id}: #{inspect(reason)}")
          acc_state
      end
    end)
  end

  defp execute_action(state, :noop), do: state

  # Helper to spawn agent immediately (when auto_start is true)
  defp spawn_agent_immediately(state, agent_type, agent_module, context, workspace_path) do
    case Ipa.Agent.Supervisor.start_agent(state.task_id, agent_module, context) do
      {:ok, agent_id} ->
        case AgentCommands.start_agent(state, %{
               agent_id: agent_id,
               agent_type: agent_type,
               workspace_path: workspace_path
             }) do
          {:ok, events} ->
            case persist_and_apply_events(state, events) do
              {:ok, new_state} ->
                broadcast_state_update(new_state)
                new_state

              _ ->
                state
            end

          _ ->
            state
        end

      {:error, reason} ->
        Logger.error("Failed to start #{agent_type} agent: #{inspect(reason)}")
        state
    end
  end

  # Implementation for spawning spec generator agent
  defp spawn_spec_generator_impl(state, input_content) do
    # Create workspace for the spec generator
    workspace_path = create_spec_generator_workspace(state.task_id)

    # Get unresolved review threads for the spec
    review_threads = get_unresolved_threads(state, :spec)

    # Build context for the spec generator agent
    agent_context = %{
      task_id: state.task_id,
      workspace: workspace_path,
      user_input: input_content,
      current_spec: get_in(state.spec, [:content]),
      review_threads: review_threads,
      task: %{
        task_id: state.task_id,
        title: state.title,
        spec: state.spec
      }
    }

    Logger.info("Spawning spec generator agent",
      task_id: state.task_id,
      workspace: workspace_path
    )

    # Start the agent process
    case Ipa.Agent.Supervisor.start_agent(state.task_id, Ipa.Agent.Types.SpecGenerator, agent_context) do
      {:ok, agent_id} ->
        # Record the agent_started event with document context
        case AgentCommands.start_agent(state, %{
               agent_id: agent_id,
               agent_type: :spec_generator,
               workspace_path: workspace_path,
               context: %{document_type: :spec}
             }) do
          {:ok, events} ->
            case persist_and_apply_events(state, events) do
              {:ok, new_state} ->
                broadcast_state_update(new_state)
                {:ok, agent_id, new_state}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to start spec generator agent: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Create workspace for spec generator
  defp create_spec_generator_workspace(task_id) do
    ensure_base_workspace(task_id)

    workspace_name = WorkspaceManager.generate_workspace_name("spec-generator", task_id)

    case WorkspaceManager.create_sub_workspace(task_id, workspace_name, %{purpose: :spec_generator}) do
      {:ok, path} ->
        # Create output directory for the spec
        output_dir = Path.join(path, "output")
        File.mkdir_p!(output_dir)
        Logger.debug("Created spec generator workspace", path: path)
        path

      {:error, :already_exists} ->
        {:ok, path} = WorkspaceManager.get_sub_workspace_path(task_id, workspace_name)
        path

      {:error, reason} ->
        Logger.error("Failed to create spec generator workspace: #{inspect(reason)}")
        # Fall back to temporary directory
        temp_path = Path.join([System.tmp_dir!(), "ipa", "spec-generator", task_id])
        File.mkdir_p!(temp_path)
        temp_path
    end
  end

  # Implementation for spawning planning agent
  defp spawn_planning_agent_impl(state, input_content) do
    # Create workspace for the planning agent
    workspace_path = create_planning_workspace(state.task_id)

    # Get unresolved review threads for the plan
    review_threads = get_unresolved_threads(state, :plan)

    # Get current plan data for iteration
    current_plan = state.plan

    # Build context for the planning agent
    agent_context = %{
      task_id: state.task_id,
      workspace: workspace_path,
      user_input: input_content,
      current_plan: current_plan,
      review_threads: review_threads,
      task: %{
        task_id: state.task_id,
        title: state.title,
        spec: state.spec
      }
    }

    Logger.info("Spawning planning agent",
      task_id: state.task_id,
      workspace: workspace_path,
      has_current_plan: current_plan != nil
    )

    # Start the agent process
    case Ipa.Agent.Supervisor.start_agent(state.task_id, Ipa.Agent.Types.Planning, agent_context) do
      {:ok, agent_id} ->
        # Record the agent_started event with document context
        case AgentCommands.start_agent(state, %{
               agent_id: agent_id,
               agent_type: :planning_agent,
               workspace_path: workspace_path,
               context: %{document_type: :plan}
             }) do
          {:ok, events} ->
            case persist_and_apply_events(state, events) do
              {:ok, new_state} ->
                broadcast_state_update(new_state)
                {:ok, agent_id, new_state}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to start planning agent: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Helper to spawn a pending agent when manually started
  defp spawn_pending_agent(state, agent) do
    # Build context based on agent type
    context = build_agent_context(state, agent)

    # Determine the agent module
    agent_module =
      case agent.agent_type do
        :planning -> Ipa.Agent.Types.Planning
        :planning_agent -> Ipa.Agent.Types.Planning
        :workstream -> Ipa.Agent.Types.Workstream
        :review -> Ipa.Agent.Types.Review
        :spec_generator -> Ipa.Agent.Types.SpecGenerator
        _ -> Ipa.Agent.Types.Workstream
      end

    Logger.info("Spawning manually started agent",
      agent_id: agent.agent_id,
      agent_type: agent.agent_type,
      workspace: agent.workspace_path
    )

    # Start the actual agent process
    case Ipa.Agent.Supervisor.start_agent(
           state.task_id,
           agent_module,
           Map.put(context, :agent_id, agent.agent_id)
         ) do
      {:ok, _pid} ->
        Logger.info("Successfully spawned agent #{agent.agent_id}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to spawn agent #{agent.agent_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_agent_context(state, agent) do
    base_context = %{
      task_id: state.task_id,
      workspace: agent.workspace_path,
      task: %{
        task_id: state.task_id,
        title: state.title,
        spec: state.spec
      }
    }

    # Add workstream context if applicable
    if agent.workstream_id do
      workstream = Map.get(state.workstreams, agent.workstream_id)

      Map.merge(base_context, %{
        workstream_id: agent.workstream_id,
        workstream: workstream
      })
    else
      base_context
    end
  end

  defp create_planning_workspace(task_id) do
    # Ensure base workspace exists
    ensure_base_workspace(task_id)

    # Generate workspace name for planning
    workspace_name = WorkspaceManager.generate_workspace_name("planning", task_id)

    case WorkspaceManager.create_sub_workspace(task_id, workspace_name, %{purpose: :planning}) do
      {:ok, path} ->
        Logger.debug("Created planning workspace", path: path)
        path

      {:error, :already_exists} ->
        # Workspace already exists, get the path
        {:ok, path} = WorkspaceManager.get_sub_workspace_path(task_id, workspace_name)
        path

      {:error, reason} ->
        raise "Failed to create planning workspace: #{inspect(reason)}"
    end
  end

  defp ensure_base_workspace(task_id) do
    case WorkspaceManager.ensure_base_workspace(task_id, %{}) do
      {:ok, _path} -> :ok
      {:error, reason} -> raise "Failed to create base workspace: #{inspect(reason)}"
    end
  end

  defp start_agent_for_workstream(state, context) do
    # Create workspace for the workstream agent
    workspace_path = create_workstream_workspace(state.task_id, context.workstream_id)

    # Add workspace to context for the agent
    context_with_workspace = Map.put(context, :workspace, workspace_path)

    case Ipa.Agent.Supervisor.start_agent(
           state.task_id,
           Ipa.Agent.Types.Workstream,
           context_with_workspace
         ) do
      {:ok, agent_id} ->
        case AgentCommands.start_agent(state, %{
               agent_id: agent_id,
               agent_type: :workstream,
               workstream_id: context.workstream_id,
               workspace_path: workspace_path
             }) do
          {:ok, events} ->
            case persist_and_apply_events(state, events) do
              {:ok, new_state} -> {:ok, agent_id, new_state}
              error -> error
            end

          error ->
            error
        end

      error ->
        error
    end
  end

  defp create_workstream_workspace(task_id, workstream_id) do
    # Ensure base workspace exists
    ensure_base_workspace(task_id)

    # Generate workspace name for workstream using workstream_id
    workspace_name = WorkspaceManager.generate_workspace_name(nil, workstream_id)

    case WorkspaceManager.create_sub_workspace(task_id, workspace_name, %{
           workstream_id: workstream_id,
           purpose: :workstream
         }) do
      {:ok, path} ->
        Logger.debug("Created workstream workspace",
          path: path,
          workstream_id: workstream_id
        )

        path

      {:error, :already_exists} ->
        # Workspace already exists, get the path
        {:ok, path} = WorkspaceManager.get_sub_workspace_path(task_id, workspace_name)
        path

      {:error, reason} ->
        raise "Failed to create workstream workspace: #{inspect(reason)}"
    end
  end

  defp find_workstream_for_agent(state, agent_id) do
    case Enum.find(state.agents, fn a -> a.agent_id == agent_id end) do
      nil -> nil
      agent -> agent.workstream_id
    end
  end

  defp schedule_evaluation(interval) do
    Process.send_after(self(), :evaluate, interval)
  end

  defp broadcast_state_update(state) do
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      "pod:#{state.task_id}",
      {:state_updated, state.task_id, state}
    )
  end

  defp maybe_trigger_evaluation(events) do
    trigger_types = [
      Ipa.Pod.Events.SpecApproved,
      Ipa.Pod.Events.PlanApproved,
      Ipa.Pod.Events.TransitionApproved,
      Ipa.Pod.Events.WorkstreamCompleted,
      Ipa.Pod.Events.WorkstreamFailed,
      Ipa.Pod.Events.AgentCompleted,
      Ipa.Pod.Events.AgentFailed
    ]

    if Enum.any?(events, fn e -> e.__struct__ in trigger_types end) do
      send(self(), :evaluate)
    end
  end

  # Apply an external event (from EventStore broadcast) to state
  defp apply_external_event(state, event) do
    # Projector.apply handles raw events directly - it converts event_type + data to typed struct
    Projector.apply(state, event)
    # Note: Projector.apply already updates version and updated_at from the raw event
  end

  # Events that should trigger an evaluation after being applied
  defp should_evaluate_after?(event_type) do
    event_type in [
      "spec_approved",
      "plan_created",
      "plan_updated",
      "plan_approved",
      "transition_approved",
      "workstream_completed",
      "workstream_failed",
      "agent_completed",
      "agent_failed"
    ]
  end

  # Get unresolved review threads for a document type
  # Returns a list of thread maps suitable for the agent's context
  defp get_unresolved_threads(state, document_type) do
    threads = State.get_review_threads(state, document_type)

    threads
    |> Enum.filter(fn {_thread_id, messages} ->
      # Check if the thread is NOT resolved
      first_msg = List.first(messages)

      resolved? =
        !!(first_msg && first_msg.metadata &&
             (first_msg.metadata[:resolved?] || first_msg.metadata["resolved?"]))

      not resolved?
    end)
    |> Enum.map(fn {thread_id, messages} ->
      first_msg = List.first(messages)
      is_question = first_msg && first_msg.metadata && first_msg.metadata[:is_question]

      %{
        thread_id: thread_id,
        is_question: is_question || false,
        messages:
          Enum.map(messages, fn msg ->
            %{
              author: msg.author,
              content: msg.content,
              posted_at: msg.posted_at
            }
          end)
      }
    end)
  end
end
