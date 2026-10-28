defmodule PhoenixStreamdown do
  @moduledoc """
  Streaming markdown renderer for Phoenix LiveView.

  Renders LLM-streamed markdown with proper handling of incomplete syntax,
  block-level memoization, and minimal DOM updates.

  ## Usage

      use PhoenixStreamdown

      <.markdown content={@response} streaming={@streaming?} id={"msg-\#{@message_id}"} />

  Or without importing:

      <PhoenixStreamdown.markdown
        content={@response}
        streaming={@streaming?}
        id={"msg-\#{@message_id}"}
      />

  ## How it works

  1. `PhoenixStreamdown.Remend` — auto-closes incomplete markdown syntax
     (`**bold` → `**bold**`, unclosed code fences, partial links)
  2. `PhoenixStreamdown.Blocks` — splits markdown into independent blocks
  3. [MDEx](https://hex.pm/packages/mdex) — renders each block to HTML server-side (Rust-backed)
  4. LiveView — diffs only the active block, skips the rest

  Completed blocks get `phx-update="ignore"` so LiveView skips them entirely.
  On a 56-block document, this means **~7x less server CPU** and **~460x smaller
  diffs** per token compared to re-rendering the full document each time.

  ## Animations

  Enable word-level streaming animations (like Vercel's Streamdown):

      <.markdown content={@response} streaming animate="fadeIn" />

  Available animations: `fadeIn` (default), `blurIn`, `slideUp`.

  Include the CSS in your app:

      @import "../../deps/phoenix_streamdown/priv/static/phoenix_streamdown.css";

  ## Customization

  ### Syntax highlighting theme

      <.markdown content={@md} theme="catppuccin_mocha" />

  Available themes: `onedark` (default), `dracula`, `github_dark`, `github_light`,
  `catppuccin_mocha`, `nord`, `tokyonight_night`, `vscode_dark`, and
  [100+ more](https://lumis.sh).

  Highlighting is an optional MDEx feature. It needs `mdex_native` compiled with Lumis
  and a parser package for the languages you highlight:

      # config/config.exs
      config :mdex_native, syntax_highlighter: :lumis

      # mix.exs
      {:lumis_wasm_elixir, "~> 0.26"}

  Without it, code blocks render unhighlighted instead of failing, and `theme` is
  ignored. Pass `theme={nil}` to turn highlighting off explicitly.

  ### CSS classes

      <.markdown content={@md} class="prose" block_class="mb-4" />

  ### Stable IDs

  `id` is required when `streaming: true`, and it has to stay the same across renders.
  LiveView matches nodes by DOM id, so an id that changes per render makes
  `phx-update="ignore"` a no-op and replaces the whole markdown subtree on every chunk:

      <.markdown content={@response} streaming id={"msg-\#{@message.id}"} />

  When not streaming, an id is generated for you.

  ## What "frozen" costs

  A completed block is rendered once and then frozen with `phx-update="ignore"`, so the
  client keeps the DOM it already has. If `Remend` guessed wrong about incomplete syntax,
  that rendering sticks until the block gets a new id. Fine for append-only LLM output,
  worth knowing when content can be corrected after the fact.

  ### MDEx options

  Options are deep-merged with defaults, so you only override what you need:

      <.markdown content={@md} mdex_opts={[extension: [shortcodes: true]]} />

  ## Why not just MDEx streaming?

  MDEx has its own `streaming: true` mode. PhoenixStreamdown adds:

  - **Block-level memoization** — only the last block re-renders per token
  - **Ready-made LiveView component** — drop in, pass content and streaming flag
  - **Remend** — strips partial links/images instead of rendering broken HTML
  - **Word-level animations** — fade-in/blur-in each new word as it streams
  """

  @doc """
  Imports the `markdown/1` component for use as `<.markdown />`.

      defmodule MyAppWeb.ChatLive do
        use MyAppWeb, :live_view
        use PhoenixStreamdown

        def render(assigns) do
          ~H\"\"\"
          <.markdown content={@response} streaming={@streaming?} id={"msg-\#{@message_id}"} />
          \"\"\"
        end
      end
  """
  defmacro __using__(_opts) do
    quote do
      import PhoenixStreamdown, only: [markdown: 1]
    end
  end

  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1, safe_to_string: 1]

  require Logger

  alias PhoenixStreamdown.Animate
  alias PhoenixStreamdown.Blocks
  alias PhoenixStreamdown.Remend

  @default_mdex_opts [
    extension: [
      strikethrough: true,
      table: true,
      autolink: true,
      tasklist: true
    ]
  ]

  @failed_syntax_highlight {__MODULE__, :failed_syntax_highlight}
  @logged_errors {__MODULE__, :logged_errors}

  @doc """
  Renders markdown content with streaming support.

  ## Attributes

    * `content` — the markdown string to render
    * `streaming` — whether content is still being streamed (enables incomplete syntax completion)
    * `animate` — animation type for streaming: `"fadeIn"`, `"blurIn"`, `"slideUp"`, or `nil` to disable
    * `class` — CSS class for the wrapper `<div>`
    * `block_class` — CSS class for each block `<div>`
    * `id` — id prefix; required when `streaming: true`, generated otherwise
    * `theme` — syntax highlighting theme name (default: `"onedark"`); `nil` disables highlighting
    * `mdex_opts` — options passed to `MDEx.to_html!/2` (merged with defaults)

  ## Examples

      <PhoenixStreamdown.markdown content="# Hello **world**" />

      <PhoenixStreamdown.markdown
        content={@response}
        streaming
        id={"msg-\#{@message.id}"}
        animate="blurIn"
        class="prose"
        theme="github_dark"
      />
  """
  attr :content, :string, default: ""
  attr :streaming, :boolean, default: false
  attr :animate, :string, default: nil
  attr :class, :any, default: nil
  attr :block_class, :any, default: nil
  attr :id, :string
  attr :theme, :string, default: "onedark"
  attr :mdex_opts, :list, default: []

  def markdown(assigns) do
    assigns = assign_stable_id(assigns)

    completed =
      if assigns.streaming do
        Remend.complete(assigns.content || "")
      else
        assigns.content || ""
      end

    blocks =
      completed
      |> Blocks.parse()
      |> Enum.with_index()

    mdex_opts = build_mdex_opts(assigns.mdex_opts, assigns.theme)
    last_idx = length(blocks) - 1
    animate? = assigns.streaming and is_binary(assigns.animate) and assigns.animate != ""

    prev_last_idx = track_previous_last_idx(assigns.id, last_idx, assigns.streaming)

    rendered_blocks =
      if animate? do
        render_animated_blocks(blocks, mdex_opts, last_idx, assigns.id, assigns.animate)
      else
        Process.delete({__MODULE__, assigns.id})

        Enum.map(blocks, fn {block, idx} ->
          {idx, render_block(block, mdex_opts), idx == last_idx}
        end)
      end

    assigns =
      assigns
      |> assign(:rendered_blocks, rendered_blocks)
      |> assign(:last_idx, last_idx)
      |> assign(:prev_last_idx, prev_last_idx)

    ~H"""
    <div class={["phoenix-streamdown", @class]} id={@id}>
      <div
        :for={{idx, html, is_last} <- @rendered_blocks}
        id={"#{@id}-block-#{idx}"}
        class={@block_class}
        phx-update={block_update(is_last, @streaming, idx, @prev_last_idx)}
      >
        {raw(html)}
      </div>
    </div>
    """
  end

  defp assign_stable_id(assigns) do
    cond do
      is_binary(assigns[:id]) ->
        assigns

      assigns.streaming ->
        raise ArgumentError, """
        <.markdown> requires an explicit `id` when `streaming: true`.

        A generated id changes on every render, so LiveView cannot reuse the existing
        blocks: `phx-update="ignore"` stops working and the whole markdown subtree is
        replaced on every chunk.

        Pass a value that is stable across renders, for example:

            <.markdown content={@response} streaming id={"msg-\#{@message.id}"} />
        """

      true ->
        assign_new(assigns, :id, fn -> "psd-#{System.unique_integer([:positive])}" end)
    end
  end

  defp track_previous_last_idx(id, last_idx, true) do
    key = {__MODULE__, :last_idx, id}
    previous = Process.get(key)
    Process.put(key, last_idx)
    previous
  end

  defp track_previous_last_idx(id, _last_idx, false) do
    Process.delete({__MODULE__, :last_idx, id})
    nil
  end

  # The last block during streaming is always live (no phx-update="ignore").
  defp block_update(true, true, _idx, _prev_last_idx), do: nil

  # A block that just transitioned from "last" to "not last" needs one
  # final DOM update before being frozen — otherwise its content is lost.
  defp block_update(false, true, idx, prev_last_idx)
       when is_integer(prev_last_idx) and idx >= prev_last_idx,
       do: nil

  # All other blocks are frozen.
  defp block_update(_is_last, _streaming, _idx, _prev_last_idx), do: "ignore"

  defp render_animated_blocks(blocks, mdex_opts, last_idx, id, animation) do
    pdict_key = {__MODULE__, id}
    {prev_block_idx, prev_chars} = Process.get(pdict_key, {0, 0})
    prev_chars = if prev_block_idx == last_idx, do: prev_chars, else: 0

    Enum.map(blocks, fn {block, idx} ->
      html = render_block(block, mdex_opts)

      if idx == last_idx do
        {animated, new_chars} = Animate.animate_words(html, prev_chars, animation: animation)
        Process.put(pdict_key, {last_idx, new_chars})
        {idx, animated, true}
      else
        {idx, html, false}
      end
    end)
  end

  defp build_mdex_opts(user_opts, theme) do
    @default_mdex_opts
    |> deep_merge(theme_opts(theme))
    |> deep_merge(user_opts)
  end

  defp theme_opts(nil), do: []

  defp theme_opts(theme) do
    syntax_highlight = [engine: :lumis, opts: [formatter: {:html_inline, theme: theme}]]

    if syntax_highlight_failed?(syntax_highlight) do
      []
    else
      [syntax_highlight: syntax_highlight]
    end
  end

  defp deep_merge(base, override) do
    Keyword.merge(base, override, fn _key, v1, v2 ->
      if Keyword.keyword?(v1) and Keyword.keyword?(v2) do
        deep_merge(v1, v2)
      else
        v2
      end
    end)
  end

  defp render_block(block, mdex_opts) do
    MDEx.to_html!(block, mdex_opts)
  rescue
    exception -> handle_render_error(block, mdex_opts, exception)
  end

  # The highlighter is optional (MDEx needs Lumis for it). Losing it must not cost
  # content, so retry the block without highlighting.
  defp handle_render_error(block, mdex_opts, exception) do
    case Keyword.get(mdex_opts, :syntax_highlight) do
      nil ->
        render_plain_text(block, exception)

      syntax_highlight ->
        retry_without_syntax_highlight(block, mdex_opts, syntax_highlight, exception)
    end
  end

  defp retry_without_syntax_highlight(block, mdex_opts, syntax_highlight, exception) do
    html = MDEx.to_html!(block, Keyword.delete(mdex_opts, :syntax_highlight))

    # It renders without the highlighter, so that was the problem. Stop asking
    # for it in this process instead of paying a failed render per block.
    disable_syntax_highlight(syntax_highlight, exception)
    html
  rescue
    retry_exception -> render_plain_text(block, retry_exception)
  end

  defp render_plain_text(block, exception) do
    log_once(
      :error,
      {:render, exception.__struct__, Exception.message(exception)},
      "PhoenixStreamdown could not render a markdown block with MDEx and fell back " <>
        "to escaped plain text (#{describe(exception)}). Block starts with: " <>
        inspect(String.slice(block, 0, 200))
    )

    "<p>#{block |> Phoenix.HTML.html_escape() |> safe_to_string()}</p>"
  end

  defp disable_syntax_highlight(syntax_highlight, exception) do
    failed = Process.get(@failed_syntax_highlight, MapSet.new())

    unless MapSet.member?(failed, syntax_highlight) do
      Process.put(@failed_syntax_highlight, MapSet.put(failed, syntax_highlight))

      log_once(
        :warning,
        {:syntax_highlight, syntax_highlight},
        "PhoenixStreamdown could not syntax highlight a code block and now renders " <>
          "code blocks without highlighting (#{describe(exception)}). See the docs for " <>
          "enabling Lumis."
      )
    end
  end

  defp syntax_highlight_failed?(syntax_highlight) do
    failed = Process.get(@failed_syntax_highlight, MapSet.new())
    MapSet.member?(failed, syntax_highlight)
  end

  defp describe(exception) do
    "#{inspect(exception.__struct__)}: #{Exception.message(exception)}"
  end

  defp log_once(level, signature, message) do
    logged = Process.get(@logged_errors, MapSet.new())

    unless MapSet.member?(logged, signature) do
      Process.put(@logged_errors, MapSet.put(logged, signature))
      Logger.log(level, message)
    end
  end
end
