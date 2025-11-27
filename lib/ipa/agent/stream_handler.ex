defmodule Ipa.Agent.StreamHandler do
  @moduledoc """
  Handles streaming messages from Claude Agent SDK (claude_agent_sdk_ts) and classifies them.

  The Claude Agent SDK returns a stream of messages via callbacks or Elixir Stream.
  This module classifies each message type and extracts relevant data
  for broadcasting to subscribers.

  ## Message Types (claude_agent_sdk_ts)

  Based on the new SDK, messages are maps with `:type` field:
  - `%{type: :chunk, content: text}` - Streaming text chunk
  - `%{type: :tool_use, name: name, input: args}` - Tool is being called
  - `%{type: :tool_result, name: name, output: result}` - Tool execution result
  - `%{type: :end}` - Stream complete
  - `%{type: :error, message: msg}` - Error occurred

  ## Classification Results

  The `classify_message/1` function returns tuples:
  - `{:text_delta, text}` - Text content from assistant
  - `{:tool_use_start, tool_name, args}` - Tool call starting
  - `{:tool_complete, tool_name, result}` - Tool execution finished
  - `{:message_start, data}` - Message beginning
  - `{:message_stop, data}` - Message complete
  - `{:unknown, message}` - Unrecognized message type
  """

  require Logger

  @type classification ::
          {:text_delta, String.t()}
          | {:tool_use_start, String.t(), map()}
          | {:tool_complete, String.t(), term()}
          | {:message_start, term()}
          | {:message_stop, term()}
          | {:unknown, term()}

  @doc """
  Classifies a message from the Claude Agent SDK stream.

  ## Parameters
    - `message` - Message map from ClaudeAgentSdkTs.stream/3

  ## Returns
    - Tuple with classification type and extracted data
  """
  @spec classify_message(term()) :: classification()
  def classify_message(message), do: classify(message)

  @doc """
  Classifies a message from the Claude Agent SDK stream.

  Alias for `classify_message/1`.
  """
  @spec classify(term()) :: classification()
  def classify(nil), do: :unknown
  def classify(message) when message == %{}, do: :unknown
  def classify(message) do
    # Handle claude_agent_sdk_ts message format
    # The new SDK returns messages with :type field directly
    msg_type = get_message_type(message)

    case msg_type do
      # New SDK format: %{type: :chunk, content: text}
      :chunk ->
        content = message[:content] || message["content"] || ""
        {:text_delta, content}

      # New SDK format: %{type: :tool_use, name: name, input: args}
      :tool_use ->
        name = message[:name] || message["name"] || "unknown"
        input = message[:input] || message["input"] || %{}
        {:tool_use_start, name, input}

      # New SDK format: %{type: :tool_result, name: name, output: result}
      :tool_result ->
        name = message[:name] || message["name"]
        output = message[:output] || message["output"] || ""
        {:tool_complete, name, output}

      # New SDK format: %{type: :end}
      :end ->
        {:message_stop, message}

      # New SDK format: %{type: :error, message: msg}
      :error ->
        error = message[:message] || message["message"] || "Unknown error"
        {:error, error}

      # Legacy format support for backwards compatibility during transition
      :assistant ->
        data = get_message_data(message)
        classify_assistant_message(data)

      :thinking ->
        data = get_message_data(message)
        thinking = data[:thinking] || data["thinking"] || ""
        {:thinking, thinking}

      :result ->
        data = get_message_data(message)
        result = data[:result] || data["result"] || ""
        {:result, result}

      :end_turn ->
        {:message_stop, message}

      :message_start ->
        {:message_start, message}

      :message_stop ->
        {:message_stop, message}

      :content_block_delta ->
        data = get_message_data(message)
        classify_content_block_delta(data)

      :content_block_start ->
        data = get_message_data(message)
        classify_content_block_start(data)

      :content_block_stop ->
        {:message_stop, message}

      _ ->
        Logger.debug("Unknown message type: #{inspect(msg_type)}")
        :unknown
    end
  end

  @doc """
  Extracts all text content from a list of messages or content blocks.

  ## Parameters
    - `messages` - List of messages from SDK or content blocks

  ## Returns
    - Concatenated text content
  """
  @spec extract_text(list() | binary() | nil) :: String.t()
  def extract_text(nil), do: ""
  def extract_text(text) when is_binary(text), do: text
  def extract_text([]), do: ""
  def extract_text(messages) when is_list(messages) do
    # Check if this is a list of content blocks (maps with type/text) or SDK messages
    first = List.first(messages)

    cond do
      # Content block format (text/tool_use blocks)
      is_map(first) && (Map.has_key?(first, "type") || Map.has_key?(first, :type)) &&
        !Map.has_key?(first, :data) ->
        extract_text_from_content_blocks(messages)

      # SDK message format
      true ->
        messages
        |> Enum.map(&classify/1)
        |> Enum.filter(fn
          {:text_delta, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:text_delta, text} -> text end)
        |> Enum.join()
    end
  end

  # Helper for content block format
  defp extract_text_from_content_blocks(blocks) do
    blocks
    |> Enum.filter(fn block ->
      type = block[:type] || block["type"]
      type == "text" || type == :text
    end)
    |> Enum.map(fn block ->
      block[:text] || block["text"] || ""
    end)
    |> Enum.join()
  end

  @doc """
  Checks if a message indicates completion of the agent's execution.

  ## Parameters
    - `message` - Message from SDK

  ## Returns
    - `true` if message indicates completion
    - `false` otherwise
  """
  @spec is_complete?(term()) :: boolean()
  def is_complete?(message) do
    msg_type = get_message_type(message)
    # Include :end for new SDK format
    msg_type in [:result, :end_turn, :message_stop, :end]
  end

  @doc """
  Extracts all tool calls from a list of messages.

  ## Parameters
    - `messages` - List of messages from SDK

  ## Returns
    - List of tool call maps with :name, :args, :result keys
  """
  @spec extract_tool_calls(list()) :: [map()]
  def extract_tool_calls(messages) when is_list(messages) do
    messages
    |> Enum.map(&classify_message/1)
    |> Enum.reduce(%{}, fn classified, acc ->
      case classified do
        {:tool_use_start, name, args} ->
          Map.put(acc, name, %{name: name, args: args, result: nil})

        {:tool_complete, name, result} ->
          Map.update(acc, name, %{name: name, args: %{}, result: result}, fn call ->
            %{call | result: result}
          end)

        _ ->
          acc
      end
    end)
    |> Map.values()
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_message_type(message) do
    # Try struct field access first (for message maps)
    cond do
      is_struct(message) && Map.has_key?(message, :type) ->
        message.type

      is_map(message) && Map.has_key?(message, :type) ->
        message.type

      is_map(message) && Map.has_key?(message, "type") ->
        String.to_existing_atom(message["type"])

      true ->
        :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  defp get_message_data(message) do
    cond do
      is_struct(message) && Map.has_key?(message, :data) ->
        message.data

      is_map(message) && Map.has_key?(message, :data) ->
        message.data

      is_map(message) && Map.has_key?(message, "data") ->
        message["data"]

      true ->
        message
    end
  end

  defp classify_assistant_message(data) do
    # Extract text from assistant message content
    content = extract_content(data)

    case content do
      text when is_binary(text) and text != "" ->
        {:text_delta, text}

      _ ->
        {:message_stop, data}
    end
  end

  defp classify_content_block_delta(data) do
    # Handle streaming text deltas
    delta = data[:delta] || data["delta"] || %{}
    text = delta[:text] || delta["text"]

    if text && text != "" do
      {:text_delta, text}
    else
      {:unknown, data}
    end
  end

  defp classify_content_block_start(data) do
    # Handle content block start (might be tool_use or text)
    content_block = data[:content_block] || data["content_block"] || %{}
    block_type = content_block[:type] || content_block["type"]

    case block_type do
      "tool_use" ->
        name = content_block[:name] || content_block["name"] || "unknown"
        input = content_block[:input] || content_block["input"] || %{}
        {:tool_use_start, name, input}

      "text" ->
        text = content_block[:text] || content_block["text"] || ""
        {:text_delta, text}

      _ ->
        {:message_start, data}
    end
  end

  defp extract_content(data) do
    # Try various content extraction strategies
    cond do
      # Direct text field
      is_binary(data[:text]) ->
        data[:text]

      is_binary(data["text"]) ->
        data["text"]

      # Content array with text blocks
      is_list(data[:content]) ->
        extract_text_from_content_array(data[:content])

      is_list(data["content"]) ->
        extract_text_from_content_array(data["content"])

      # Message wrapper
      is_map(data[:message]) ->
        extract_content(data[:message])

      is_map(data["message"]) ->
        extract_content(data["message"])

      # Direct binary content
      is_binary(data) ->
        data

      true ->
        ""
    end
  end

  defp extract_text_from_content_array(content) when is_list(content) do
    content
    |> Enum.filter(fn block ->
      block_type = block[:type] || block["type"]
      block_type == "text" || block_type == :text
    end)
    |> Enum.map(fn block ->
      block[:text] || block["text"] || ""
    end)
    |> Enum.join()
  end

  defp extract_text_from_content_array(_), do: ""
end
