defmodule Ipa.Pod.Commands.CommunicationCommands do
  @moduledoc """
  Commands for messages, approvals, and notifications.
  """

  alias Ipa.Pod.State

  alias Ipa.Pod.Events.{
    MessagePosted,
    ApprovalRequested,
    ApprovalGiven,
    NotificationCreated,
    NotificationRead
  }

  @type result :: {:ok, [struct()]} | {:error, atom() | String.t()}

  @max_message_length 10_000

  @doc """
  Posts a message.
  """
  @spec post_message(State.t(), map()) :: result()
  def post_message(state, params) do
    with {:ok, message_type} <- validate_message_type(params[:type] || params[:message_type]),
         {:ok, content} <- validate_content(params[:content]),
         {:ok, author} <- validate_author(params[:author]),
         :ok <- validate_thread(params[:thread_id], state) do
      event = %MessagePosted{
        task_id: state.task_id,
        message_id: params[:message_id] || Ecto.UUID.generate(),
        author: author,
        content: content,
        message_type: message_type,
        thread_id: params[:thread_id],
        workstream_id: params[:workstream_id]
      }

      {:ok, [event]}
    end
  end

  @doc """
  Requests approval from a human.
  """
  @spec request_approval(State.t(), map()) :: result()
  def request_approval(state, params) do
    with {:ok, question} <- validate_question(params[:question]),
         {:ok, options} <- validate_options(params[:options]),
         {:ok, author} <- validate_author(params[:author]) do
      event = %ApprovalRequested{
        task_id: state.task_id,
        message_id: params[:message_id] || Ecto.UUID.generate(),
        author: author,
        question: question,
        options: options,
        workstream_id: params[:workstream_id],
        blocking?: Map.get(params, :blocking?, true)
      }

      {:ok, [event]}
    end
  end

  @doc """
  Gives approval for a pending approval request.
  """
  @spec give_approval(State.t(), String.t(), String.t(), String.t(), String.t() | nil) :: result()
  def give_approval(state, message_id, approved_by, choice, comment \\ nil) do
    case State.get_message(state, message_id) do
      nil ->
        {:error, :message_not_found}

      msg when msg.message_type != :approval ->
        {:error, :not_approval_request}

      msg when msg.approved? ->
        {:error, :already_approved}

      msg ->
        if choice in (msg.approval_options || []) do
          event = %ApprovalGiven{
            task_id: state.task_id,
            message_id: message_id,
            approved_by: approved_by,
            choice: choice,
            comment: comment
          }

          {:ok, [event]}
        else
          {:error, :invalid_choice}
        end
    end
  end

  @doc """
  Creates a notification.
  """
  @spec create_notification(State.t(), map()) :: result()
  def create_notification(state, params) do
    with {:ok, recipient} <- validate_author(params[:recipient]),
         {:ok, notification_type} <- validate_notification_type(params[:type]) do
      event = %NotificationCreated{
        task_id: state.task_id,
        notification_id: params[:notification_id] || Ecto.UUID.generate(),
        recipient: recipient,
        notification_type: notification_type,
        message_id: params[:message_id],
        preview: params[:preview]
      }

      {:ok, [event]}
    end
  end

  @doc """
  Marks a notification as read.
  """
  @spec mark_notification_read(State.t(), String.t()) :: result()
  def mark_notification_read(state, notification_id) do
    notification =
      Enum.find(state.notifications, fn n -> n.notification_id == notification_id end)

    if notification do
      event = %NotificationRead{
        task_id: state.task_id,
        notification_id: notification_id
      }

      {:ok, [event]}
    else
      {:error, :notification_not_found}
    end
  end

  @doc """
  Posts a review comment on a document.

  ## Required params:
  - author: who is posting the comment
  - content: the comment text
  - document_type: :spec | :plan | :report
  - document_anchor: %{selected_text, surrounding_text, line_start, line_end}

  ## Optional params:
  - thread_id: if replying to an existing thread
  - message_id: custom message ID
  """
  @spec post_review_comment(State.t(), map()) :: result()
  def post_review_comment(state, params) do
    with {:ok, content} <- validate_content(params[:content]),
         {:ok, author} <- validate_author(params[:author]),
         {:ok, document_type} <- validate_document_type(params[:document_type]),
         {:ok, document_anchor} <- validate_document_anchor(params[:document_anchor]),
         :ok <- validate_review_thread(params[:thread_id], state) do
      metadata = %{
        document_type: document_type,
        document_anchor: document_anchor,
        resolved?: false,
        resolved_by: nil,
        resolved_at: nil
      }

      event = %MessagePosted{
        task_id: state.task_id,
        message_id: params[:message_id] || Ecto.UUID.generate(),
        author: author,
        content: content,
        message_type: :review_comment,
        thread_id: params[:thread_id],
        workstream_id: nil,
        metadata: metadata
      }

      {:ok, [event]}
    end
  end

  # Validation helpers

  defp validate_message_type(type) when type in [:question, :update, :blocker], do: {:ok, type}

  defp validate_message_type(type) when type in ["question", "update", "blocker"] do
    {:ok, String.to_atom(type)}
  end

  defp validate_message_type(_), do: {:error, :invalid_type}

  defp validate_content(nil), do: {:error, :empty_content}
  defp validate_content(""), do: {:error, :empty_content}

  defp validate_content(content) when is_binary(content) do
    if byte_size(content) <= @max_message_length do
      {:ok, content}
    else
      {:error, :content_too_long}
    end
  end

  defp validate_content(_), do: {:error, :invalid_content}

  defp validate_author(nil), do: {:error, :invalid_author}
  defp validate_author(""), do: {:error, :invalid_author}
  defp validate_author(author) when is_binary(author), do: {:ok, author}
  defp validate_author(_), do: {:error, :invalid_author}

  defp validate_question(nil), do: {:error, :empty_question}
  defp validate_question(""), do: {:error, :empty_question}
  defp validate_question(q) when is_binary(q), do: {:ok, q}
  defp validate_question(_), do: {:error, :invalid_question}

  defp validate_options([]), do: {:error, :invalid_options}

  defp validate_options(opts) when is_list(opts) do
    if Enum.all?(opts, &is_binary/1) do
      {:ok, opts}
    else
      {:error, :invalid_options}
    end
  end

  defp validate_options(_), do: {:error, :invalid_options}

  defp validate_thread(nil, _state), do: :ok

  defp validate_thread(thread_id, state) do
    if Map.has_key?(state.messages, thread_id) do
      :ok
    else
      {:error, :thread_not_found}
    end
  end

  defp validate_notification_type(type)
       when type in [:needs_approval, :question_asked, :blocker_raised, :workstream_completed] do
    {:ok, type}
  end

  defp validate_notification_type(type) when is_binary(type) do
    case type do
      "needs_approval" -> {:ok, :needs_approval}
      "question_asked" -> {:ok, :question_asked}
      "blocker_raised" -> {:ok, :blocker_raised}
      "workstream_completed" -> {:ok, :workstream_completed}
      _ -> {:error, :invalid_notification_type}
    end
  end

  defp validate_notification_type(_), do: {:error, :invalid_notification_type}

  # Review comment validation helpers

  defp validate_document_type(type) when type in [:spec, :plan, :report], do: {:ok, type}

  defp validate_document_type(type) when is_binary(type) do
    case type do
      "spec" -> {:ok, :spec}
      "plan" -> {:ok, :plan}
      "report" -> {:ok, :report}
      _ -> {:error, :invalid_document_type}
    end
  end

  defp validate_document_type(_), do: {:error, :invalid_document_type}

  defp validate_document_anchor(nil), do: {:error, :missing_document_anchor}

  defp validate_document_anchor(anchor) when is_map(anchor) do
    with {:ok, selected_text} <- get_required_string(anchor, :selected_text),
         {:ok, surrounding_text} <- get_required_string(anchor, :surrounding_text),
         {:ok, line_start} <- get_required_integer(anchor, :line_start),
         {:ok, line_end} <- get_required_integer(anchor, :line_end) do
      {:ok,
       %{
         selected_text: selected_text,
         surrounding_text: surrounding_text,
         line_start: line_start,
         line_end: line_end
       }}
    end
  end

  defp validate_document_anchor(_), do: {:error, :invalid_document_anchor}

  defp get_required_string(map, key) do
    value = Map.get(map, key) || Map.get(map, to_string(key))

    case value do
      nil -> {:error, {:missing_field, key}}
      "" -> {:error, {:empty_field, key}}
      s when is_binary(s) -> {:ok, s}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp get_required_integer(map, key) do
    value = Map.get(map, key) || Map.get(map, to_string(key))

    case value do
      nil -> {:error, {:missing_field, key}}
      i when is_integer(i) and i >= 0 -> {:ok, i}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp validate_review_thread(nil, _state), do: :ok

  defp validate_review_thread(thread_id, state) do
    case Map.get(state.messages, thread_id) do
      nil ->
        {:error, :thread_not_found}

      msg ->
        if msg.message_type == :review_comment do
          :ok
        else
          {:error, :not_review_thread}
        end
    end
  end
end
