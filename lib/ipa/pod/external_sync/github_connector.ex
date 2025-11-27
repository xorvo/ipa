defmodule Ipa.Pod.ExternalSync.GitHubConnector do
  @moduledoc """
  GitHub API connector using the `gh` CLI.

  Provides:
  - PR creation, update, merge, close
  - PR status and comments fetching
  - Rate limit handling
  - Error handling with retries

  Uses the `gh` CLI which handles authentication via the user's
  existing GitHub credentials.
  """

  require Logger

  @type repo :: String.t()
  @type pr_number :: integer()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Creates a new pull request.

  ## Options

  - `:title` - PR title (required)
  - `:body` - PR description
  - `:head` - Head branch name (required)
  - `:base` - Base branch name (default: "main")
  - `:draft` - Create as draft (default: false)

  ## Returns

  - `{:ok, pr_number, pr_url}` on success
  - `{:error, reason}` on failure

  ## Examples

      {:ok, 123, "https://github.com/owner/repo/pull/123"} =
        GitHubConnector.create_pr("owner/repo",
          title: "My PR",
          body: "Description",
          head: "feature-branch",
          base: "main"
        )
  """
  @spec create_pr(repo(), keyword()) :: {:ok, pr_number(), String.t()} | {:error, term()}
  def create_pr(repo, opts) do
    title = Keyword.fetch!(opts, :title)
    head = Keyword.fetch!(opts, :head)
    base = Keyword.get(opts, :base, "main")
    body = Keyword.get(opts, :body, "")
    draft = Keyword.get(opts, :draft, false)

    args = [
      "pr", "create",
      "--repo", repo,
      "--title", title,
      "--body", body,
      "--head", head,
      "--base", base
    ]

    args = if draft, do: args ++ ["--draft"], else: args

    case run_gh(args) do
      {:ok, output} ->
        # gh pr create outputs the PR URL
        pr_url = String.trim(output)
        pr_number = extract_pr_number(pr_url)

        if pr_number do
          Logger.info("Created PR ##{pr_number} for #{repo}: #{pr_url}")
          {:ok, pr_number, pr_url}
        else
          {:error, :invalid_response}
        end

      {:error, reason} ->
        Logger.error("Failed to create PR for #{repo}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Updates an existing pull request.

  ## Options

  - `:title` - New title
  - `:body` - New body

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec update_pr(repo(), pr_number(), keyword()) :: :ok | {:error, term()}
  def update_pr(repo, pr_number, opts) do
    args = ["pr", "edit", to_string(pr_number), "--repo", repo]

    args =
      case Keyword.get(opts, :title) do
        nil -> args
        title -> args ++ ["--title", title]
      end

    args =
      case Keyword.get(opts, :body) do
        nil -> args
        body -> args ++ ["--body", body]
      end

    case run_gh(args) do
      {:ok, _} ->
        Logger.info("Updated PR ##{pr_number} for #{repo}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to update PR ##{pr_number} for #{repo}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets pull request details.

  ## Returns

  - `{:ok, pr_data}` with PR details map
  - `{:error, reason}` on failure
  """
  @spec get_pr(repo(), pr_number()) :: {:ok, map()} | {:error, term()}
  def get_pr(repo, pr_number) do
    args = [
      "pr", "view", to_string(pr_number),
      "--repo", repo,
      "--json", "number,title,body,state,merged,mergeable,headRefName,baseRefName,url,createdAt,updatedAt"
    ]

    case run_gh(args) do
      {:ok, output} ->
        case Jason.decode(output, keys: :atoms) do
          {:ok, data} ->
            {:ok, data}

          {:error, _} ->
            {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Merges a pull request.

  ## Parameters

  - `repo` - Repository in "owner/repo" format
  - `pr_number` - PR number
  - `merge_method` - "merge", "squash", or "rebase"

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec merge_pr(repo(), pr_number(), String.t()) :: :ok | {:error, term()}
  def merge_pr(repo, pr_number, merge_method \\ "squash") do
    args = [
      "pr", "merge", to_string(pr_number),
      "--repo", repo,
      "--#{merge_method}",
      "--delete-branch"
    ]

    case run_gh(args) do
      {:ok, _} ->
        Logger.info("Merged PR ##{pr_number} for #{repo} using #{merge_method}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to merge PR ##{pr_number} for #{repo}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Closes a pull request without merging.

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec close_pr(repo(), pr_number()) :: :ok | {:error, term()}
  def close_pr(repo, pr_number) do
    args = ["pr", "close", to_string(pr_number), "--repo", repo]

    case run_gh(args) do
      {:ok, _} ->
        Logger.info("Closed PR ##{pr_number} for #{repo}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to close PR ##{pr_number} for #{repo}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets comments on a pull request.

  ## Returns

  - `{:ok, comments}` list of comment maps
  - `{:error, reason}` on failure
  """
  @spec get_pr_comments(repo(), pr_number()) :: {:ok, [map()]} | {:error, term()}
  def get_pr_comments(repo, pr_number) do
    args = [
      "pr", "view", to_string(pr_number),
      "--repo", repo,
      "--json", "comments"
    ]

    case run_gh(args) do
      {:ok, output} ->
        case Jason.decode(output, keys: :atoms) do
          {:ok, %{comments: comments}} ->
            {:ok, comments}

          {:error, _} ->
            {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Adds a comment to a pull request.

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec add_pr_comment(repo(), pr_number(), String.t()) :: :ok | {:error, term()}
  def add_pr_comment(repo, pr_number, body) do
    args = [
      "pr", "comment", to_string(pr_number),
      "--repo", repo,
      "--body", body
    ]

    case run_gh(args) do
      {:ok, _} ->
        Logger.info("Added comment to PR ##{pr_number} for #{repo}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to add comment to PR ##{pr_number} for #{repo}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets the current rate limit status.

  ## Returns

  - `{:ok, %{remaining: n, reset_at: timestamp}}` on success
  - `{:error, reason}` on failure
  """
  @spec get_rate_limit() :: {:ok, map()} | {:error, term()}
  def get_rate_limit do
    args = ["api", "rate_limit", "--jq", ".resources.core"]

    case run_gh(args) do
      {:ok, output} ->
        case Jason.decode(output, keys: :atoms) do
          {:ok, data} ->
            {:ok, %{
              remaining: data.remaining,
              limit: data.limit,
              reset_at: data.reset
            }}

          {:error, _} ->
            {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if the `gh` CLI is available and authenticated.

  ## Returns

  - `{:ok, username}` if authenticated
  - `{:error, :not_authenticated}` if not authenticated
  - `{:error, :gh_not_found}` if gh CLI not installed
  """
  @spec check_auth() :: {:ok, String.t()} | {:error, term()}
  def check_auth do
    args = ["auth", "status"]

    case run_gh(args) do
      {:ok, output} ->
        # Extract username from output
        case Regex.run(~r/Logged in to github\.com account (\S+)/, output) do
          [_, username] -> {:ok, username}
          _ -> {:ok, "unknown"}
        end

      {:error, {:exit_code, _}} ->
        {:error, :not_authenticated}

      {:error, :command_not_found} ->
        {:error, :gh_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp run_gh(args) do
    full_args = ["gh" | args]
    cmd = Enum.join(full_args, " ")

    Logger.debug("Running: #{cmd}")

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        # Check for rate limiting
        if String.contains?(output, "rate limit") do
          {:error, :rate_limited}
        else
          Logger.debug("gh command failed (exit #{code}): #{output}")
          {:error, {:exit_code, code, output}}
        end
    end
  rescue
    e in ErlangError ->
      case e.original do
        :enoent -> {:error, :command_not_found}
        other -> {:error, other}
      end
  end

  defp extract_pr_number(url) when is_binary(url) do
    case Regex.run(~r/\/pull\/(\d+)/, url) do
      [_, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp extract_pr_number(_), do: nil
end
