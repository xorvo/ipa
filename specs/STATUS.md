# IPA Project Status Tracker

**Last Updated**: 2025-11-06
**Current Phase**: Architecture Refactor & Planning
**Overall Progress**: 0% (11 components, 0 completed, 6 specs approved, 2 new components added, 3 major refactors needed)

## Architecture Refactor (In Progress)

**Status**: Major architectural enhancements introduced to support parallel workstreams and multi-agent coordination.

**Key Changes**:
1. **Workstreams Layer**: Tasks now break down into parallel workstreams (one agent per workstream)
2. **Communications System**: New structured messaging for human-agent and agent-agent coordination
3. **CLAUDE.md Templates**: Multi-level contextual instructions for agents
4. **Single Event Stream**: All workstream and message events in task event stream
5. **Updated Timeline**: ~7 weeks → ~15 weeks (more than 2x due to complexity)

**New Components**:
- 2.7 Pod Communications Manager (NEW - 2.5 weeks)
- 2.8 CLAUDE.md Template System (NEW - 1 week)

**Major Component Updates Needed**:
- 2.2 Pod State Manager: Add workstream/message projections (+1 week)
- 2.3 Pod Scheduler: Transform to orchestration engine (+3 weeks)
- 2.6 Pod LiveView UI: Add workstreams and communications tabs (+1.5 weeks)

**Refactor Tracking**:
- [x] Overview spec updated (specs/00_overview.md)
- [x] CLAUDE.md updated with new concepts
- [x] Placeholder folders created for new components (2.7, 2.8)
- [x] Dependency graph updated (specs/01_dependency_graph.md)
- [x] Component 2.7 spec created (Communications Manager) - 981 lines, COMPLETE
- [x] Component 2.8 spec created (CLAUDE.md Templates) - 716 lines, COMPLETE
- [x] Component 2.2 refactor plan created (Pod State Manager) - REFACTOR_PLAN.md
- [x] Component 2.3 refactor plan created (Pod Scheduler) - REFACTOR_PLAN.md
- [x] Component 2.6 refactor plan created (Pod LiveView UI) - REFACTOR_PLAN.md
- [ ] Component 2.2 spec updated (apply refactor plan to full spec)
- [ ] Component 2.3 spec updated (apply refactor plan to full spec)
- [ ] Component 2.6 spec updated (apply refactor plan to full spec)

**Architecture Review Tracking**:
- [x] Component 2.7 (Communications Manager) - Score: 9.5/10 - ✅ APPROVED (All P0 fixes applied and validated)
- [x] Component 2.8 (CLAUDE.md Templates) - Score: 8.5/10 - APPROVED with 2 P1 issues to address
- [x] Component 2.2 Refactor Plan (Pod State Manager) - Score: 8.5/10 - ✅ APPROVED (All P0 fixes applied and validated)
- [x] Component 2.3 Refactor Plan (Pod Scheduler) - Score: 9.0/10 - ✅ APPROVED (All 7 P0 fixes applied and validated, 3 P1 issues to address during implementation)
- [x] Component 2.6 Refactor Plan (Pod LiveView UI) - Score: 6.5/10 - REVISE REQUIRED (8 P0 issues, unblocked by 2.2 & 2.7)

## Quick Status Overview

| Component | Status | Progress | PR | Notes |
|-----------|--------|----------|-----|-------|
| 1.1 SQLite Event Store | ✅ Spec Approved | 10% | - | Foundation layer, spec complete, needs update for single stream model |
| 2.1 Task Pod Supervisor | ✅ Spec Approved | 5% | - | Spec complete, blocked by 1.1 implementation |
| 2.2 Pod State Manager | 🔄 Refactor Plan Ready | 10% | - | Refactor plan complete, needs spec update with workstream/message projections |
| 2.3 Pod Scheduler | 🔄 Refactor Plan Ready | 5% | - | Refactor plan complete, needs spec rewrite as orchestration engine |
| 2.4 Pod Workspace Manager | ✅ Spec Approved | 10% | - | Spec complete, needs minor update for CLAUDE.md injection |
| 2.5 Pod External Sync | ✅ Spec Approved | 5% | - | Spec complete, needs minor update for workstream reporting |
| 2.6 Pod LiveView UI | 🔄 Refactor Plan Ready | 10% | - | Refactor plan complete, needs spec update with workstreams & communications tabs |
| 2.7 Pod Communications Manager | ✅ Spec Complete | 15% | - | NEW component, comprehensive 981-line spec complete and ready for review |
| 2.8 CLAUDE.md Templates | ✅ Spec Complete | 15% | - | NEW component, comprehensive 716-line spec complete and ready for review |
| 3.1 Central Task Manager | 📝 Not Started | 0% | - | Blocked by 1.1, 2.1 |
| 3.2 Central Dashboard UI | 📝 Not Started | 0% | - | Blocked by 3.1, needs minor update for message counts |

**Status Legend:**
- 📝 Not Started / Spec Needed
- 📋 Spec In Progress
- ✅ Spec Approved
- 🔄 Needs Update (architecture refactor)
- 🚧 Implementation In Progress
- 🧪 Testing
- 👀 Code Review
- ✅ Completed & Merged

## Current Sprint Goals

**Sprint 0: Project Setup & Planning**
- [x] Create top-level overview spec
- [x] Create dependency graph
- [x] Create status tracker
- [ ] Review and approve top-level specs
- [ ] Initialize Phoenix project
- [ ] Create individual component specs

## Detailed Component Status

### Layer 1: Shared Persistence

#### 1.1 SQLite Event Store
- **Status**: ✅ Spec Approved
- **Spec**: ✅ Complete (`specs/1.1_event_store/spec.md`)
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: None
- **Estimated Completion**: 3-4 days
- **Notes**: Spec reviewed by architecture-strategist agent and all critical issues resolved. Ready for implementation.

**Tasks:**
- [ ] Create Phoenix app structure
- [ ] Add SQLite dependencies (ecto_sqlite3)
- [ ] Define database schema (tasks, events, snapshots tables)
- [ ] Create Ipa.EventStore module
- [ ] Implement append_event function
- [ ] Implement load_events function
- [ ] Implement load_events_since function
- [ ] Implement save_snapshot function
- [ ] Implement load_snapshot function
- [ ] Write unit tests for EventStore
- [ ] Test concurrent writes
- [ ] Test event replay consistency

---

### Layer 2: Pod Infrastructure

#### 2.1 Task Pod Supervisor
- **Status**: 📋 Spec Complete
- **Spec**: ✅ Complete (`specs/2.1_pod_supervisor/spec.md`)
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Component 1.1 (implementation)
- **Estimated Completion**: 2 days after 1.1 complete
- **Notes**: Spec complete. Foundation for all Layer 2 components. Uses DynamicSupervisor + Registry pattern.

**Tasks:**
- [ ] Create `lib/ipa/pod/` directory structure
- [ ] Implement PodRegistry module
- [ ] Implement PodSupervisor (DynamicSupervisor)
- [ ] Implement Ipa.Pod (per-pod Supervisor)
- [ ] Implement start_pod/stop_pod/restart_pod functions
- [ ] Implement query functions (list_pods, count_pods, get_pod_pid)
- [ ] Write unit tests for all lifecycle operations
- [ ] Write integration tests for child supervision
- [ ] Write performance tests for registry operations

---

#### 2.2 Pod State Manager
- **Status**: ✅ Spec Approved
- **Spec**: ✅ Complete (`specs/2.2_pod_state_manager/spec.md`)
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Components 1.1, 2.1 (implementation)
- **Estimated Completion**: Week 2, Day 3-5 (2-3 days after 1.1, 2.1 complete)
- **Notes**: Spec reviewed by architecture-strategist (score: 9/10). All critical fixes implemented. Provides event-sourced state management, pub-sub broadcasting, optimistic concurrency. Ready for implementation.

**Tasks:**
- [ ] Create GenServer module
- [ ] Implement event loading on startup
- [ ] Build in-memory state projection
- [ ] Add event append with version checking
- [ ] Set up pod-local pub-sub
- [ ] Implement get_state query
- [ ] Write unit tests for state projection
- [ ] Test optimistic concurrency conflicts
- [ ] Test pub-sub message delivery

---

#### 2.3 Pod Scheduler
- **Status**: 📝 Not Started
- **Spec**: Not created
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Components 1.1, 2.1, 2.2, 2.4
- **Estimated Completion**: Week 3-4
- **Notes**: Complex state machine, needs careful design

**Tasks:**
- [ ] Create GenServer module
- [ ] Subscribe to pod-local pub-sub
- [ ] Implement state machine logic for each phase
- [ ] Build action dispatcher
- [ ] Add agent spawning via Claude Code SDK
- [ ] Implement cooldown management
- [ ] Add agent interruption handling
- [ ] Write state transition tests
- [ ] Test agent spawning
- [ ] Integration test with real agent

---

#### 2.4 Pod Workspace Manager
- **Status**: ✅ Spec Approved
- **Spec**: ✅ Complete (`specs/2.4_pod_workspace_manager/spec.md`)
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Components 1.1, 2.1 (implementation)
- **Estimated Completion**: Week 3, Day 1-2 (2 days after 1.1, 2.1 complete)
- **Notes**: Spec reviewed by architecture-strategist. All critical fixes implemented (event-sourced state, path validation security, graceful shutdown). Primary role clarified: thin wrapper around `aw` CLI tool for workspace lifecycle management. Agents execute in workspaces via Claude Code SDK with `cwd` parameter. Ready for implementation.

**Critical Fixes Applied:**
- ✅ Event-sourced state management with explicit replay logic
- ✅ Enhanced path validation (symlink detection, traversal prevention)
- ✅ Graceful shutdown with `terminate/2` callback
- ✅ `aw` CLI integration as primary interface (create/destroy/list)

**Architecture:**
- WorkspaceManager = Thin wrapper around external `aw` CLI tool
- `aw create` handles workspace directory creation and initialization
- `aw destroy` handles workspace cleanup
- `aw list` queries active workspaces
- Agents execute in workspace via Claude Code SDK (cwd parameter)
- File operations are optional utilities for pod-level inspection

**Tasks:**
- [ ] Verify `aw` CLI tool is installed and available
- [ ] Create GenServer module with event-sourced state
- [ ] Implement `aw create` wrapper (create_workspace/3)
- [ ] Implement `aw destroy` wrapper (cleanup_workspace/2)
- [ ] Implement `aw list` wrapper (list_workspaces/1)
- [ ] Add path validation utilities (read_file/3, write_file/4)
- [ ] Implement graceful shutdown with terminate/2
- [ ] Write unit tests with System.cmd mocks
- [ ] Write integration tests with real `aw` CLI
- [ ] Test event-sourced state reconstruction
- [ ] Test graceful shutdown cleanup

---

#### 2.5 Pod External Sync Engine
- **Status**: ✅ Spec Approved
- **Spec**: ✅ Complete (`specs/2.5_pod_external_sync/spec.md`)
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Components 1.1, 2.1, 2.2 (implementation)
- **Estimated Completion**: Week 4-5 (3-4 days after 2.2 complete)
- **Notes**: Spec reviewed by architecture-strategist (score: 8.5/10). All 5 critical fixes implemented. Handles GitHub/JIRA sync with approval gates, adaptive polling, idempotency checks, and comprehensive error handling. Ready for implementation.

**Tasks:**
- [ ] Create GenServer module with Registry registration
- [ ] Subscribe to pod-local pub-sub for state changes
- [ ] Implement sync queue with deduplication and backpressure
- [ ] Implement GitHub connector with rate limiting
- [ ] Implement JIRA connector
- [ ] Implement sync triggers (evaluate_sync_triggers)
- [ ] Implement idempotency checks for GitHub (check_existing_pr)
- [ ] Implement idempotency checks for JIRA
- [ ] Implement adaptive polling logic
- [ ] Implement approval gate system
- [ ] Implement graceful shutdown with operation cancellation
- [ ] Write unit tests with mocked external APIs
- [ ] Test sync queue processing and completion messages
- [ ] Test approval gate workflow
- [ ] Test adaptive polling rate adjustment
- [ ] Test idempotency (retry operations should be safe)
- [ ] Integration test with real GitHub/JIRA (optional)

---

#### 2.6 Pod LiveView UI
- **Status**: ✅ Spec Approved
- **Spec**: ✅ Complete (`specs/2.6_pod_liveview_ui/spec.md`)
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Components 1.1, 2.1, 2.2 (implementation)
- **Estimated Completion**: Week 3, Day 3-5 (2-3 days after 2.2 complete)
- **Notes**: Spec complete and reviewed. All critical integration issues resolved. Real-time UI with Phoenix LiveView, agent log streaming via separate pub-sub, workspace browser with file tree. Ready for implementation.

**Critical Fixes Applied:**
- ✅ Fixed file selection error handling to match WorkspaceManager API (`:file_not_found`, `:workspace_not_found`)
- ✅ Removed dependency warning for `list_files/2` (API added to WorkspaceManager spec 2.4)
- ✅ Fixed agent log test to use separate pub-sub stream instead of event store
- ✅ Updated all error handling sections to match component APIs

**Tasks:**
- [ ] Create LiveView module with proper authentication (on_mount hook)
- [ ] Add route to router (`/pods/:task_id`)
- [ ] Subscribe to pod-local pub-sub for state updates
- [ ] Subscribe to agent log pub-sub streams (separate from events)
- [ ] Implement mount/3 with state loading and WebSocket subscription
- [ ] Implement handle_info/2 for state updates and agent logs
- [ ] Create task header component (phase, status badges)
- [ ] Create spec section component with approval button
- [ ] Create plan section component with approval button
- [ ] Create agent monitor component with log streaming
- [ ] Implement workspace browser with file tree (uses `list_files/2`)
- [ ] Implement file viewer for selected files
- [ ] Create external sync status component (GitHub PR, JIRA ticket)
- [ ] Implement approval event handlers (spec, plan, transitions)
- [ ] Implement agent interrupt handler
- [ ] Add pending transitions display banner
- [ ] Style with Tailwind CSS (phase colors, status badges)
- [ ] Write unit tests for event handlers
- [ ] Write integration tests for real-time updates
- [ ] Test version conflict handling
- [ ] Test agent log streaming
- [ ] Test workspace browser file selection

---

#### 2.7 Pod Communications Manager
- **Status**: 📝 Spec Needed (NEW COMPONENT)
- **Spec**: Placeholder created (`specs/2.7_pod_communications_manager/spec.md`)
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Components 1.1, 2.1, 2.2 (implementation)
- **Estimated Completion**: 2.5 weeks (after 2.2 complete)
- **Notes**: NEW component for structured human-agent and agent-agent communication. Critical for multi-agent coordination.

**Key Features:**
- Threaded messaging (like Slack)
- Message types: question, approval, update, blocker
- Inbox/notification management
- Human approval workflows
- Real-time pub-sub broadcasting

**Tasks:**
- [ ] Complete detailed specification
- [ ] Define message model and state structure
- [ ] Design threading logic
- [ ] Design inbox/notification system
- [ ] Design approval workflow
- [ ] Get spec reviewed
- [ ] Begin implementation after 2.2 complete

---

#### 2.8 CLAUDE.md Template System
- **Status**: 📝 Spec Needed (NEW COMPONENT)
- **Spec**: Placeholder created (`specs/2.8_claude_md_templates/spec.md`)
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Component 2.2 (implementation)
- **Estimated Completion**: 1 week (after 2.2 complete)
- **Notes**: NEW component for multi-level contextual CLAUDE.md generation. Ensures agents have proper context.

**Key Features:**
- System-level template (static)
- Pod-level template generation
- Workstream-level template generation
- Context injection logic

**Tasks:**
- [ ] Complete detailed specification
- [ ] Design template structure and format
- [ ] Define context injection rules
- [ ] Get spec reviewed
- [ ] Begin implementation after 2.2 complete

---

### Layer 3: Central Management

#### 3.1 Central Task Manager
- **Status**: 📝 Not Started
- **Spec**: Not created
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Components 1.1, 2.1
- **Estimated Completion**: Week 3
- **Notes**: Can start after 2.2 is complete

**Tasks:**
- [ ] Create GenServer module
- [ ] Implement pod lifecycle (start_pod, stop_pod)
- [ ] Add pod registry
- [ ] Implement get_active_pods
- [ ] Add pod_running? check
- [ ] Handle pod crash notifications
- [ ] Write unit tests
- [ ] Test pod lifecycle
- [ ] Test concurrent pod operations

---

#### 3.2 Central Dashboard UI
- **Status**: 📝 Not Started
- **Spec**: Not created
- **Implementation**: Not started
- **Tests**: Not written
- **PR**: N/A
- **Blockers**: Component 3.1
- **Estimated Completion**: Week 3
- **Notes**: Simple UI, quick to implement

**Tasks:**
- [ ] Create LiveView module
- [ ] Add route to router
- [ ] Implement task list view
- [ ] Add task creation form
- [ ] Implement navigation to pod UIs
- [ ] Add task completion/cancellation
- [ ] Style with Tailwind CSS
- [ ] Write LiveView tests
- [ ] Test navigation flow

---

## Milestones

### Milestone 1: Foundation Complete (Day 4-5)
- [x] Project structure created
- [x] Top-level specs complete
- [ ] Component 1.1 (SQLite Event Store) complete
- [ ] SQLite database and tables created
- [ ] Event recording and replay working

### Milestone 2: Pod Core Complete (End of Week 2)
- [ ] Component 2.1 (Pod Supervisor) complete
- [ ] Component 2.2 (Pod State Manager) complete
- [ ] Component 2.4 (Pod Workspace Manager) complete
- [ ] Can create pod, load state, create workspace

### Milestone 3: Central Management Complete (End of Week 3)
- [ ] Component 3.1 (Central Manager) complete
- [ ] Component 3.2 (Central Dashboard) complete
- [ ] Can create tasks from UI, navigate to pods

### Milestone 4: Pod Automation Complete (End of Week 4)
- [ ] Component 2.3 (Pod Scheduler) complete
- [ ] Component 2.6 (Pod LiveView) complete
- [ ] Agents can be spawned and monitored
- [ ] End-to-end task flow working

### Milestone 5: External Integrations Complete (End of Week 5)
- [ ] Component 2.5 (External Sync) complete
- [ ] GitHub integration working
- [ ] JIRA integration working
- [ ] Full system operational

## Risks & Issues

### Current Risks
1. **Claude Code SDK availability** - External dependency
   - **Mitigation**: Design scheduler to handle failures gracefully
   - **Status**: Monitoring

2. **`aw` CLI tool availability** - External dependency for workspace management
   - **Mitigation**: WorkspaceManager verifies `aw` CLI on init, fails fast if not available
   - **Impact**: Critical - workspaces cannot be created without `aw` CLI
   - **Status**: Must be installed in production environment
   - **Documentation**: Need to document `aw` CLI installation requirements

3. **SQLite concurrent write performance** - Single-file database
   - **Mitigation**: Each task has its own write path, pod isolation reduces contention
   - **Status**: Will monitor in testing

### Current Issues
None

### Resolved Issues
None

## Recent Activity

**2025-11-05**: Project initialization & spec generation
- Created project repository
- Created top-level specs (overview, dependency graph, status tracker)
- ✅ Created Event Store spec (1.1) - reviewed and approved by architecture-strategist agent
- ✅ Fixed all critical issues in Event Store spec
- ✅ Created Pod Supervisor spec (2.1) - reviewed and approved
- ✅ Fixed all critical issues in Pod Supervisor spec
- ✅ Reviewed and improved Pod State Manager spec (2.2)
- ✅ Had architecture-strategist review State Manager spec (score: 9/10)
- ✅ Implemented all critical fixes for State Manager:
  - Added defensive stream checks for graceful failure
  - Documented restart behavior and subscriber re-subscription patterns
  - Added graceful pub-sub broadcast failure handling
  - Completed comprehensive event validation for all event types
- ✅ Created Pod Workspace Manager spec (2.4) - comprehensive specification complete
- ✅ Had architecture-strategist review Workspace Manager spec
- ✅ Fixed all critical issues (P0) in Workspace Manager spec:
  - Implemented event-sourced state management with explicit replay logic
  - Enhanced path validation security (symlink detection, traversal prevention)
  - Added graceful shutdown with terminate/2 callback
- ✅ Applied major architectural clarification to Workspace Manager:
  - Clarified primary role: thin wrapper around external `aw` CLI tool
  - Documented `aw create`, `aw destroy`, `aw list` integration patterns
  - Explained agent execution model: agents work in workspace via Claude Code SDK with cwd parameter
  - Clarified file operations (read_file/write_file) are optional utilities, NOT used by agents
  - Added comprehensive `aw` CLI integration section with error handling
  - Updated all sections to reflect `aw` CLI as primary interface
- ✅ Created Pod External Sync spec (2.5) - comprehensive GitHub/JIRA integration spec
- ✅ Had architecture-strategist review External Sync spec (score: 8.5/10)
- ✅ Implemented all 5 critical fixes for External Sync:
  - Event logging in terminate/2 for cancelled operations audit trail
  - Task.start_link for queue processing to prevent orphaned operations
  - Comprehensive idempotency checks for GitHub PR and JIRA ticket creation
  - Adaptive polling that adjusts interval from 1-30 minutes based on rate limits
  - Duplicate event prevention via tracking seen comment IDs and state changes
- Ready to begin implementation: Components 1.1, 2.1, 2.2, 2.4, 2.5 specs are all approved

**2025-11-06**: Pod LiveView UI spec completion
- ✅ Reviewed existing Pod LiveView UI spec (2.6) - comprehensive real-time UI specification
- ✅ Had architecture-strategist review LiveView spec
- ✅ Implemented all 4 critical fixes for LiveView:
  - Added `list_files/2` API to Workspace Manager spec (2.4) for file tree browsing
  - Fixed file selection error handling to match WorkspaceManager API (`:file_not_found`, `:workspace_not_found`)
  - Removed dependency warning for missing `list_files/2` API
  - Fixed agent log test to use separate pub-sub stream instead of event store append
- ✅ Updated all error handling sections to match component APIs
- Ready to begin implementation: Components 1.1, 2.1, 2.2, 2.4, 2.5, 2.6 specs are all approved

**2025-11-06 (afternoon)**: Major Architecture Refactor - Phase 1
- ✅ Introduced Workstreams concept for parallel work execution
- ✅ Introduced Communications Manager for human-agent/agent-agent coordination
- ✅ Introduced CLAUDE.md Template System for multi-level contextual instructions
- ✅ Updated overview spec (specs/00_overview.md) with new architecture
- ✅ Updated CLAUDE.md with new concepts (workstreams, communications, templates)
- ✅ Created placeholder specs for new components:
  - 2.7 Pod Communications Manager
  - 2.8 CLAUDE.md Template System
- ✅ Updated STATUS.md with architecture refactor tracking
- ✅ Updated dependency graph (specs/01_dependency_graph.md) with new components and dependencies
- Impact: Timeline extended from ~7 weeks to ~15 weeks due to significant complexity increase

**2025-11-06 (evening)**: Architecture Refactor - Phase 2 Complete
- ✅ Created Component 2.8 spec (CLAUDE.md Template System) - 716 lines, COMPLETE
  - Multi-level template hierarchy (system, pod, workstream)
  - EEx template rendering with context injection
  - Integration with Pod State Manager for context data
  - Workspace Manager integration for template injection
- ✅ Created Component 2.7 spec (Pod Communications Manager) - 981 lines, COMPLETE
  - Structured messaging system (questions, approvals, updates, blockers)
  - Threading model for organized conversations
  - Inbox/notification management with read tracking
  - Approval workflows with blocking operations
  - Real-time pub-sub broadcasting
- ✅ Created Component 2.2 refactor plan (Pod State Manager) - REFACTOR_PLAN.md
  - Add workstream state projections (status, dependencies, agents)
  - Add message and inbox state projections
  - New event types and API functions
  - Additional effort: +1 week
- ✅ Created Component 2.3 refactor plan (Pod Scheduler) - REFACTOR_PLAN.md
  - Transform from state machine to orchestration engine (MOST COMPLEX UPDATE)
  - Planning phase with dynamic workstream creation
  - Concurrent workstream execution with dependency management
  - CLAUDE.md generation integration (via 2.8)
  - Communications integration (via 2.7)
  - Complete rewrite of evaluation logic
  - Additional effort: +3 weeks
- ✅ Created Component 2.6 refactor plan (Pod LiveView UI) - REFACTOR_PLAN.md
  - Add tab navigation (Overview, Workstreams, Communications, External)
  - New Workstreams tab with dependency visualization
  - New Communications tab with inbox, threads, and approvals
  - Update agent monitor to group by workstream
  - Real-time communications integration
  - Additional effort: +1.5 weeks
- **ALL REFACTOR PLANNING COMPLETE**: Ready for spec updates and architecture review

## Next Actions

### Phase 1: Spec Updates (In Progress)

**✅ COMPLETED:**
1. ✅ Update dependency graph (specs/01_dependency_graph.md) - DONE
2. ✅ Create Component 2.7 spec (Communications Manager) - DONE (981 lines)
3. ✅ Create Component 2.8 spec (CLAUDE.md Templates) - DONE (716 lines)
4. ✅ Create refactor plans for 2.2, 2.3, 2.6 - DONE

**📋 REMAINING:**

1. **Apply refactor plans to actual specs** - 3 major updates:
   - **2.2 Pod State Manager**: Update full spec with workstream/message projections (using REFACTOR_PLAN.md)
   - **2.3 Pod Scheduler**: Rewrite full spec as orchestration engine (using REFACTOR_PLAN.md)
   - **2.6 Pod LiveView UI**: Update full spec with new tabs (using REFACTOR_PLAN.md)

2. **Minor spec updates** - 5 components need small updates:
   - 1.1 SQLite Event Store: Document single stream model (add section)
   - 2.4 Pod Workspace Manager: Add CLAUDE.md injection to create_workspace (minor API update)
   - 2.5 Pod External Sync: Add workstream reporting to GitHub/JIRA sync
   - 3.1 Central Task Manager: Create spec (document pod lifecycle)
   - 3.2 Central Dashboard UI: Create spec (add message counts)

### Phase 2: Architecture Review

3. **Get architecture review** for ALL refactored/new specs:
   - 2.2 Pod State Manager (refactored)
   - 2.3 Pod Scheduler (refactored)
   - 2.6 Pod LiveView UI (refactored)
   - 2.7 Communications Manager (new)
   - 2.8 CLAUDE.md Templates (new)

### Phase 3: Implementation

4. **Initialize Phoenix project** - Set up basic app structure
5. **Install `aw` CLI tool** - Required for workspace management
6. **Begin implementation** - Start with Stream A:
   - Week 1: Component 1.1 (SQLite Event Store)
   - Week 2: Component 2.1 (Pod Supervisor)
   - Week 3-4: Component 2.2 (Pod State Manager with refactored projections)
   - Week 5-7: Component 2.7 (Communications Manager)
   - Week 8: Component 2.8 (CLAUDE.md Templates)
   - Week 9-12: Component 2.3 (Pod Scheduler - orchestration engine)

## Team Notes

### Development Approach
- Spec-driven: Write spec → Review → Approve → Code → Test → PR → Merge
- Update this STATUS.md as work progresses
- Each component gets its own folder: `specs/{component}/`
  - `spec.md` - Detailed specification
  - `tracker.md` - Component-specific todos and logs
  - `review.md` - Review findings and issues

### Communication
- Use GitHub issues for major decisions
- Use PR comments for code review
- Update STATUS.md weekly or after major milestones
