defmodule Ipa.Test.AgentTestHelpers do
  @moduledoc """
  Test helpers for testing agent modules without live SDK calls.

  This module provides utilities to:
  - Create test fixtures for agent contexts
  - Simulate streaming message sequences
  - Assert on agent events
  - Helper functions for test workspace management

  ## Usage

      import Ipa.Test.AgentTestHelpers

      test "planning agent generates workstreams" do
        context = planning_context(title: "Test Task")
        prompt = Ipa.Agent.Types.Planning.generate_prompt(context)
        assert prompt =~ "Test Task"
      end
  """

  import ExUnit.Assertions

  @doc """
  Creates a simulated SDK message stream from a list of message tuples.

  ## Message Types

  - `{:text, content}` - Text content from assistant
  - `{:tool_use, name, args}` - Tool use start
  - `{:tool_result, result}` - Tool use result
  - `{:thinking, content}` - Extended thinking block
  - `{:error, message}` - Error response

  ## Examples

      messages = simulate_sdk_messages([
        {:text, "Analyzing the codebase..."},
        {:tool_use, "Read", %{"file_path" => "/tmp/test.txt"}},
        {:tool_result, "File contents here"},
        {:text, "Found the main module."}
      ])
  """
  def simulate_sdk_messages(messages) do
    Enum.map(messages, &to_sdk_message/1)
  end

  @doc """
  Creates a context map suitable for planning agents.
  """
  def planning_context(opts \\ []) do
    task_id = Keyword.get(opts, :task_id, "test-task-#{:rand.uniform(10000)}")
    workspace = Keyword.get(opts, :workspace, "/tmp/test-workspace-#{task_id}")

    %{
      task_id: task_id,
      workspace: workspace,
      task: %{
        task_id: task_id,
        title: Keyword.get(opts, :title, "Test Task"),
        spec: %{
          description: Keyword.get(opts, :spec, "Test task specification")
        }
      }
    }
  end

  @doc """
  Creates a context map suitable for workstream agents.
  """
  def workstream_context(opts \\ []) do
    task_id = Keyword.get(opts, :task_id, "test-task-#{:rand.uniform(10000)}")
    workstream_id = Keyword.get(opts, :workstream_id, "ws-#{:rand.uniform(1000)}")
    workspace = Keyword.get(opts, :workspace, "/tmp/test-workspace-#{task_id}-#{workstream_id}")

    %{
      task_id: task_id,
      workstream_id: workstream_id,
      workspace: workspace,
      task: %{
        task_id: task_id,
        title: Keyword.get(opts, :title, "Test Task")
      },
      workstream: %{
        workstream_id: workstream_id,
        spec: Keyword.get(opts, :spec, "Test workstream specification"),
        dependencies: Keyword.get(opts, :dependencies, [])
      }
    }
  end

  @doc """
  Creates a context map suitable for PR consolidation agents.
  """
  def pr_consolidation_context(opts \\ []) do
    task_id = Keyword.get(opts, :task_id, "test-task-#{:rand.uniform(10000)}")
    workspace = Keyword.get(opts, :workspace, "/tmp/test-workspace-#{task_id}-pr")

    completed_workstreams =
      Keyword.get(opts, :completed_workstreams, [
        %{
          workstream_id: "ws-1",
          title: "Test Workstream 1",
          status: :completed,
          spec: "First workstream spec"
        },
        %{
          workstream_id: "ws-2",
          title: "Test Workstream 2",
          status: :completed,
          spec: "Second workstream spec"
        }
      ])

    %{
      task_id: task_id,
      workspace: workspace,
      task: %{
        task_id: task_id,
        title: Keyword.get(opts, :title, "Test Task"),
        workstreams:
          Map.new(completed_workstreams, fn ws -> {ws.workstream_id, ws} end)
      }
    }
  end

  @doc """
  Creates a context map suitable for PR comment resolver agents.
  """
  def pr_comment_resolver_context(opts \\ []) do
    task_id = Keyword.get(opts, :task_id, "test-task-#{:rand.uniform(10000)}")
    workspace = Keyword.get(opts, :workspace, "/tmp/test-workspace-#{task_id}-comments")
    pr_number = Keyword.get(opts, :pr_number, 123)

    %{
      task_id: task_id,
      workspace: workspace,
      task: %{
        task_id: task_id,
        title: Keyword.get(opts, :title, "Test Task"),
        external_sync: %{
          github: %{
            pr_number: pr_number
          }
        }
      }
    }
  end

  @doc """
  Creates a temporary workspace directory for testing.

  Returns the path to the created directory.
  """
  def create_test_workspace(task_id, workstream_id \\ "test") do
    path = Path.join([System.tmp_dir!(), "ipa-test", task_id, workstream_id])
    File.mkdir_p!(path)
    path
  end

  @doc """
  Cleans up a test workspace directory.
  """
  def cleanup_test_workspace(path) do
    File.rm_rf!(path)
  end

  @doc """
  Creates a workstreams_plan.json file in the given workspace.

  Useful for testing planning agent completion handling.
  """
  def create_test_plan_file(workspace, workstreams) do
    plan = %{
      "workstreams" => workstreams
    }

    path = Path.join(workspace, "workstreams_plan.json")
    File.write!(path, Jason.encode!(plan))
    path
  end

  @doc """
  Creates a WORKSTREAM_COMPLETE.md marker file.

  Useful for testing workstream agent completion handling.
  """
  def create_completion_marker(workspace, summary \\ "Work completed successfully") do
    path = Path.join(workspace, "WORKSTREAM_COMPLETE.md")
    File.write!(path, "# Workstream Complete\n\n#{summary}")
    path
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp to_sdk_message({:text, content}) do
    %{
      type: :assistant,
      data: %{
        message: %{
          "content" => [%{"type" => "text", "text" => content}]
        }
      }
    }
  end

  defp to_sdk_message({:tool_use, name, args}) do
    %{
      type: :tool_use,
      data: %{
        name: name,
        input: args,
        id: "tool-#{:rand.uniform(10000)}"
      }
    }
  end

  defp to_sdk_message({:tool_result, result}) do
    %{
      type: :tool_result,
      data: %{
        content: result
      }
    }
  end

  defp to_sdk_message({:thinking, content}) do
    %{
      type: :thinking,
      data: %{
        thinking: content
      }
    }
  end

  defp to_sdk_message({:error, message}) do
    %{
      type: :error,
      data: %{
        error: message
      }
    }
  end
end
