# IPA Component Dependency Graph

**Last Updated**: 2025-11-06 (Architecture Refactor)

## Visual Dependency Graph

```
                    ┌─────────────────────────────────┐
                    │  1.1 SQLite Event Store         │
                    │  (Single stream per task)       │
                    │                                 │
                    └───────────────┬─────────────────┘
                                    │
                    ┏━━━━━━━━━━━━━━━┻━━━━━━━━━━━━━━━┓
                    ┃         REQUIRED FIRST         ┃
                    ┗━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━┛
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
        ▼                           ▼                           ▼
┌───────────────┐         ┌──────────────────┐      ┌──────────────────┐
│  2.1 Task Pod │         │  3.1 Central     │      │  (External)      │
│  Supervisor   │         │  Task Manager    │      │  Dependency:     │
└───────┬───────┘         └────────┬─────────┘      │  Claude Code SDK │
        │                          │                └──────────────────┘
        │                          │
        ├──────────────┬───────────┼───────────┬
        │              │           │           │
        ▼              ▼           ▼           ▼
┌───────────────┐  ┌──────────┐  ┌──────────────────┐
│  2.2 Pod      │  │  2.4 Pod │  │  3.2 Central     │
│  State        │  │  Workspace│  │  Dashboard UI    │
│  Manager      │  │  Manager │  └──────────────────┘
└───┬───────────┘  └─────┬────┘
    │                    │
    │                    │
    ├────────┬───────────┴──┬──────────────┬──────────┐
    │        │              │              │          │
    ▼        ▼              ▼              ▼          ▼
┌────────┐  ┌────────────┐ ┌──────────┐ ┌─────────┐ ┌─────────┐
│  2.5   │  │  2.7 Comms │ │  2.8     │ │  2.6    │ │  2.6    │
│  Ext.  │  │  Manager   │ │  CLAUDE  │ │  Pod UI │ │  Pod UI │
│  Sync  │  │  (NEW)     │ │  .md     │ │ (needs  │ │ (needs  │
│        │  │            │ │  (NEW)   │ │  2.7)   │ │  2.7)   │
└────────┘  └──────┬─────┘ └─────┬────┘ └─────────┘ └─────────┘
                   │              │
                   └──────┬───────┘
                          │
                          ▼
                   ┌──────────────┐
                   │  2.3 Pod     │
                   │  Scheduler   │
                   │  (needs 2.2, │
                   │   2.4, 2.7,  │
                   │   2.8)       │
                   └──────────────┘
```

## Dependency Matrix

| Component | Depends On | Blocks |
|-----------|-----------|--------|
| 1.1 SQLite Event Store | None | 2.1, 2.2, 3.1 |
| 2.1 Task Pod Supervisor | 1.1 | 2.2, 2.4, 2.5, 2.6, 2.7, 3.1 |
| 2.2 Pod State Manager | 1.1, 2.1 | 2.3, 2.5, 2.6, 2.7, 2.8 |
| 2.3 Pod Scheduler | 1.1, 2.1, 2.2, 2.4, 2.7, 2.8 | None |
| 2.4 Pod Workspace Manager | 2.1 | 2.3 |
| 2.5 Pod External Sync | 1.1, 2.1, 2.2 | None |
| 2.6 Pod LiveView UI | 1.1, 2.1, 2.2, 2.7 | None |
| 2.7 Pod Communications Manager | 1.1, 2.1, 2.2 | 2.3, 2.6 |
| 2.8 CLAUDE.md Templates | 2.2 | 2.3 |
| 3.1 Central Task Manager | 1.1, 2.1 | 3.2 |
| 3.2 Central Dashboard UI | 3.1 | None |

## Critical Path

The critical path (longest dependency chain) determines minimum project duration:

```
1.1 SQLite Event Store (1 week)
  → 2.1 Pod Supervisor (2 days)
    → 2.2 Pod State Manager (1.5 weeks)
      → 2.7 Communications Manager (2.5 weeks)
        → 2.3 Pod Scheduler (3 weeks)
```

**Alternative Critical Path (if 2.8 takes longer than 2.7):**
```
1.1 → 2.1 → 2.2 → 2.8 CLAUDE.md Templates (1 week) → 2.3 (3 weeks)
```

**Total Critical Path: ~9-10 weeks**

This is significantly longer than the original ~3 week estimate due to:
- New components (2.7, 2.8)
- Increased complexity in 2.2 (workstream/message projections)
- Massive increase in 2.3 complexity (orchestration engine)

## Parallelization Opportunities

### Phase 1: Foundation (Week 1)
**Sequential - Must be done first:**
- 1.1 SQLite Event Store (1 week)

### Phase 2: Pod Core (Weeks 2-3)
**Sequential:**
- 2.1 Task Pod Supervisor (2 days)
- 2.2 Pod State Manager (1.5 weeks) - includes workstream/message projections

**Parallel (after 2.1):**
- 2.4 Pod Workspace Manager (3-4 days)

### Phase 3: Pod Communications & Templates (Weeks 3-6)
**Parallel (after 2.2):**
- 2.7 Pod Communications Manager (2.5 weeks) - **NEW**
- 2.8 CLAUDE.md Templates (1 week) - **NEW**
- 2.5 Pod External Sync (1.5 weeks)
- 3.1 Central Task Manager (2-3 days)

**Parallel (after 2.7):**
- 2.6 Pod LiveView UI (2 weeks) - includes workstreams & comms tabs

### Phase 4: Pod Scheduler (Weeks 6-9)
**Sequential (after 2.2 + 2.4 + 2.7 + 2.8):**
- 2.3 Pod Scheduler (3 weeks) - **Orchestration engine, most complex component**

### Phase 5: Central UI (Week 9)
**Parallel (after 3.1):**
- 3.2 Central Dashboard UI (2-3 days)

## Development Streams (Parallelized)

### Stream A: Foundation → Pod Core → Central Management
**Owner**: Primary developer (critical path)
```
Week 1:    1.1 SQLite Event Store
Week 2:    2.1 Pod Supervisor (2 days) → 2.2 Pod State Manager (start)
Week 3:    2.2 Pod State Manager (complete)
Week 4-5:  Wait for 2.7, 2.8 OR work on 3.1 Central Manager
Week 6-8:  2.3 Pod Scheduler (orchestration engine)
Week 9:    Testing & integration
```

### Stream B: Pod Workspace + Templates (parallel with A after Week 2)
**Owner**: Developer 2
```
Week 2:    2.4 Pod Workspace Manager (3-4 days)
Week 3:    2.8 CLAUDE.md Templates (1 week)
Week 4-5:  Help with testing, documentation, or other components
```

### Stream C: Pod Communications (parallel after Week 3)
**Owner**: Developer 3
```
Week 3-6:  2.7 Pod Communications Manager (2.5 weeks)
Week 6-7:  Testing & integration
```

### Stream D: Pod UI (parallel after Week 6)
**Owner**: Developer 4
```
Week 6-8:  2.6 Pod LiveView UI (2 weeks with workstreams & comms tabs)
Week 8-9:  Testing & integration
```

### Stream E: External Sync (parallel after Week 3)
**Owner**: Developer 5
```
Week 3-5:  2.5 Pod External Sync (1.5 weeks)
Week 5-6:  Testing & integration
Week 6-9:  Support other streams
```

### Stream F: Central Management (parallel after Week 3)
**Owner**: Developer 6 (or primary developer during waits)
```
Week 4:    3.1 Central Task Manager (2-3 days)
Week 4:    3.2 Central Dashboard UI (2-3 days)
Week 5-9:  Testing, documentation, support
```

## Estimated Timeline by Team Size

### Single Developer (Sequential)
```
Week 1:    1.1 Event Store
Week 2:    2.1 Pod Supervisor + 2.2 Pod State Manager (start)
Week 3:    2.2 Pod State Manager (complete)
Week 4:    2.4 Workspace Manager + 2.8 Templates
Week 5-7:  2.7 Communications Manager
Week 8-10: 2.3 Pod Scheduler
Week 11-12: 2.6 Pod LiveView UI
Week 13:   2.5 External Sync + 3.1 Central Manager
Week 14:   3.2 Central Dashboard
Week 15:   Testing & integration

Total: ~15 weeks
```

### Team of 3-4 Developers (Parallelized)
```
Week 1:    1.1 Event Store (sequential)
Week 2-3:  2.1 + 2.2 (sequential)
Week 3-6:  Parallel work (2.4, 2.7, 2.8, 2.5, 3.1, 3.2)
Week 6-9:  2.3 Scheduler (sequential) + 2.6 UI (parallel)
Week 9-10: Testing & integration

Total: ~10 weeks
```

### Team of 6+ Developers (Maximum Parallelization)
```
Week 1:    1.1 Event Store (sequential)
Week 2-3:  2.1 + 2.2 (sequential)
Week 3-6:  Heavy parallel work (all parallel components)
Week 6-9:  2.3 Scheduler + 2.6 UI (parallel)
Week 9:    Testing & integration

Total: ~9 weeks
```

## Inter-Component Communication

### Layer 1 → Layer 2
- **Interface**: SQLite Event Store module (`Ipa.EventStore`)
- **Direction**: Layer 2 reads/writes via EventStore functions
- **Contract**: Event schema (JSON) + state projection schema
- **Change**: Now single stream per task (includes workstream/message events)
- **Testing**: Mock EventStore or use in-memory SQLite for tests

### Within Layer 2 (Pod-Internal)
- **Interface**: Pod-local pub-sub (`pod:{task_id}:state`)
- **Direction**: State Manager publishes, others subscribe
- **Contract**: `{:state_updated, state}` messages
- **Change**: State now includes workstreams, messages, inbox
- **Testing**: Use Phoenix.PubSub test helpers

### Layer 2 Communications (NEW)
- **Interface**: Communications Manager API
- **Direction**: Scheduler, Agents, LiveView call Communications Manager
- **Contract**: `post_message/2`, `request_approval/2`, `get_inbox/1`
- **Testing**: Mock message posting, test approval workflows

### Layer 2 Templates (NEW)
- **Interface**: CLAUDE.md Template System
- **Direction**: Scheduler generates templates, WorkspaceManager injects them
- **Contract**: `generate_workstream_level/3`, `generate_pod_level/2`
- **Testing**: Test template rendering and context injection

### Layer 3 → Layer 2
- **Interface**: Pod Supervisor start/stop
- **Direction**: Central Manager controls Pod lifecycle
- **Contract**: `start_pod(task_id)` / `stop_pod(task_id)`
- **Testing**: Test pod lifecycle in isolation

## External Dependencies

### Required External Libraries
- **phoenix** (~> 1.7) - Web framework
- **phoenix_live_view** (~> 0.20) - Real-time UI
- **ecto** (~> 3.11) - Database toolkit
- **ecto_sqlite3** (~> 0.15) - SQLite adapter for Ecto
- **jason** (~> 1.4) - JSON encoding
- **tesla** (~> 1.8) - HTTP client (for GitHub/JIRA)
- **tentacat** or **github_api** - GitHub client library
- **jira_client** - JIRA REST API client
- **uuid** (~> 1.1) - UUID generation for workstreams, messages

### Claude Code SDK
- **Package**: `claude_code` (https://hexdocs.pm/claude_code/)
- **Usage**: Pod Scheduler spawns agents per workstream
- **Integration Point**: Component 2.3
- **Risk**: External service availability

## Risk Assessment

### High Risk Dependencies
1. **Claude Code SDK** - External service dependency
   - **Mitigation**: Design scheduler to handle agent failures gracefully
   - **Impact**: Critical for multi-agent workstream execution

2. **Pod Scheduler Complexity** - Most complex component (3 weeks)
   - **Mitigation**: Thorough spec review, incremental development, extensive testing
   - **Impact**: Blocking many other features

### Medium Risk Dependencies
1. **Phoenix LiveView** - Complex state synchronization
   - **Mitigation**: Keep LiveView stateless, source of truth is Pod State
   - **Note**: Now more complex with workstreams and communications tabs

2. **Communications Manager** - New complex component (2.5 weeks)
   - **Mitigation**: Clear API design, comprehensive testing
   - **Impact**: Required for human-agent coordination

### Low Risk Dependencies
1. **SQLite** - Mature, battle-tested, single-file database
2. **Ecto** - Well-established Elixir database toolkit
3. **Phoenix** - Stable, mature web framework
4. **CLAUDE.md Templates** - Simple template rendering
5. **Workspace Manager** - Thin wrapper around `aw` CLI

## Build Order Recommendation

### For Single Developer (Sequential)

**Weeks 1-3: Foundation & Pod Core**
1. **Week 1**: Component 1.1 (SQLite Event Store)
2. **Week 2**: Component 2.1 (Pod Supervisor - 2 days)
3. **Week 2-3**: Component 2.2 (Pod State Manager - 1.5 weeks)

**Weeks 4-7: Pod Infrastructure**
4. **Week 4**: Component 2.4 (Pod Workspace Manager - 3-4 days)
5. **Week 4**: Component 2.8 (CLAUDE.md Templates - 1 week)
6. **Week 5-7**: Component 2.7 (Pod Communications Manager - 2.5 weeks)

**Weeks 8-10: Pod Scheduler (Critical)**
7. **Week 8-10**: Component 2.3 (Pod Scheduler - 3 weeks)

**Weeks 11-13: UI & Integrations**
8. **Week 11-12**: Component 2.6 (Pod LiveView UI - 2 weeks)
9. **Week 13**: Component 2.5 (Pod External Sync - 1.5 weeks)
10. **Week 13**: Component 3.1 (Central Task Manager - 2-3 days)

**Week 14: Final UI**
11. **Week 14**: Component 3.2 (Central Dashboard UI - 2-3 days)

**Week 15: Testing & Integration**
12. End-to-end testing, bug fixes, documentation

**Total: ~15 weeks**

### For Team of 3-4 Developers (Recommended)

Assign developers to streams A-D:
- **Dev 1**: Stream A (critical path: 1.1 → 2.1 → 2.2 → 2.3)
- **Dev 2**: Stream B (parallel: 2.4 → 2.8, then help elsewhere)
- **Dev 3**: Stream C (parallel: 2.7, most complex parallel component)
- **Dev 4**: Stream D + E (parallel: 2.6 after 2.7, plus 2.5, 3.1, 3.2)

**Total: ~10 weeks** with proper parallelization

## Key Changes from Original Plan

1. **New Components**: Added 2.7 (Communications) and 2.8 (CLAUDE.md Templates)
2. **Updated Dependencies**: 2.3 now depends on 2.7 and 2.8, 2.6 depends on 2.7
3. **Increased Complexity**:
   - 2.2 Pod State Manager: +1 week (workstream/message projections)
   - 2.3 Pod Scheduler: +3 weeks (from 1 week to 3 weeks - orchestration engine)
   - 2.6 Pod LiveView UI: +1.5 weeks (workstreams & communications tabs)
4. **Timeline**: Extended from ~7 weeks (original) to **~15 weeks** (single dev) or **~10 weeks** (team)
5. **Critical Path**: Extended from ~3 weeks to **~9-10 weeks**
