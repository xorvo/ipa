defmodule Ipa.Agent.StreamHandlerTest do
  @moduledoc """
  Tests for the Ipa.Agent.StreamHandler module.
  """

  use ExUnit.Case, async: true

  alias Ipa.Agent.StreamHandler

  describe "classify/1" do
    test "classifies text content from assistant message" do
      message = %{
        type: :assistant,
        data: %{
          message: %{
            "content" => [%{"type" => "text", "text" => "Hello, world!"}]
          }
        }
      }

      assert {:text_delta, "Hello, world!"} = StreamHandler.classify(message)
    end

    test "classifies text content with atom keys" do
      message = %{
        type: :assistant,
        data: %{
          message: %{
            content: [%{type: "text", text: "Test content"}]
          }
        }
      }

      assert {:text_delta, "Test content"} = StreamHandler.classify(message)
    end

    test "handles multiple text blocks by joining them" do
      message = %{
        type: :assistant,
        data: %{
          message: %{
            "content" => [
              %{"type" => "text", "text" => "First "},
              %{"type" => "text", "text" => "Second"}
            ]
          }
        }
      }

      assert {:text_delta, "First Second"} = StreamHandler.classify(message)
    end

    test "classifies tool use start" do
      # New SDK format: %{type: :tool_use, name: name, input: args}
      message = %{
        type: :tool_use,
        name: "Read",
        input: %{"file_path" => "/tmp/test.txt"}
      }

      result = StreamHandler.classify(message)
      assert {:tool_use_start, "Read", %{"file_path" => "/tmp/test.txt"}} = result
    end

    test "classifies tool result" do
      # New SDK format: %{type: :tool_result, name: name, output: result}
      message = %{
        type: :tool_result,
        name: "Read",
        output: "File contents here"
      }

      result = StreamHandler.classify(message)
      assert {:tool_complete, "Read", "File contents here"} = result
    end

    test "classifies thinking block" do
      message = %{
        type: :thinking,
        data: %{
          thinking: "Let me analyze this..."
        }
      }

      assert {:thinking, "Let me analyze this..."} = StreamHandler.classify(message)
    end

    test "classifies error message" do
      message = %{
        type: :error,
        data: %{
          error: %{
            "message" => "Rate limit exceeded"
          }
        }
      }

      result = StreamHandler.classify(message)
      assert {:error, _} = result
    end

    test "returns :unknown for unrecognized message types" do
      message = %{
        type: :unknown_type,
        data: %{something: "weird"}
      }

      assert :unknown = StreamHandler.classify(message)
    end

    test "handles nil message gracefully" do
      assert :unknown = StreamHandler.classify(nil)
    end

    test "handles empty map gracefully" do
      assert :unknown = StreamHandler.classify(%{})
    end

    test "classifies result message (final response)" do
      message = %{
        type: :result,
        data: %{
          result: "Task completed successfully"
        }
      }

      assert {:result, "Task completed successfully"} = StreamHandler.classify(message)
    end
  end

  describe "extract_text/1" do
    test "extracts text from content blocks list" do
      content = [
        %{"type" => "text", "text" => "Hello"},
        %{"type" => "tool_use", "name" => "Read"},
        %{"type" => "text", "text" => " World"}
      ]

      assert "Hello World" = StreamHandler.extract_text(content)
    end

    test "returns empty string for empty list" do
      assert "" = StreamHandler.extract_text([])
    end

    test "returns empty string for nil" do
      assert "" = StreamHandler.extract_text(nil)
    end

    test "returns binary content as-is" do
      assert "plain text" = StreamHandler.extract_text("plain text")
    end
  end

  describe "is_complete?/1" do
    test "returns true for result message" do
      message = %{type: :result, data: %{}}
      assert StreamHandler.is_complete?(message)
    end

    test "returns true for end_turn message" do
      message = %{type: :end_turn, data: %{}}
      assert StreamHandler.is_complete?(message)
    end

    test "returns false for assistant message" do
      message = %{type: :assistant, data: %{}}
      refute StreamHandler.is_complete?(message)
    end

    test "returns false for tool_use message" do
      message = %{type: :tool_use, data: %{}}
      refute StreamHandler.is_complete?(message)
    end
  end
end
