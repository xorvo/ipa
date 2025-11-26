# E2E Test: Task Lifecycle

This document describes the end-to-end test flow for the IPA task lifecycle.
The test uses Playwright MCP tools to interact with the web UI.

## Prerequisites

1. Phoenix server running on http://localhost:4000
2. PostgreSQL database running with `ipa_dev` database
3. Playwright MCP server connected

## Test Flow

### Phase 1: Dashboard - Create New Task

1. Navigate to dashboard: `http://localhost:4000/`
2. Click "New Task" button
3. Enter task title in modal
4. Click "Create" button
5. Verify task appears in list
6. Click "Open" to navigate to task detail page

### Phase 2: Task Detail - Spec Clarification

1. Verify task is in "Spec clarification" phase
2. Click "Edit Spec" or "Add Specification" button
3. Enter specification description
4. Click "Save Spec" button
5. Verify spec is displayed
6. Click "Approve Spec" button
7. Verify "Spec Approved" message appears

### Phase 3: Transition to Planning

1. Wait for "Pending Transition" card to appear (scheduler creates it)
2. Click "Approve" button for transition to planning
3. Verify phase changes to "Planning"

### Phase 4: Planning Phase (if pod running)

1. Start pod if not running
2. Scheduler will spawn planning agent
3. Wait for workstreams to be created
4. Approve workstream plan

### Phase 5: Workstream Execution (if pod running)

1. Verify phase changes to "Workstream execution"
2. Check Workstreams tab for workstream list
3. Monitor workstream status

### Phase 6: Review Phase

1. Verify phase changes to "Review" when all workstreams complete
2. PR consolidation agent creates PR

### Phase 7: Completion

1. Approve PR merge
2. Verify phase changes to "Completed"

## Test Commands Reference

### Browser Navigation
```
mcp__playwright__browser_navigate(url)
mcp__playwright__browser_snapshot()
mcp__playwright__browser_take_screenshot(filename)
```

### Element Interaction
```
mcp__playwright__browser_click(element, ref)
mcp__playwright__browser_type(element, ref, text)
mcp__playwright__browser_fill_form(fields)
```

### Wait Operations
```
mcp__playwright__browser_wait_for(text)
mcp__playwright__browser_wait_for(time=seconds)
```

## Manual Test Execution

Run each step manually using Claude Code with Playwright MCP tools enabled.

Example session:
```
1. Navigate to dashboard
2. Take snapshot to see current state
3. Click appropriate buttons based on snapshot refs
4. Verify state changes
5. Continue to next step
```
