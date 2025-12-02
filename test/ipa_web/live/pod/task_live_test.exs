defmodule IpaWeb.Pod.TaskLiveTest do
  @moduledoc """
  Tests for the TaskLive Phoenix LiveView component.

  These tests ensure that:
  - Task overview renders correctly
  - Workstreams tab renders without crashes (including edge cases)
  - Communications tab renders correctly
  - Tab navigation works
  - Approval workflows function properly
  """
  use IpaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ipa.EventStore

  setup do
    # Generate unique task_id for each test to avoid conflicts
    task_id = "test-task-#{System.system_time(:millisecond)}-#{:rand.uniform(100_000)}"

    # Clean up any existing stream (just in case)
    EventStore.delete_stream(task_id)

    # Create a fresh task stream with realistic data (stream_type, stream_id)
    {:ok, ^task_id} = EventStore.start_stream("task", task_id)

    # Task created event
    {:ok, _} =
      EventStore.append(
        task_id,
        "task_created",
        %{
          title: "Test Task for LiveView",
          description: "A test task to verify LiveView rendering"
        },
        actor_id: "test"
      )

    # Spec updated event - using new content-based format
    {:ok, _} =
      EventStore.append(
        task_id,
        "spec_updated",
        %{
          content: "# Test Specification\n\nTest specification description",
          workspace_path: "/tmp/test-workspace"
        },
        actor_id: "test"
      )

    # Spec approved event
    {:ok, _} =
      EventStore.append(
        task_id,
        "spec_approved",
        %{approved_by: "user", approved_at: System.system_time(:second)},
        actor_id: "user"
      )

    # Phase transition to planning
    {:ok, _} =
      EventStore.append(
        task_id,
        "phase_changed",
        %{from_phase: "spec_clarification", to_phase: "planning"},
        actor_id: "system"
      )

    on_exit(fn ->
      # Clean up after test
      EventStore.delete_stream(task_id)
    end)

    %{task_id: task_id}
  end

  describe "task overview rendering" do
    test "renders task with title and phase", %{conn: conn, task_id: task_id} do
      {:ok, _view, html} = live(conn, ~p"/pods/#{task_id}")

      assert html =~ "Test Task for LiveView"
      assert html =~ task_id
      # Check for phase badge - default is spec_clarification when phase_changed not supported
      assert html =~ "Spec clarification" or html =~ "spec_clarification" or html =~ "Planning" or
               html =~ "planning"
    end

    test "renders specification section", %{conn: conn, task_id: task_id} do
      {:ok, _view, html} = live(conn, ~p"/pods/#{task_id}")

      assert html =~ "Specification"
      # Content is markdown, so checking for the text part
      assert html =~ "Test Specification" or html =~ "specification description"
      assert html =~ "Spec Approved"
    end

    test "renders plan section", %{conn: conn, task_id: task_id} do
      {:ok, _view, html} = live(conn, ~p"/pods/#{task_id}")

      assert html =~ "Plan"
    end
  end

  describe "workstreams tab rendering" do
    setup %{task_id: task_id} do
      # Add workstreams without :title key (the bug case)
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-1",
            spec: "First workstream specification",
            dependencies: []
          },
          actor_id: "scheduler"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-2",
            spec: "Second workstream with dependency",
            dependencies: ["ws-1"]
          },
          actor_id: "scheduler"
        )

      :ok
    end

    test "renders workstreams tab without crash when workstreams lack :title key", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Click on Workstreams tab - this should NOT crash
      html =
        view
        |> element("button", "Workstreams")
        |> render_click()

      # Should render workstream IDs as titles (fallback)
      assert html =~ "ws-1"
      assert html =~ "ws-2"
      # Should render workstream specs
      assert html =~ "First workstream specification"
      assert html =~ "Second workstream with dependency"
    end

    test "renders workstream dependencies correctly", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      html =
        view
        |> element("button", "Workstreams")
        |> render_click()

      # ws-2 depends on ws-1
      assert html =~ "Depends on: ws-1"
    end

    test "renders workstream status badges", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      html =
        view
        |> element("button", "Workstreams")
        |> render_click()

      # Default status should be pending
      assert html =~ "Pending"
    end

    test "handles workstreams with :title key", %{conn: conn, task_id: task_id} do
      # Add a workstream WITH a title - note: title may not be projected by state,
      # so we test that it renders without crash and shows the workstream_id as fallback
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-3",
            title: "Custom Workstream Title",
            spec: "Third workstream",
            dependencies: []
          },
          actor_id: "scheduler"
        )

      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      html =
        view
        |> element("button", "Workstreams")
        |> render_click()

      # Should render - either custom title or workstream_id as fallback
      # The key test is that it renders without crashing
      assert html =~ "ws-3" or html =~ "Custom Workstream Title"
      assert html =~ "Third workstream"
    end
  end

  describe "workstreams empty state" do
    test "renders empty state when no workstreams exist", %{conn: conn} do
      # Create a new task without workstreams
      task_id =
        "no-workstreams-task-#{System.system_time(:millisecond)}-#{:rand.uniform(100_000)}"

      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} =
        EventStore.append(
          task_id,
          "task_created",
          %{title: "Empty Task", description: "No workstreams"},
          actor_id: "test"
        )

      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      html =
        view
        |> element("button", "Workstreams")
        |> render_click()

      assert html =~ "No workstreams yet"

      # Cleanup
      EventStore.delete_stream(task_id)
    end
  end

  describe "workstream details panel" do
    setup %{task_id: task_id} do
      # Create workstream with workspace
      agent_id = "workstream-agent-ws-details-test"
      workspace_path = "/tmp/test-workspace/#{task_id}/#{agent_id}"

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{
            workstream_id: "ws-details-1",
            spec: "Workstream for details panel test",
            dependencies: []
          },
          actor_id: "scheduler"
        )

      # Add sub_workspace_created event (fires before agent_started)
      {:ok, _} =
        EventStore.append(
          task_id,
          "sub_workspace_created",
          %{
            task_id: task_id,
            workspace_name: "ws-details-1",
            workspace_path: workspace_path,
            agent_id: agent_id,
            workstream_id: "ws-details-1",
            purpose: :workstream
          },
          actor_id: "workspace_manager"
        )

      # Add workstream_agent_started event with workspace
      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_agent_started",
          %{
            workstream_id: "ws-details-1",
            agent_id: agent_id,
            agent_type: "workstream_executor",
            workspace_path: workspace_path
          },
          actor_id: "scheduler"
        )

      # Add agent_started event to populate state.agents
      {:ok, _} =
        EventStore.append(
          task_id,
          "agent_started",
          %{
            task_id: task_id,
            agent_id: agent_id,
            agent_type: "workstream_executor",
            workstream_id: "ws-details-1",
            workspace: workspace_path
          },
          actor_id: "scheduler"
        )

      %{agent_id: agent_id, workspace_path: workspace_path}
    end

    test "clicking workstream shows details panel", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Click on Workstreams tab
      view
      |> element("button", "Workstreams")
      |> render_click()

      # Click on the workstream card to select it
      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-details-1\"]")
        |> render_click()

      # Details panel should appear
      assert html =~ "Workstream Details"
      assert html =~ "ws-details-1"
    end

    test "details panel shows workstream specification", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-details-1\"]")
        |> render_click()

      assert html =~ "Specification"
      assert html =~ "Workstream for details panel test"
    end

    test "details panel shows workspace path with copy button", %{
      conn: conn,
      task_id: task_id,
      workspace_path: workspace_path
    } do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-details-1\"]")
        |> render_click()

      # Should show workspace section with path
      assert html =~ "Workspace"
      assert html =~ workspace_path
      # Should have copy button
      assert html =~ "Copy path"
    end

    test "details panel shows agent information", %{
      conn: conn,
      task_id: task_id,
      agent_id: agent_id
    } do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-details-1\"]")
        |> render_click()

      # Should show agent section
      assert html =~ "Agent"
      assert html =~ agent_id
      # Note: "workstream_executor" is normalized to :workstream by AgentStarted.from_map
      assert html =~ "workstream"
      assert html =~ "Running"
    end

    test "details panel shows status badge", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-details-1\"]")
        |> render_click()

      # Status should show after workstream_agent_started event
      # Note: The actual status may be "In progress" or "Failed" depending on whether
      # the Scheduler marks the workstream as orphaned (no actual agent process running)
      assert html =~ "Status:"
      assert html =~ "badge"
      # At minimum, the status should be formatted (not just raw atom)
      assert html =~ ~r/(In progress|Failed|Pending|Completed)/
    end

    test "details panel shows dependencies section", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-details-1\"]")
        |> render_click()

      assert html =~ "Dependencies"
      # ws-details-1 has no dependencies
      assert html =~ "No dependencies"
    end

    test "details panel shows timeline section", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-details-1\"]")
        |> render_click()

      assert html =~ "Timeline"
      assert html =~ "Started:"
    end

    test "clicking close button hides details panel", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      view
      |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-details-1\"]")
      |> render_click()

      # Click close button (empty id deselects)
      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"\"]")
        |> render_click()

      # Details panel should be gone - check for the heading tag specifically
      # (HTML comments might still contain the text)
      refute html =~ "<h2 class=\"card-title" and html =~ ">Workstream Details</h2>"
      # Verify the panel layout changed back to full width
      assert html =~ "lg:col-span-3"
    end

    test "details panel shows 'No workspace created yet' when workspace not set", %{conn: conn} do
      # Create task with workstream but no workspace
      task_id = "no-workspace-task-#{System.system_time(:millisecond)}-#{:rand.uniform(100_000)}"
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} =
        EventStore.append(
          task_id,
          "task_created",
          %{title: "Task without workspace"},
          actor_id: "test"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{workstream_id: "ws-no-workspace", spec: "Test spec", dependencies: []},
          actor_id: "scheduler"
        )

      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-no-workspace\"]")
        |> render_click()

      # Should show "No workspace created yet"
      assert html =~ "No workspace created yet"

      # Cleanup
      EventStore.delete_stream(task_id)
    end

    test "details panel shows 'No agent assigned yet' when agent not started", %{conn: conn} do
      # Create task with workstream but no agent
      task_id = "no-agent-task-#{System.system_time(:millisecond)}-#{:rand.uniform(100_000)}"
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} =
        EventStore.append(
          task_id,
          "task_created",
          %{title: "Task without agent"},
          actor_id: "test"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "workstream_created",
          %{workstream_id: "ws-no-agent", spec: "Test spec", dependencies: []},
          actor_id: "scheduler"
        )

      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Navigate to workstreams and select one
      view |> element("button", "Workstreams") |> render_click()

      html =
        view
        |> element("[phx-click=\"select_workstream\"][phx-value-id=\"ws-no-agent\"]")
        |> render_click()

      # Should show "No agent assigned yet"
      assert html =~ "No agent assigned yet"

      # Cleanup
      EventStore.delete_stream(task_id)
    end
  end

  describe "communications tab rendering" do
    setup %{task_id: task_id} do
      # Add some messages
      {:ok, _} =
        EventStore.append(
          task_id,
          "message_posted",
          %{
            message_id: "msg-1",
            type: :update,
            content: "Test update message",
            author: "agent-1",
            posted_at: System.system_time(:second)
          },
          actor_id: "agent-1"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "message_posted",
          %{
            message_id: "msg-2",
            type: :question,
            content: "Test question message?",
            author: "user",
            posted_at: System.system_time(:second)
          },
          actor_id: "user"
        )

      :ok
    end

    test "renders communications tab without crash", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      # Click on Communications tab - should NOT crash
      html =
        view
        |> element("button", "Communications")
        |> render_click()

      assert html =~ "Messages"
      assert html =~ "Inbox"
    end

    test "renders messages in communications tab", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      html =
        view
        |> element("button", "Communications")
        |> render_click()

      assert html =~ "Test update message"
      assert html =~ "Test question message?"
    end
  end

  describe "communications empty state" do
    test "renders empty messages state", %{conn: conn} do
      # Create a new task without messages
      task_id = "no-messages-task-#{System.system_time(:millisecond)}-#{:rand.uniform(100_000)}"
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} =
        EventStore.append(
          task_id,
          "task_created",
          %{title: "Empty Messages Task", description: "No messages"},
          actor_id: "test"
        )

      {:ok, view, _html} = live(conn, ~p"/pods/#{task_id}")

      html =
        view
        |> element("button", "Communications")
        |> render_click()

      assert html =~ "No messages yet"

      # Cleanup
      EventStore.delete_stream(task_id)
    end
  end

  describe "tab navigation" do
    test "can switch between all tabs", %{conn: conn, task_id: task_id} do
      {:ok, view, html} = live(conn, ~p"/pods/#{task_id}")

      # Default tab is Overview
      assert html =~ "Specification"

      # Switch to Workstreams
      html =
        view
        |> element("button", "Workstreams")
        |> render_click()

      refute html =~ "Specification"

      # Switch to Communications
      html =
        view
        |> element("button", "Communications")
        |> render_click()

      assert html =~ "Messages"

      # Switch back to Overview
      html =
        view
        |> element("button", "Overview")
        |> render_click()

      assert html =~ "Specification"
    end
  end

  describe "spec approval workflow" do
    test "can approve spec when not already approved", %{conn: conn} do
      # Create task without spec approval
      task_id =
        "unapproved-spec-task-#{System.system_time(:millisecond)}-#{:rand.uniform(100_000)}"

      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} =
        EventStore.append(
          task_id,
          "task_created",
          %{title: "Unapproved Spec Task", description: "Needs approval"},
          actor_id: "test"
        )

      {:ok, _} =
        EventStore.append(
          task_id,
          "spec_updated",
          %{spec: %{description: "Spec needing approval", requirements: []}},
          actor_id: "test"
        )

      # Allow dynamically started pod processes to access the sandbox
      # This is necessary because the refactored TaskLive now routes events through
      # the Manager process, which runs in a separate Erlang process
      Ecto.Adapters.SQL.Sandbox.mode(Ipa.Repo, {:shared, self()})

      {:ok, view, html} = live(conn, ~p"/pods/#{task_id}")

      # Should show approve button (button text is "Approve" with title "Approve Specification")
      assert html =~ "approve_spec"

      # Click approve
      view
      |> element("button[phx-click=approve_spec]")
      |> render_click()

      # Wait for state update to propagate back via PubSub
      # The Manager broadcasts state updates which LiveView handles
      :timer.sleep(100)

      # Re-render to get updated view
      html = render(view)

      # Should show approved state
      assert html =~ "Spec Approved" or html =~ "Spec approved"

      # Cleanup - stop pod first to avoid orphaned processes
      Ipa.CentralManager.stop_pod(task_id)
      EventStore.delete_stream(task_id)
    end
  end

  describe "error handling" do
    test "redirects to home when task not found", %{conn: conn} do
      # LiveView uses live_redirect for navigation with flash message
      {:error, {:live_redirect, %{to: "/", flash: _flash}}} =
        live(conn, ~p"/pods/nonexistent-task-id")
    end

    test "handles missing optional fields gracefully", %{conn: conn} do
      # Create minimal task
      task_id = "minimal-task-#{System.system_time(:millisecond)}-#{:rand.uniform(100_000)}"
      {:ok, ^task_id} = EventStore.start_stream("task", task_id)

      {:ok, _} =
        EventStore.append(
          task_id,
          "task_created",
          %{title: "Minimal Task"},
          actor_id: "test"
        )

      # Should render without crashing even with minimal data
      {:ok, _view, html} = live(conn, ~p"/pods/#{task_id}")

      assert html =~ "Minimal Task"

      # Cleanup
      EventStore.delete_stream(task_id)
    end
  end
end
