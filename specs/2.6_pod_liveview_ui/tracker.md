# Pod LiveView UI - Implementation Tracker

## Status

**Component**: 2.6 Pod LiveView UI
**Status**: ✅ Spec Approved - All P0 Issues Resolved - Ready for Implementation
**Started**: 2025-11-05
**Last Updated**: 2025-11-06
**Reviewed By**: Architecture Strategist Agent
**Review Score**: 8.5/10 - Approved with Recommended Changes
**P0 Issues**: ✅ All resolved (Agent logs + WorkspaceManager API)

## Overview

This component provides the real-time web interface for monitoring and interacting with task pods.

## Dependencies

**Blocked By**:
- ✅ 1.1 Event Store (Complete)
- ✅ 2.1 Pod Supervisor (Complete)
- ✅ 2.2 Pod State Manager (Complete)
- ⏳ 2.3 Pod Scheduler (Required for agent interruption)
- ⏳ 2.4 Pod Workspace Manager (Required for file browsing)
- ⏳ 2.5 Pod External Sync (Required for sync status display)

**Unblocks**:
- None (end-user facing component)

## Implementation Plan

### Phase 1: Basic Structure (Day 1)
- [ ] Create LiveView module structure
- [ ] Set up routes
- [ ] Implement mount/3 with state loading
- [ ] Implement handle_info/2 for pub-sub
- [ ] Basic template structure
- [ ] Test mounting and state subscription

### Phase 2: Core Components (Day 1-2)
- [ ] Task Header component
- [ ] Spec Section component with approval button
- [ ] Plan Section component with approval button
- [ ] Pending Transitions banner
- [ ] Test approval workflows
- [ ] Test version conflict handling

### Phase 3: Agent Monitoring (Day 2)
- [ ] Agent Monitor component
- [ ] Agent list display
- [ ] Agent interrupt handler
- [ ] Agent log display (if agent logs implemented)
- [ ] Test agent interruption

### Phase 4: Workspace Browser (Day 2-3)
- [ ] Workspace Browser component
- [ ] File tree loading
- [ ] File selection handler
- [ ] File viewer with syntax highlighting
- [ ] Test file browsing and viewing

### Phase 5: External Sync (Day 3)
- [ ] External Sync Status component
- [ ] GitHub PR display
- [ ] JIRA ticket display
- [ ] Test external sync status

### Phase 6: Polish & Testing (Day 3)
- [ ] Styling with TailwindCSS
- [ ] Responsive layout
- [ ] Error handling
- [ ] Flash messages
- [ ] Loading states
- [ ] All unit tests
- [ ] Integration tests
- [ ] Manual testing checklist

## Current Tasks

### Specification Phase
- [x] Write detailed spec
- [x] Review spec with architecture-strategist agent
- [x] Address review feedback
- [x] Get spec approved

### Implementation Phase
- [ ] Waiting for dependencies (Pod Scheduler, Workspace Manager, External Sync)
- [ ] Begin implementation once dependencies are ready

## Issues & Questions

### Resolved Questions
1. **Agent Logs**: ✅ Use separate pub-sub stream, NOT events
   - Storing logs as events would cause severe performance issues
   - Solution: Pub-sub topic `"pod:#{task_id}:agent:#{agent_id}:logs"`
   - Logs stored in LiveView socket assigns (ephemeral, not persisted)
   - Resolved by: Architecture review (Critical Issue #1)
   - **STATUS**: ✅ Spec updated with pub-sub implementation (lines 577-651)

2. **WorkspaceManager API**: ✅ Documented missing `list_files/2` function
   - Added explicit dependency note in spec
   - Must be implemented in WorkspaceManager before file browsing can work
   - Resolved by: Architecture review (Critical Issue #2)
   - **STATUS**: ✅ API added to WorkspaceManager spec 2.4 (lines 431-509)

3. **User Authentication**: ✅ Added comprehensive authentication section
   - Documented on_mount hook pattern
   - Specified current_user structure
   - Added authorization strategy
   - Resolved by: Architecture review (Major Issue #3)

4. **Agent Log Retention**: ✅ Last 1000 messages total (all agents), configurable
   - Automatic rotation in handle_info/2
   - ~100KB memory per LiveView connection

5. **Large Files**: ✅ Show warning + download link for files > 1MB
   - Enforced in configuration
   - Check file size before loading

### Open Questions
1. **File Syntax Highlighting**: Which library to use?
   - Options: Monaco Editor (heavy), Highlight.js (lightweight), Prism.js (lightweight)
   - **Recommendation**: Start with Prism.js for MVP
   - **Status**: Defer to implementation phase

## Implementation Notes

### Key Design Decisions

1. **Real-Time Updates**: Use Phoenix LiveView pub-sub for automatic UI updates
2. **Optimistic Concurrency**: Always pass `expected_version` when appending events
3. **Component Structure**: Break UI into reusable components for better maintainability
4. **Error Handling**: Use flash messages for user feedback

### Performance Considerations

1. **Rendering**: Keep template computations lightweight
2. **Memory**: Implement log rotation for agent logs
3. **Network**: LiveView handles diffing automatically

### Testing Strategy

1. **Unit Tests**: Test each event handler individually
2. **Integration Tests**: Test full workflows (spec → plan → development)
3. **Manual Tests**: Test real-time updates, responsiveness, error cases

## Blockers

### Current Blockers
- None (spec phase)

### Future Blockers (Implementation)
- Need Pod Scheduler for agent interruption
- Need Workspace Manager for file browsing
- Need External Sync for sync status

## Progress Log

### 2025-11-06 - P0 Issues Resolution
- **All P0/Critical Issues Resolved**:
  1. ✅ **Agent Log Storage** (Issue #1): Spec updated with separate pub-sub stream implementation
     - Lines 577-651 show complete implementation using `"pod:#{task_id}:agent:#{agent_id}:logs"` topic
     - Logs stored in LiveView assigns (in-memory, ephemeral)
     - Memory rotation strategy: keep last 1000 messages
     - No event store pollution

  2. ✅ **WorkspaceManager API** (Issue #2): `list_files/2` added to WorkspaceManager spec
     - Spec 2.4 lines 431-509 define complete API
     - Returns nested map file tree structure
     - Proper error handling for workspace not found
     - Implementation included with recursive tree building

- **Spec Status**: ✅ FULLY READY FOR IMPLEMENTATION
  - All P0 blockers resolved
  - All critical issues addressed in spec
  - Major issues (auth, memory) already documented
  - Dependencies clearly identified

### 2025-11-05 - Afternoon
- **Architecture Review Completed**
  - Received comprehensive 1,130-line review from architecture-strategist agent
  - Overall score: 8.5/10 - Approved with recommended changes
  - Identified 8 issues (2 critical, 3 major, 3 minor)

- **Critical Issues Identified**:
  1. Agent log storage: Changed from events to separate pub-sub stream
  2. WorkspaceManager API: Documented missing `list_files/2` function

- **Major Issues Resolved**:
  3. User authentication: Added comprehensive section with on_mount pattern
  4. Memory management: Updated with log rotation strategy
  5. Socket assigns: Added agent_logs and current_user documentation

- **Spec Status**: ✅ Approved for implementation
  - All critical issues addressed
  - Major issues resolved
  - Minor issues noted for implementation phase
  - Ready to proceed once dependencies are complete

### 2025-11-05 - Morning
- Created detailed specification
- Defined all LiveView callbacks and event handlers
- Designed UI layout and component structure (6 components)
- Documented testing requirements
- Submitted for architecture review

## Next Steps

1. ✅ ~~Get spec reviewed by architecture-strategist agent~~ - DONE
2. ✅ ~~Address critical feedback from review~~ - DONE
3. ✅ ~~Get spec approved~~ - DONE
4. ✅ ~~Resolve all P0 issues~~ - DONE
   - ✅ Agent log storage: Spec updated with pub-sub implementation
   - ✅ WorkspaceManager API: `list_files/2` added to spec 2.4
5. **CURRENT**: Wait for dependencies to be completed:
   - 2.3 Pod Scheduler (for agent interruption and log streaming)
   - 2.4 Pod Workspace Manager (with `list_files/2` implementation)
   - 2.5 Pod External Sync (for sync status display)
6. **NEXT**: Begin implementation following phased plan (3-day estimate)

## Implementation Blockers

### Critical Dependencies
- **Pod Scheduler (2.3)**: Required for agent interruption and log pub-sub
  - Must implement log broadcasting via `"pod:#{task_id}:agent:#{agent_id}:logs"` topic
  - Must implement `interrupt_agent/2` API
- **Workspace Manager (2.4)**: Must implement `list_files/2` before file browsing
  - ✅ API spec complete (lines 431-509 in spec 2.4)
  - ⏳ Implementation pending

### Optional Dependencies
- **External Sync (2.5)**: Can stub external sync status in MVP if not ready

### Recommendation
- Implement core LiveView (Phases 1-3) first: Task display, approvals, agent monitoring
- Defer Workspace Browser (Phase 4) until WorkspaceManager.list_files/2 is implemented
- Defer External Sync display (Phase 5) until ExternalSync is ready

### P0 Status: ✅ ALL CLEAR
- No P0 blockers remaining
- All critical spec issues resolved
- Ready to begin implementation when dependencies complete
