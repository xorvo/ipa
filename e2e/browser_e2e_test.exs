# Browser E2E Test Script: Task Lifecycle via UI
#
# This script provides step-by-step instructions for running browser-based E2E tests
# using Playwright MCP tools with Claude Code.
#
# Prerequisites:
#   - Phoenix server running on http://localhost:4000
#   - Playwright MCP server connected
#
# Usage:
#   Run these commands interactively with Claude Code that has Playwright MCP enabled.

defmodule E2ETest.BrowserSteps do
  @moduledoc """
  Browser-based E2E test steps using Playwright MCP.
  Run each step interactively with Claude Code.
  """

  @base_url "http://localhost:4000"

  @doc """
  Step 1: Navigate to Dashboard

  Playwright commands:
    mcp__playwright__browser_navigate(url: "http://localhost:4000/")
    mcp__playwright__browser_snapshot()

  Expected:
    - Dashboard page loads
    - "New Task" button visible
    - Task list visible (may be empty or have existing tasks)
  """
  def step_1_navigate_to_dashboard do
    IO.puts("""

    === STEP 1: Navigate to Dashboard ===

    Run these Playwright MCP commands:

    1. mcp__playwright__browser_navigate(url: "#{@base_url}/")
    2. mcp__playwright__browser_snapshot()

    Verify:
    - Dashboard page loads
    - "New Task" button is visible
    - Stats bar shows task counts
    """)
  end

  @doc """
  Step 2: Create New Task

  Playwright commands:
    mcp__playwright__browser_click(element: "New Task button", ref: <ref from snapshot>)
    mcp__playwright__browser_snapshot()
    mcp__playwright__browser_type(element: "Task title input", ref: <ref>, text: "E2E Browser Test")
    mcp__playwright__browser_click(element: "Create button", ref: <ref>)
    mcp__playwright__browser_snapshot()

  Expected:
    - Modal opens
    - Title entered
    - Task created and appears in list
  """
  def step_2_create_task do
    IO.puts("""

    === STEP 2: Create New Task ===

    Run these Playwright MCP commands:

    1. Click "New Task" button:
       mcp__playwright__browser_click(element: "New Task button", ref: <ref>)

    2. Take snapshot to see modal:
       mcp__playwright__browser_snapshot()

    3. Type task title:
       mcp__playwright__browser_type(element: "Task title input", ref: <ref>, text: "E2E Browser Test")

    4. Click "Create" button:
       mcp__playwright__browser_click(element: "Create button", ref: <ref>)

    5. Verify task was created:
       mcp__playwright__browser_snapshot()

    Verify:
    - Modal opens with title input
    - Task is created successfully
    - Task appears in list with "Spec clarification" badge
    """)
  end

  @doc """
  Step 3: Open Task Detail Page

  Playwright commands:
    mcp__playwright__browser_click(element: "Open button", ref: <ref>)
    mcp__playwright__browser_snapshot()

  Expected:
    - Task detail page loads
    - Phase shows "Spec clarification"
    - Specification section visible
  """
  def step_3_open_task do
    IO.puts("""

    === STEP 3: Open Task Detail Page ===

    Run these Playwright MCP commands:

    1. Click "Open" button for the new task:
       mcp__playwright__browser_click(element: "Open button", ref: <ref>)

    2. Take snapshot:
       mcp__playwright__browser_snapshot()

    Verify:
    - Task detail page loads
    - Phase badge shows "Spec clarification"
    - Specification section shows "Add Specification" or "Edit Spec" button
    """)
  end

  @doc """
  Step 4: Edit and Approve Spec

  Playwright commands:
    mcp__playwright__browser_click(element: "Edit Spec button", ref: <ref>)
    mcp__playwright__browser_type(element: "Description textarea", ref: <ref>, text: "Test spec...")
    mcp__playwright__browser_click(element: "Save Spec button", ref: <ref>)
    mcp__playwright__browser_click(element: "Approve Spec button", ref: <ref>)
    mcp__playwright__browser_snapshot()

  Expected:
    - Spec form opens
    - Spec saved successfully
    - "Spec Approved" message appears
  """
  def step_4_edit_and_approve_spec do
    IO.puts("""

    === STEP 4: Edit and Approve Spec ===

    Run these Playwright MCP commands:

    1. Click "Edit Spec" or "Add Specification" button:
       mcp__playwright__browser_click(element: "Edit Spec button", ref: <ref>)

    2. Take snapshot to see form:
       mcp__playwright__browser_snapshot()

    3. Enter spec description:
       mcp__playwright__browser_type(element: "Description textarea", ref: <ref>,
         text: "Create a hello world program that prints a greeting")

    4. Click "Save Spec":
       mcp__playwright__browser_click(element: "Save Spec button", ref: <ref>)

    5. Click "Approve Spec":
       mcp__playwright__browser_click(element: "Approve Spec button", ref: <ref>)

    6. Take snapshot:
       mcp__playwright__browser_snapshot()

    Verify:
    - Spec form opens with textarea
    - Spec is saved (flash message)
    - "Spec Approved" appears with checkmark
    """)
  end

  @doc """
  Step 5: Approve Transition to Planning

  Playwright commands:
    mcp__playwright__browser_wait_for(text: "Pending Transition")
    mcp__playwright__browser_click(element: "Approve button", ref: <ref>)
    mcp__playwright__browser_snapshot()

  Expected:
    - Pending Transition card appears
    - After clicking Approve, phase changes to "Planning"
  """
  def step_5_approve_transition do
    IO.puts("""

    === STEP 5: Approve Transition to Planning ===

    Note: You may need to wait or start the pod for the scheduler to create
    the transition request. If pod is not running, you can start it from the dashboard.

    Run these Playwright MCP commands:

    1. Wait for "Pending Transition" card (may need to refresh or start pod):
       mcp__playwright__browser_wait_for(text: "Pending Transition")

    2. Take snapshot:
       mcp__playwright__browser_snapshot()

    3. Click "Approve" button in Pending Transition card:
       mcp__playwright__browser_click(element: "Approve button", ref: <ref>)

    4. Take snapshot:
       mcp__playwright__browser_snapshot()

    Verify:
    - Pending Transition card shows "Transition to planning"
    - After approval, phase badge changes to "Planning"
    - Pending Transition card disappears
    """)
  end

  @doc """
  Step 6: Verify Planning Phase

  Expected:
    - Phase shows "Planning"
    - Pod may start planning agent (if running)
    - Workstreams tab will show workstreams when created
  """
  def step_6_verify_planning do
    IO.puts("""

    === STEP 6: Verify Planning Phase ===

    Take a final snapshot:

    1. mcp__playwright__browser_snapshot()

    2. Optionally take a screenshot:
       mcp__playwright__browser_take_screenshot(filename: "planning-phase.png")

    Verify:
    - Phase badge shows "Planning"
    - Spec section shows "Spec Approved"
    - If pod is running, scheduler will start creating workstreams

    === END OF BASIC E2E TEST ===

    The task has successfully transitioned from:
    spec_clarification -> planning

    Further testing (requires running pod and Claude Code SDK):
    - Wait for planning agent to create workstreams
    - Approve workstream plan
    - Watch workstream execution
    - Verify PR consolidation in review phase
    """)
  end

  @doc """
  Run all steps documentation
  """
  def run do
    step_1_navigate_to_dashboard()
    step_2_create_task()
    step_3_open_task()
    step_4_edit_and_approve_spec()
    step_5_approve_transition()
    step_6_verify_planning()
  end
end

# Print all steps
E2ETest.BrowserSteps.run()
