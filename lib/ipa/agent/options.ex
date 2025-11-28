defmodule Ipa.Agent.Options do
  @moduledoc """
  Options struct for configuring Claude Agent execution.

  This module provides a struct that mirrors the configuration options
  expected by the claude_agent_sdk_ts library.

  ## Fields

  - `:cwd` - Working directory for the agent (required)
  - `:allowed_tools` - List of tool names the agent can use
  - `:max_turns` - Maximum conversation turns (default: 50)
  - `:timeout_ms` - Timeout in milliseconds (default: 3_600_000 = 1 hour)
  - `:permission_mode` - Permission mode for file operations (:accept_edits, :bypass_permissions)
  - `:model` - Claude model to use (optional)
  - `:interactive` - Whether agent supports multi-turn conversation (default: true)
  """

  defstruct [
    :cwd,
    :allowed_tools,
    :max_turns,
    :timeout_ms,
    :permission_mode,
    :model,
    interactive: true
  ]

  @type t :: %__MODULE__{
          cwd: String.t() | nil,
          allowed_tools: [String.t()] | nil,
          max_turns: non_neg_integer() | nil,
          timeout_ms: non_neg_integer() | nil,
          permission_mode: :accept_edits | :bypass_permissions | nil,
          model: String.t() | nil,
          interactive: boolean()
        }

  @doc """
  Creates a new Options struct with the given fields.

  ## Examples

      iex> Ipa.Agent.Options.new(cwd: "/tmp/workspace", max_turns: 100)
      %Ipa.Agent.Options{cwd: "/tmp/workspace", max_turns: 100, ...}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Converts the Options struct to a keyword list suitable for ClaudeAgentSdkTs.

  ## Examples

      iex> opts = %Ipa.Agent.Options{cwd: "/tmp/workspace", max_turns: 100}
      iex> Ipa.Agent.Options.to_keyword_list(opts)
      [cwd: "/tmp/workspace", max_turns: 100, timeout: nil, ...]
  """
  @spec to_keyword_list(t()) :: keyword()
  def to_keyword_list(%__MODULE__{} = opts) do
    base = [
      cwd: opts.cwd,
      max_turns: opts.max_turns,
      timeout: opts.timeout_ms
    ]

    base =
      if opts.allowed_tools do
        Keyword.put(base, :allowed_tools, opts.allowed_tools)
      else
        base
      end

    base =
      if opts.permission_mode do
        Keyword.put(base, :permission_mode, opts.permission_mode)
      else
        base
      end

    base =
      if opts.model do
        Keyword.put(base, :model, opts.model)
      else
        base
      end

    # Filter out nil values
    Enum.reject(base, fn {_k, v} -> is_nil(v) end)
  end
end
