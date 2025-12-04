defmodule Ipa.Agent.MdFileTest do
  use ExUnit.Case, async: true

  alias Ipa.Agent.MdFile

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp build_test_state(opts \\ []) do
    workstream_id = opts[:workstream_id] || "ws-1"

    workstream = %{
      workstream_id: workstream_id,
      title: opts[:workstream_title] || "Test Workstream",
      spec: opts[:workstream_spec] || "Test workstream specification",
      status: opts[:workstream_status] || :pending,
      dependencies: opts[:dependencies] || []
    }

    related_workstreams =
      opts[:related_workstreams] ||
        if opts[:include_related] do
          %{
            "ws-2" => %{
              workstream_id: "ws-2",
              title: "Related Workstream",
              spec: "Related spec",
              status: :pending,
              dependencies: [workstream_id]
            }
          }
        else
          %{}
        end

    %{
      task_id: opts[:task_id] || "task-123",
      title: opts[:task_title] || "Test Task",
      spec: opts[:task_spec] || %{content: "Test task specification content"},
      phase: opts[:phase] || :workstream_execution,
      workstreams: Map.put(related_workstreams, workstream_id, workstream),
      tracker: opts[:tracker] || nil
    }
  end

  defp build_tracker_with_items(workstream_id) do
    %{
      phases: [
        %{
          name: "Implementation",
          items: [
            %{
              item_id: "item-1",
              workstream_id: workstream_id,
              summary: "Implement feature A",
              status: :todo
            },
            %{
              item_id: "item-2",
              workstream_id: workstream_id,
              summary: "Test feature A",
              status: :wip
            }
          ]
        }
      ]
    }
  end

  # ============================================================================
  # available_blocks/0 Tests
  # ============================================================================

  describe "available_blocks/0" do
    test "returns list of block IDs" do
      blocks = MdFile.available_blocks()
      assert is_list(blocks)
      assert :workspace_rules in blocks
      assert :workstream_spec in blocks
      assert :dependencies in blocks
      assert :tracker_items in blocks
      assert :task_context in blocks
      assert :code_guidelines in blocks
      assert :git_workflow in blocks
      assert :planning_instructions in blocks
    end
  end

  # ============================================================================
  # get_template/1 Tests
  # ============================================================================

  describe "get_template/1" do
    test "returns EEx template for workspace_rules" do
      template = MdFile.get_template(:workspace_rules)
      assert is_binary(template)
      assert String.contains?(template, "Workspace Rules")
      assert String.contains?(template, "NEVER write to `/tmp/`")
      assert String.contains?(template, "CRITICAL")
    end

    test "returns EEx template for workstream_spec with EEx syntax" do
      template = MdFile.get_template(:workstream_spec)
      assert String.contains?(template, "<%= @workstream_id %>")
      assert String.contains?(template, "<%= @workstream_spec %>")
      assert String.contains?(template, "<%= @workstream_status %>")
    end

    test "returns EEx template for dependencies with conditionals" do
      template = MdFile.get_template(:dependencies)
      assert String.contains?(template, "<%= if @dependencies")
      assert String.contains?(template, "<%= for dep_id <- @dependencies")
    end

    test "returns EEx template for tracker_items with conditionals" do
      template = MdFile.get_template(:tracker_items)
      assert String.contains?(template, "<%= if @tracker_items")
      assert String.contains?(template, "<%= for item <- @tracker_items")
      assert String.contains?(template, "tracker_update.json")
    end

    test "returns EEx template for code_guidelines" do
      template = MdFile.get_template(:code_guidelines)
      assert String.contains?(template, "Code Guidelines")
      assert String.contains?(template, "pattern matching")
    end

    test "returns empty string for unknown block" do
      assert MdFile.get_template(:unknown_block) == ""
    end
  end

  # ============================================================================
  # render/2 Tests
  # ============================================================================

  describe "render/2" do
    test "renders workstream_spec block with context" do
      context = %{
        workstream_id: "ws-1",
        workstream_spec: "Build the auth module",
        workstream_status: :pending
      }

      content = MdFile.render(:workstream_spec, context)
      assert String.contains?(content, "ws-1")
      assert String.contains?(content, "Build the auth module")
      assert String.contains?(content, "pending")
      refute String.contains?(content, "<%= @")
    end

    test "renders dependencies block with no dependencies" do
      context = %{dependencies: []}
      content = MdFile.render(:dependencies, context)
      assert String.contains?(content, "no dependencies")
      assert String.contains?(content, "can start immediately")
    end

    test "renders dependencies block with dependencies" do
      context = %{dependencies: ["ws-0", "ws-prep"]}
      content = MdFile.render(:dependencies, context)
      assert String.contains?(content, "ws-0")
      assert String.contains?(content, "ws-prep")
      assert String.contains?(content, "Do not start work until")
    end

    test "renders tracker_items block when items exist" do
      context = %{
        tracker_items: [
          %{item_id: "item-1", phase_name: "Setup", summary: "Create project", status: :todo}
        ]
      }

      content = MdFile.render(:tracker_items, context)
      assert String.contains?(content, "Tracker Items")
      assert String.contains?(content, "item-1")
      assert String.contains?(content, "Create project")
      assert String.contains?(content, "Setup")
    end

    test "renders empty string for tracker_items when no items" do
      context = %{tracker_items: []}
      content = MdFile.render(:tracker_items, context)
      # Should be empty or nearly empty (just whitespace from EEx)
      assert String.trim(content) == ""
    end

    test "renders with blank values for missing context variables" do
      # EEx renders missing assigns as blank/nil (with warnings)
      # This is expected behavior, not an error
      content = MdFile.render(:workstream_spec, %{})
      # Template is rendered but values are empty
      assert String.contains?(content, "Workstream Context")
      assert String.contains?(content, "Workstream ID")
    end
  end

  # ============================================================================
  # compose/2 Tests
  # ============================================================================

  describe "compose/2" do
    test "composes multiple blocks" do
      context = %{
        task_id: "task-123",
        task_title: "My Task",
        task_spec: "Build something",
        task_phase: :planning,
        repo_url: "git@github.com:test/repo.git",
        branch: "main",
        show_repo_info: true
      }

      content = MdFile.compose([:task_context, :code_guidelines], context)
      assert String.contains?(content, "My Task")
      assert String.contains?(content, "Code Guidelines")
    end

    test "skips blocks that fail to render" do
      # workstream_spec needs workstream context, task_context doesn't
      context = %{
        task_title: "My Task",
        task_spec: "Build something",
        task_phase: :planning,
        repo_url: "git@github.com:test/repo.git",
        branch: "main",
        show_repo_info: false
      }

      # Should still work even if workstream_spec fails
      content = MdFile.compose([:workstream_spec, :task_context], context)
      assert String.contains?(content, "My Task")
    end
  end

  # ============================================================================
  # for_workstream/3 Tests
  # ============================================================================

  describe "for_workstream/3" do
    test "generates full CLAUDE.md content for workstream" do
      state = build_test_state()
      {:ok, content} = MdFile.for_workstream(state, "ws-1")

      # Should have workstream spec
      assert String.contains?(content, "ws-1")
      assert String.contains?(content, "Test workstream specification")

      # Should have dependencies section
      assert String.contains?(content, "Dependencies")

      # Should have task context
      assert String.contains?(content, "Test Task")

      # Should have workflow instructions
      assert String.contains?(content, "Your Role")
      assert String.contains?(content, "primary agent")

      # Should have success criteria
      assert String.contains?(content, "Success Criteria")
    end

    test "includes tracker items when present" do
      state = build_test_state(tracker: build_tracker_with_items("ws-1"))
      {:ok, content} = MdFile.for_workstream(state, "ws-1")

      assert String.contains?(content, "Tracker Items")
      assert String.contains?(content, "Implement feature A")
      assert String.contains?(content, "Test feature A")
      assert String.contains?(content, "item-1")
      assert String.contains?(content, "item-2")
    end

    test "includes related workstreams" do
      state = build_test_state(include_related: true)
      {:ok, content} = MdFile.for_workstream(state, "ws-1")

      assert String.contains?(content, "Related Workstreams")
      assert String.contains?(content, "ws-2")
    end

    test "includes dependent workstreams" do
      state = build_test_state(include_related: true)
      {:ok, content} = MdFile.for_workstream(state, "ws-1")

      # ws-2 depends on ws-1, so it should be in dependent workstreams
      assert String.contains?(content, "Dependent Workstreams")
      assert String.contains?(content, "waiting for your completion")
    end

    test "shows dependencies when workstream has them" do
      state = build_test_state(dependencies: ["ws-0", "ws-prep"])
      {:ok, content} = MdFile.for_workstream(state, "ws-1")

      assert String.contains?(content, "ws-0")
      assert String.contains?(content, "ws-prep")
      assert String.contains?(content, "Do not start work until")
    end

    test "returns error for non-existent workstream" do
      state = build_test_state()
      assert {:error, :workstream_not_found} = MdFile.for_workstream(state, "ws-nonexistent")
    end
  end

  # ============================================================================
  # for_planning/2 Tests
  # ============================================================================

  describe "for_planning/2" do
    test "generates CLAUDE.md content for planning agent" do
      state = build_test_state()
      {:ok, content} = MdFile.for_planning(state)

      # Should have workspace rules
      assert String.contains?(content, "Workspace Rules")
      assert String.contains?(content, "NEVER write to `/tmp/`")

      # Should have task context
      assert String.contains?(content, "Test Task")

      # Should have planning instructions
      assert String.contains?(content, "Planning Instructions")
      assert String.contains?(content, "breaking down tasks")

      # Should have code guidelines
      assert String.contains?(content, "Code Guidelines")
    end
  end

  # ============================================================================
  # for_spec_generator/2 Tests
  # ============================================================================

  describe "for_spec_generator/2" do
    test "generates minimal CLAUDE.md for spec generator" do
      state = build_test_state()
      {:ok, content} = MdFile.for_spec_generator(state)

      # Should have workspace rules
      assert String.contains?(content, "Workspace Rules")

      # Should have task context
      assert String.contains?(content, "Test Task")

      # Should NOT have planning instructions or code guidelines
      refute String.contains?(content, "Planning Instructions")
      refute String.contains?(content, "Code Guidelines")
    end
  end

  # ============================================================================
  # build_workstream_context/3 Tests
  # ============================================================================

  describe "build_workstream_context/3" do
    test "builds complete context map" do
      state = build_test_state(include_related: true, tracker: build_tracker_with_items("ws-1"))
      {:ok, workstream} = Map.fetch(state.workstreams, "ws-1")
      context = MdFile.build_workstream_context(state, workstream, [])

      assert context.task_id == "task-123"
      assert context.task_title == "Test Task"
      assert context.workstream_id == "ws-1"
      assert context.workstream_spec == "Test workstream specification"
      assert context.dependencies == []
      assert length(context.related_workstreams) == 1
      assert length(context.dependent_workstreams) == 1
      assert length(context.tracker_items) == 2
    end

    test "allows overriding options" do
      state = build_test_state()
      {:ok, workstream} = Map.fetch(state.workstreams, "ws-1")

      context =
        MdFile.build_workstream_context(state, workstream,
          workstream_spec: "Custom spec",
          dependencies: ["custom-dep"],
          repo_url: "custom-repo",
          branch: "custom-branch"
        )

      assert context.workstream_spec == "Custom spec"
      assert context.dependencies == ["custom-dep"]
      assert context.repo_url == "custom-repo"
      assert context.branch == "custom-branch"
    end
  end
end
