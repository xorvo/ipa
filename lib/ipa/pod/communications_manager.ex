defmodule Ipa.Pod.CommunicationsManager do
  @moduledoc """
  Pod Communications Manager provides structured communication for human-agent
  and agent-agent coordination within a pod.

  Features:
  - Threaded messaging (like Slack)
  - Typed messages: question, approval, update, blocker
  - Inbox/notification management
  - Human approval workflows
  - Real-time pub-sub broadcasting
  """

  use GenServer
  require Logger

  # Client API

  @doc """
  Starts the Communications Manager for a pod.

  ## Parameters
    - task_id: Task UUID

  ## Options
    - name: Optional name for the GenServer (defaults to via Registry)
  """
  def start_link(task_id, opts \\ []) do
    name = Keyword.get(opts, :name, via_tuple(task_id))
    GenServer.start_link(__MODULE__, task_id, name: name)
  end

  @doc """
  Posts a new message to the pod communications.

  ## Parameters
    - task_id: Task UUID
    - opts: Keyword list with:
      - type (required): Message type (:question | :update | :blocker)
      - content (required): Message content (string)
      - author (required): Author ID ("agent-123" or "user-456")
      - thread_id (optional): Parent message ID for replies
      - workstream_id (optional): Associated workstream

  ## Returns
    - {:ok, message_id} - Message successfully posted
    - {:error, :invalid_type} - Invalid message type
    - {:error, :empty_content} - Content is empty
    - {:error, :thread_not_found} - Thread ID doesn't exist

  ## Example
      {:ok, msg_id} = CommunicationsManager.post_message(
        task_id,
        type: :question,
        content: "Should we use PostgreSQL or SQLite?",
        author: "agent-dev-1",
        workstream_id: "ws-2"
      )
  """
  @spec post_message(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def post_message(task_id, opts) do
    GenServer.call(via_tuple(task_id), {:post_message, opts})
  end

  @doc """
  Requests human approval with specific options.

  ## Parameters
    - task_id: Task UUID
    - opts: Keyword list with:
      - question (required): Approval question (string)
      - options (required): List of options for human to choose (list of strings)
      - author (required): Author ID (usually agent)
      - workstream_id (optional): Associated workstream
      - blocking? (optional): Whether agent is blocked waiting (default: true)

  ## Returns
    - {:ok, message_id} - Approval request created
    - {:error, :invalid_options} - Options list is empty or invalid
    - {:error, :empty_question} - Question is empty

  ## Example
      {:ok, msg_id} = CommunicationsManager.request_approval(
        task_id,
        question: "Ready to merge PR #123 to main?",
        options: ["Yes, merge it", "No, needs changes"],
        author: "agent-dev-1",
        workstream_id: "ws-1"
      )
  """
  @spec request_approval(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def request_approval(task_id, opts) do
    GenServer.call(via_tuple(task_id), {:request_approval, opts})
  end

  @doc """
  Provides approval for a pending approval request.

  ## Parameters
    - task_id: Task UUID
    - message_id: Approval request message ID
    - opts: Keyword list with:
      - approved_by (required): User ID providing approval
      - choice (required): Selected option from the original options list
      - comment (optional): Additional comment/explanation

  ## Returns
    - {:ok, approval_id} - Approval recorded
    - {:error, :message_not_found} - Message doesn't exist
    - {:error, :not_approval_request} - Message is not an approval request
    - {:error, :invalid_choice} - Choice not in original options
    - {:error, :already_approved} - Approval already given

  ## Example
      {:ok, approval_id} = CommunicationsManager.give_approval(
        task_id,
        msg_id,
        approved_by: "user-456",
        choice: "Yes, merge it"
      )
  """
  @spec give_approval(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def give_approval(task_id, message_id, opts) do
    GenServer.call(via_tuple(task_id), {:give_approval, message_id, opts})
  end

  @doc """
  Marks a notification as read.

  ## Parameters
    - task_id: Task UUID
    - notification_id: Notification UUID

  ## Returns
    - :ok - Notification marked as read
    - {:error, :notification_not_found} - Notification doesn't exist
  """
  @spec mark_read(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_read(task_id, notification_id) do
    GenServer.call(via_tuple(task_id), {:mark_read, notification_id})
  end

  @doc """
  Retrieves inbox notifications.

  ## Parameters
    - task_id: Task UUID
    - opts: Keyword list with:
      - unread_only? (optional): Only return unread notifications (default: false)
      - recipient (optional): Filter by recipient ("user-456" or "agent-123")

  ## Returns
    - {:ok, notifications} - List of notification maps
    - {:error, :task_not_found} - Task doesn't exist
  """
  @spec get_inbox(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_inbox(task_id, opts \\ []) do
    GenServer.call(via_tuple(task_id), {:get_inbox, opts})
  end

  @doc """
  Retrieves all messages in a thread.

  ## Parameters
    - task_id: Task UUID
    - thread_id: Root message ID

  ## Returns
    - {:ok, messages} - List of messages in thread (sorted chronologically)
    - {:error, :thread_not_found} - Thread doesn't exist
  """
  @spec get_thread(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_thread(task_id, thread_id) do
    GenServer.call(via_tuple(task_id), {:get_thread, thread_id})
  end

  @doc """
  Retrieves messages with optional filtering.

  ## Parameters
    - task_id: Task UUID
    - opts: Keyword list with:
      - type (optional): Filter by message type
      - workstream_id (optional): Filter by workstream
      - author (optional): Filter by author
      - limit (optional): Limit number of results (default: 50)

  ## Returns
    - {:ok, messages} - List of message maps
    - {:error, :task_not_found} - Task doesn't exist
  """
  @spec get_messages(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_messages(task_id, opts \\ []) do
    GenServer.call(via_tuple(task_id), {:get_messages, opts})
  end

  @doc """
  Subscribes to message notifications via Phoenix.PubSub.

  Topic: `"pod:<task_id>:communications"`

  Messages received:
    - `{:message_posted, task_id, message}`
    - `{:approval_requested, task_id, message}`
    - `{:approval_given, task_id, message_id, approval}`
    - `{:notification_created, task_id, notification}`
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(task_id) do
    Phoenix.PubSub.subscribe(Ipa.PubSub, "pod:#{task_id}:communications")
  end

  # Server Callbacks

  defstruct [
    :task_id,
    messages: %{},  # message_id => message (cached from Pod State)
    inbox: []       # notifications (cached from Pod State)
  ]

  @impl true
  def init(task_id) do
    # Subscribe to pod state changes
    Ipa.Pod.State.subscribe(task_id)

    # Load initial messages from state to cache them locally
    case Ipa.Pod.State.get_state(task_id) do
      {:ok, pod_state} ->
        messages = Map.new(pod_state.messages || [], fn msg -> {msg.message_id, msg} end)
        inbox = pod_state.inbox || []
        {:ok, %__MODULE__{task_id: task_id, messages: messages, inbox: inbox}}

      {:error, reason} ->
        Logger.error("Failed to load pod state for task #{task_id}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:state_updated, _task_id, new_state}, state) do
    # Update cached messages when state changes
    messages = Map.new(new_state.messages || [], fn msg -> {msg.message_id, msg} end)
    inbox = new_state.inbox || []
    {:noreply, %{state | messages: messages, inbox: inbox}}
  end

  @impl true
  def handle_call({:post_message, opts}, _from, state) do
    with :ok <- validate_message(opts, state),
         message_id <- generate_uuid(),
         {:ok, _version} <- append_message_event(state.task_id, message_id, opts),
         :ok <- maybe_create_notification(state.task_id, message_id, opts),
         :ok <- broadcast_message(state.task_id, message_id, opts) do
      {:reply, {:ok, message_id}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:request_approval, opts}, _from, state) do
    with :ok <- validate_approval_request(opts),
         message_id <- generate_uuid(),
         {:ok, _version} <- append_approval_request_event(state.task_id, message_id, opts),
         :ok <- create_approval_notification(state.task_id, message_id, opts),
         :ok <- broadcast_approval_request(state.task_id, message_id, opts) do
      {:reply, {:ok, message_id}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:give_approval, message_id, opts}, _from, state) do
    # Get current state with version for optimistic concurrency
    {:ok, current_state} = Ipa.Pod.State.get_state(state.task_id)

    with {:ok, message} <- validate_message_exists(message_id, state.messages),
         :ok <- validate_is_approval(message),
         :ok <- validate_not_already_approved(message),
         :ok <- validate_choice_in_options(opts[:choice], message.approval_options),
         approval_id <- generate_uuid(),
         {:ok, _version} <- Ipa.Pod.State.append_event(
           state.task_id,
           "approval_given",
           %{
             message_id: message_id,
             approved_by: opts[:approved_by],
             choice: opts[:choice],
             comment: opts[:comment]
           },
           current_state.version,
           actor_id: opts[:approved_by]
         ),
         :ok <- broadcast_approval(state.task_id, message_id, opts) do
      {:reply, {:ok, approval_id}, state}
    else
      {:error, :version_conflict} ->
        {:reply, {:error, :version_conflict}, state}
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:mark_read, notification_id}, _from, state) do
    with {:ok, notification} <- find_notification(notification_id, state.inbox),
         {:ok, _version} <- Ipa.Pod.State.append_event(
           state.task_id,
           "notification_read",
           %{
             notification_id: notification_id,
             read_by: notification.recipient
           },
           nil,
           actor_id: notification.recipient
         ) do
      {:reply, :ok, state}
    else
      {:error, :not_found} ->
        {:reply, {:error, :notification_not_found}, state}
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_inbox, opts}, _from, state) do
    unread_only = Keyword.get(opts, :unread_only?, false)
    recipient = Keyword.get(opts, :recipient)

    filtered_inbox =
      state.inbox
      |> filter_by_recipient(recipient)
      |> filter_by_read_status(unread_only)
      |> Enum.sort_by(& &1.created_at, :desc)

    {:reply, {:ok, filtered_inbox}, state}
  end

  @impl true
  def handle_call({:get_thread, thread_id}, _from, state) do
    # Find root message
    case Map.get(state.messages, thread_id) do
      nil ->
        {:reply, {:error, :thread_not_found}, state}

      _root_message ->
        # Get all messages in thread (root + replies)
        thread_messages =
          state.messages
          |> Map.values()
          |> Enum.filter(fn msg ->
            msg.message_id == thread_id || msg.thread_id == thread_id
          end)
          |> Enum.sort_by(& &1.posted_at, :asc)

        {:reply, {:ok, thread_messages}, state}
    end
  end

  @impl true
  def handle_call({:get_messages, opts}, _from, state) do
    type = Keyword.get(opts, :type)
    workstream_id = Keyword.get(opts, :workstream_id)
    author = Keyword.get(opts, :author)
    limit = Keyword.get(opts, :limit, 50)

    filtered_messages =
      state.messages
      |> Map.values()
      |> filter_by_type(type)
      |> filter_by_workstream(workstream_id)
      |> filter_by_author(author)
      |> Enum.sort_by(& &1.posted_at, :desc)
      |> Enum.take(limit)

    {:reply, {:ok, filtered_messages}, state}
  end

  # Private Helper Functions

  defp via_tuple(task_id) do
    {:via, Registry, {Ipa.PodRegistry, {:communications, task_id}}}
  end

  defp generate_uuid do
    Ecto.UUID.generate()
  end

  # Message Validation

  defp validate_message(opts, state) do
    with {:ok, _type} <- validate_type(opts[:type]),
         {:ok, _content} <- validate_content(opts[:content]),
         {:ok, _author} <- validate_author(opts[:author]),
         :ok <- validate_thread(opts[:thread_id], state) do
      :ok
    end
  end

  defp validate_type(type) when type in [:question, :update, :blocker], do: {:ok, type}
  defp validate_type(_), do: {:error, :invalid_type}

  defp validate_content(content) when is_binary(content) and byte_size(content) > 0 do
    max_length = Application.get_env(:ipa, __MODULE__, [])
                 |> Keyword.get(:max_message_length, 10_000)

    if byte_size(content) <= max_length do
      {:ok, content}
    else
      {:error, :content_too_long}
    end
  end
  defp validate_content(_), do: {:error, :empty_content}

  defp validate_author(author) when is_binary(author) and byte_size(author) > 0 do
    {:ok, author}
  end
  defp validate_author(_), do: {:error, :invalid_author}

  defp validate_thread(nil, _state), do: :ok
  defp validate_thread(thread_id, state) when is_binary(thread_id) do
    if Map.has_key?(state.messages, thread_id) do
      :ok
    else
      {:error, :thread_not_found}
    end
  end

  # Approval Validation

  defp validate_approval_request(opts) do
    with {:ok, _question} <- validate_question(opts[:question]),
         {:ok, _options} <- validate_options(opts[:options]),
         {:ok, _author} <- validate_author(opts[:author]) do
      :ok
    end
  end

  defp validate_question(question) when is_binary(question) and byte_size(question) > 0 do
    {:ok, question}
  end
  defp validate_question(_), do: {:error, :empty_question}

  defp validate_options(options) when is_list(options) and length(options) > 0 do
    if Enum.all?(options, &is_binary/1) do
      {:ok, options}
    else
      {:error, :invalid_options}
    end
  end
  defp validate_options(_), do: {:error, :invalid_options}

  defp validate_message_exists(message_id, messages) do
    case Map.get(messages, message_id) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  end

  defp validate_is_approval(message) do
    if message.type == :approval do
      :ok
    else
      {:error, :not_approval_request}
    end
  end

  defp validate_not_already_approved(message) do
    if message.approved? do
      {:error, :already_approved}
    else
      :ok
    end
  end

  defp validate_choice_in_options(choice, options) do
    if choice in options do
      :ok
    else
      {:error, :invalid_choice}
    end
  end

  # Event Append Helpers

  defp append_message_event(task_id, message_id, opts) do
    Ipa.Pod.State.append_event(
      task_id,
      "message_posted",
      %{
        message_id: message_id,
        type: opts[:type],
        content: opts[:content],
        author: opts[:author],
        thread_id: opts[:thread_id],
        workstream_id: opts[:workstream_id]
      },
      nil,
      actor_id: opts[:author]
    )
  end

  defp append_approval_request_event(task_id, message_id, opts) do
    Ipa.Pod.State.append_event(
      task_id,
      "approval_requested",
      %{
        message_id: message_id,
        question: opts[:question],
        options: opts[:options],
        author: opts[:author],
        workstream_id: opts[:workstream_id],
        blocking?: Keyword.get(opts, :blocking?, true)
      },
      nil,
      actor_id: opts[:author]
    )
  end

  # Notification Helpers

  defp maybe_create_notification(task_id, message_id, opts) do
    case opts[:type] do
      :question ->
        create_notifications_for_humans(task_id, message_id, :question_asked)
      :blocker ->
        create_notifications_for_humans(task_id, message_id, :blocker_raised)
      :update ->
        :ok  # No notifications for updates
      _ ->
        :ok
    end
  end

  defp create_approval_notification(task_id, message_id, _opts) do
    create_notifications_for_humans(task_id, message_id, :needs_approval)
  end

  defp create_notifications_for_humans(task_id, message_id, type) do
    humans = get_human_recipients(task_id)

    # Get message preview (first 100 chars of content)
    {:ok, state} = Ipa.Pod.State.get_state(task_id)
    message = Enum.find(state.messages, fn m -> m.message_id == message_id end)
    preview = if message, do: String.slice(message.content, 0, 100), else: ""

    Enum.each(humans, fn human_id ->
      notification_id = generate_uuid()

      Ipa.Pod.State.append_event(
        task_id,
        "notification_created",
        %{
          notification_id: notification_id,
          recipient: human_id,
          message_id: message_id,
          type: type,
          message_preview: preview
        },
        nil,
        actor_id: "system"
      )
    end)

    :ok
  end

  defp get_human_recipients(task_id) do
    config = Application.get_env(:ipa, __MODULE__, [])
    default_recipients = Keyword.get(config, :notification_recipients, [])

    case default_recipients do
      [] ->
        Logger.warning("No human recipients configured for task #{task_id}, notifications will not be created")
        []
      recipients ->
        recipients
    end
  end

  defp find_notification(notification_id, inbox) do
    case Enum.find(inbox, fn n -> n.notification_id == notification_id end) do
      nil -> {:error, :not_found}
      notification -> {:ok, notification}
    end
  end

  # Pub-Sub Broadcasting

  defp broadcast_message(task_id, message_id, message_data) do
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      "pod:#{task_id}:communications",
      {:message_posted, task_id, %{message_id: message_id, data: message_data}}
    )
  end

  defp broadcast_approval_request(task_id, message_id, approval_data) do
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      "pod:#{task_id}:communications",
      {:approval_requested, task_id, %{message_id: message_id, data: approval_data}}
    )
  end

  defp broadcast_approval(task_id, message_id, approval_data) do
    Phoenix.PubSub.broadcast(
      Ipa.PubSub,
      "pod:#{task_id}:communications",
      {:approval_given, task_id, message_id, approval_data}
    )
  end

  # Filter Helpers

  defp filter_by_recipient(inbox, nil), do: inbox
  defp filter_by_recipient(inbox, recipient) do
    Enum.filter(inbox, fn n -> n.recipient == recipient end)
  end

  defp filter_by_read_status(inbox, false), do: inbox
  defp filter_by_read_status(inbox, true) do
    Enum.filter(inbox, fn n -> !n.read? end)
  end

  defp filter_by_type(messages, nil), do: messages
  defp filter_by_type(messages, type) do
    Enum.filter(messages, fn m -> m.type == type end)
  end

  defp filter_by_workstream(messages, nil), do: messages
  defp filter_by_workstream(messages, workstream_id) do
    Enum.filter(messages, fn m -> m.workstream_id == workstream_id end)
  end

  defp filter_by_author(messages, nil), do: messages
  defp filter_by_author(messages, author) do
    Enum.filter(messages, fn m -> m.author == author end)
  end
end
