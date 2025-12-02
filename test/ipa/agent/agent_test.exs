defmodule Ipa.AgentTest do
  @moduledoc """
  Tests for the Ipa.Agent module - the common agent behaviour and API.
  """

  use ExUnit.Case, async: true

  alias Ipa.Agent
  alias Ipa.Agent.Types.{Planning, Workstream, PrConsolidation, PrCommentResolver}

  describe "agent type modules" do
    test "Planning module implements Agent behaviour" do
      # Ensure module is loaded before checking exported functions
      Code.ensure_loaded!(Planning)
      assert function_exported?(Planning, :agent_type, 0)
      assert function_exported?(Planning, :generate_prompt, 1)
      assert function_exported?(Planning, :configure_options, 1)
      assert function_exported?(Planning, :handle_completion, 2)
      assert function_exported?(Planning, :handle_tool_call, 3)
    end

    test "Workstream module implements Agent behaviour" do
      # Ensure module is loaded before checking exported functions
      Code.ensure_loaded!(Workstream)
      assert function_exported?(Workstream, :agent_type, 0)
      assert function_exported?(Workstream, :generate_prompt, 1)
      assert function_exported?(Workstream, :configure_options, 1)
      assert function_exported?(Workstream, :handle_completion, 2)
      assert function_exported?(Workstream, :handle_tool_call, 3)
    end

    test "PrConsolidation module implements Agent behaviour" do
      # Ensure module is loaded before checking exported functions
      Code.ensure_loaded!(PrConsolidation)
      assert function_exported?(PrConsolidation, :agent_type, 0)
      assert function_exported?(PrConsolidation, :generate_prompt, 1)
      assert function_exported?(PrConsolidation, :configure_options, 1)
      assert function_exported?(PrConsolidation, :handle_completion, 2)
      assert function_exported?(PrConsolidation, :handle_tool_call, 3)
    end

    test "PrCommentResolver module implements Agent behaviour" do
      # Ensure module is loaded before checking exported functions
      Code.ensure_loaded!(PrCommentResolver)
      assert function_exported?(PrCommentResolver, :agent_type, 0)
      assert function_exported?(PrCommentResolver, :generate_prompt, 1)
      assert function_exported?(PrCommentResolver, :configure_options, 1)
      assert function_exported?(PrCommentResolver, :handle_completion, 2)
      assert function_exported?(PrCommentResolver, :handle_tool_call, 3)
    end
  end

  describe "agent_type/0" do
    test "Planning returns :planning_agent" do
      assert Planning.agent_type() == :planning_agent
    end

    test "Workstream returns :workstream" do
      assert Workstream.agent_type() == :workstream
    end

    test "PrConsolidation returns :pr_consolidation" do
      assert PrConsolidation.agent_type() == :pr_consolidation
    end

    test "PrCommentResolver returns :pr_comment_resolver" do
      assert PrCommentResolver.agent_type() == :pr_comment_resolver
    end
  end

  describe "generate_prompt/1" do
    test "Planning generates prompt with task context" do
      context = %{
        task: %{
          title: "Test Task",
          spec: %{description: "Build a REST API"}
        }
      }

      prompt = Planning.generate_prompt(context)

      assert is_binary(prompt)
      assert prompt =~ "Test Task"
      assert prompt =~ "Build a REST API"
      assert prompt =~ "workstreams"
      assert prompt =~ "output.json"
    end

    test "Planning handles missing spec gracefully" do
      context = %{
        task: %{
          title: "Test Task",
          spec: %{}
        }
      }

      prompt = Planning.generate_prompt(context)
      assert is_binary(prompt)
      assert prompt =~ "No spec description provided"
    end

    test "Workstream generates prompt with workstream context" do
      context = %{
        task: %{title: "Main Task"},
        workstream: %{
          workstream_id: "ws-1",
          spec: "Implement authentication",
          dependencies: ["ws-0"]
        },
        workstream_id: "ws-1"
      }

      prompt = Workstream.generate_prompt(context)

      assert is_binary(prompt)
      assert prompt =~ "ws-1"
      assert prompt =~ "Implement authentication"
      assert prompt =~ "ws-0"
      assert prompt =~ "WORKSTREAM_COMPLETE.md"
    end

    test "Workstream handles empty dependencies" do
      context = %{
        task: %{title: "Main Task"},
        workstream: %{
          workstream_id: "ws-1",
          spec: "First workstream",
          dependencies: []
        },
        workstream_id: "ws-1"
      }

      prompt = Workstream.generate_prompt(context)
      assert prompt =~ "start immediately"
    end

    test "PrConsolidation generates prompt with workstream summaries" do
      context = %{
        task: %{
          title: "Main Task",
          workstreams: %{
            "ws-1" => %{
              workstream_id: "ws-1",
              title: "Auth Implementation",
              spec: "Build auth system",
              status: :completed
            },
            "ws-2" => %{
              workstream_id: "ws-2",
              title: "API Endpoints",
              spec: "Build REST endpoints",
              status: :completed
            }
          }
        }
      }

      prompt = PrConsolidation.generate_prompt(context)

      assert is_binary(prompt)
      assert prompt =~ "Auth Implementation"
      assert prompt =~ "API Endpoints"
      assert prompt =~ "gh pr create"
    end

    test "PrCommentResolver generates prompt with PR number" do
      context = %{
        task: %{
          title: "Main Task",
          external_sync: %{
            github: %{
              pr_number: 42
            }
          }
        }
      }

      prompt = PrCommentResolver.generate_prompt(context)

      assert is_binary(prompt)
      assert prompt =~ "#42"
      assert prompt =~ "gh pr view 42"
    end
  end

  describe "configure_options/1" do
    test "Planning returns Ipa.Agent.Options with workspace" do
      context = %{workspace: "/tmp/test-workspace"}

      options = Planning.configure_options(context)

      assert %Ipa.Agent.Options{} = options
      assert options.cwd == "/tmp/test-workspace"
      assert is_list(options.allowed_tools)
      assert "Read" in options.allowed_tools
      assert "Write" in options.allowed_tools
      assert options.max_turns > 0
      assert options.timeout_ms > 0
    end

    test "Workstream returns Ipa.Agent.Options with extended limits" do
      context = %{workspace: "/tmp/ws-workspace"}

      options = Workstream.configure_options(context)

      assert %Ipa.Agent.Options{} = options
      assert options.cwd == "/tmp/ws-workspace"
      assert options.max_turns >= 100
      assert options.timeout_ms >= 3_600_000
    end

    test "PrConsolidation returns Ipa.Agent.Options" do
      context = %{workspace: "/tmp/pr-workspace"}

      options = PrConsolidation.configure_options(context)

      assert %Ipa.Agent.Options{} = options
      assert "Bash" in options.allowed_tools
    end
  end
end
