defmodule WraithWeb.WidgetHost do
  @moduledoc """
  What a LiveView needs to show live widgets.

      import WraithWeb.WidgetHost

  gives it `mount_widgets/4` (segments → assigns, subscriptions) and two
  handlers to delegate to:

      def handle_event("widget", params, socket), do: {:noreply, widget_event(socket, params)}
      def handle_info({:widget, _, _, _} = msg, socket), do: {:noreply, widget_info(socket, msg)}
      def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"} = msg, socket), do: {:noreply, widget_info(socket, msg)}

  The template renders `@segments` with `WraithWeb.SiteComponents.body/1`.

  Assigns: `@segments` (from `Wraith.Markdown.segments/2`), `@widgets`
  (`%{instance => %{widget, slug, props, state, html}}`), `@presence`
  (readers on this page).
  """

  alias Wraith.{Markdown, Widgets}
  alias WraithWeb.Presence
  import Phoenix.Component, only: [assign: 3]

  def widget_event(socket, %{"instance" => instance, "event" => event} = params),
    do: dispatch(socket, instance, event, params["payload"])

  def widget_event(socket, _params), do: socket

  def widget_info(socket, {:widget, _slug, instance, state}),
    do: state_changed(socket, instance, state)

  def widget_info(socket, %Phoenix.Socket.Broadcast{event: "presence_diff"}),
    do: presence_changed(socket)

  def widget_info(socket, _other), do: socket

  @doc "Split `markdown`, load every widget and its state, subscribe. `scope` seeds instance ids."
  def mount_widgets(socket, markdown, scope, post \\ nil) do
    segments = Markdown.segments(markdown || "", scope)
    presence_topic = "page:" <> scope

    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Wraith.PubSub, presence_topic)
      Presence.track(self(), presence_topic, socket.assigns[:visitor] || inspect(self()), %{})
    end

    presence = Presence.list(presence_topic) |> map_size()

    widgets =
      for {:widget, slug, props, instance} <- segments, into: %{} do
        if Phoenix.LiveView.connected?(socket), do: Widgets.subscribe(instance)
        widget = Widgets.get(slug)
        state = if widget, do: Widgets.state(widget, instance, props), else: %{}
        {instance, %{widget: widget, slug: slug, props: props, state: state, html: nil}}
      end

    socket
    |> assign(:segments, segments)
    |> assign(:presence, presence)
    |> assign(:presence_topic, presence_topic)
    |> assign(:widget_post, post)
    |> assign(:widgets, widgets)
    |> render_all()
  end

  def dispatch(socket, instance, event, payload) do
    case socket.assigns.widgets[instance] do
      %{widget: %{} = widget, props: props} ->
        payload = decode_payload(payload)

        case Widgets.dispatch(widget, instance, props, event, payload, meta(socket, instance)) do
          {:ok, _state} -> socket
          {:error, why} -> Phoenix.LiveView.put_flash(socket, :error, "Widget: " <> why)
        end

      _ ->
        socket
    end
  end

  def state_changed(socket, instance, state) do
    case socket.assigns.widgets[instance] do
      nil ->
        socket

      w ->
        socket
        |> assign(:widgets, Map.put(socket.assigns.widgets, instance, %{w | state: state}))
        |> render_one(instance)
    end
  end

  def presence_changed(socket) do
    n = Presence.list(socket.assigns.presence_topic) |> map_size()
    socket |> assign(:presence, n) |> render_all()
  end

  defp render_all(socket),
    do: Enum.reduce(Map.keys(socket.assigns.widgets), socket, &render_one(&2, &1))

  defp render_one(socket, instance) do
    w = socket.assigns.widgets[instance]

    html =
      case w.widget do
        nil ->
          {:error, "unknown widget “#{w.slug}”"}

        widget ->
          Widgets.render(widget, instance, w.props, w.state, meta(socket, instance))
      end

    assign(socket, :widgets, Map.put(socket.assigns.widgets, instance, %{w | html: html}))
  end

  defp meta(socket, instance) do
    %{
      instance: instance,
      visitor: socket.assigns[:visitor],
      presence: socket.assigns[:presence] || 0,
      post: socket.assigns[:widget_post]
    }
  end

  defp decode_payload(nil), do: %{}
  defp decode_payload(%{} = m), do: m

  defp decode_payload(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end
end
