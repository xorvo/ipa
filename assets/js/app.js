// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/ipa"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Custom hooks for LiveView components
const Hooks = {
  // Auto-scroll hook for terminal/streaming output containers
  AutoScroll: {
    mounted() {
      this.scrollToBottom()
      // Use MutationObserver to detect content changes
      this.observer = new MutationObserver(() => {
        this.scrollToBottom()
      })
      this.observer.observe(this.el, { childList: true, subtree: true, characterData: true })
    },
    updated() {
      this.scrollToBottom()
    },
    destroyed() {
      if (this.observer) {
        this.observer.disconnect()
      }
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    }
  },

  // Markdown rendering with syntax highlighting
  Markdown: {
    mounted() {
      this.render()
    },
    updated() {
      this.render()
    },
    render() {
      const content = this.el.dataset.content
      if (!content || !window.marked) return

      // Configure marked with highlight.js
      marked.setOptions({
        highlight: function(code, lang) {
          if (window.hljs && lang && hljs.getLanguage(lang)) {
            try {
              return hljs.highlight(code, { language: lang }).value
            } catch (e) {}
          }
          if (window.hljs) {
            try {
              return hljs.highlightAuto(code).value
            } catch (e) {}
          }
          return code
        },
        breaks: true,
        gfm: true
      })

      // Render markdown
      this.el.innerHTML = marked.parse(content)

      // Apply highlight.js to any code blocks that weren't caught
      if (window.hljs) {
        this.el.querySelectorAll('pre code').forEach((block) => {
          if (!block.classList.contains('hljs')) {
            hljs.highlightElement(block)
          }
        })
      }
    }
  },

  // Collapsible section for tool calls
  Collapsible: {
    mounted() {
      const toggle = this.el.querySelector('[data-collapse-toggle]')
      const content = this.el.querySelector('[data-collapse-content]')
      const iconWrapper = this.el.querySelector('[data-collapse-icon-wrapper]')

      if (toggle && content) {
        // Start collapsed by default
        content.style.display = 'none'

        toggle.addEventListener('click', () => {
          const isHidden = content.style.display === 'none'
          content.style.display = isHidden ? 'block' : 'none'
          if (iconWrapper) {
            // Rotate the wrapper (which contains the chevron icon)
            iconWrapper.style.transform = isHidden ? 'rotate(90deg)' : 'rotate(0deg)'
            // Keep icon visible when expanded
            const icon = iconWrapper.querySelector('span, svg')
            if (icon) {
              icon.style.opacity = isHidden ? '1' : ''
            }
          }
        })
      }
    }
  },

  // Diff viewer using diff2html
  DiffView: {
    mounted() {
      this.render()
    },
    updated() {
      this.render()
    },
    render() {
      const oldStr = this.el.dataset.oldString || ''
      const newStr = this.el.dataset.newString || ''
      const filePath = this.el.dataset.filePath || 'file'

      if (!window.Diff2Html) return

      // Create unified diff format
      const diff = this.createUnifiedDiff(oldStr, newStr, filePath)

      // Render with diff2html
      const html = Diff2Html.html(diff, {
        drawFileList: false,
        matching: 'lines',
        outputFormat: 'line-by-line',
        renderNothingWhenEmpty: false
      })

      this.el.innerHTML = html
    },
    createUnifiedDiff(oldStr, newStr, fileName) {
      // Simple line-by-line diff creation
      const oldLines = oldStr.split('\n')
      const newLines = newStr.split('\n')

      let diff = `--- a/${fileName}\n+++ b/${fileName}\n@@ -1,${oldLines.length} +1,${newLines.length} @@\n`

      // For simplicity, just show removed and added
      oldLines.forEach(line => {
        if (line) diff += `-${line}\n`
      })
      newLines.forEach(line => {
        if (line) diff += `+${line}\n`
      })

      return diff
    }
  },

  // Open in editor link handler
  EditorLink: {
    mounted() {
      this.el.addEventListener('click', (e) => {
        e.preventDefault()
        const path = this.el.dataset.path
        const line = this.el.dataset.line || '1'

        // Send event to LiveView to open in editor
        this.pushEvent('open_in_editor', { path: path, line: line })
      })
    }
  }
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Copy to clipboard handler for phx:copy event
window.addEventListener("phx:copy", (event) => {
  const text = event.target.value
  if (text) {
    navigator.clipboard.writeText(text).then(() => {
      // Optional: Show brief feedback
      const originalTip = event.target.closest('.tooltip')?.dataset?.tip
      if (originalTip) {
        event.target.closest('.tooltip').dataset.tip = "Copied!"
        setTimeout(() => {
          event.target.closest('.tooltip').dataset.tip = originalTip
        }, 1500)
      }
    }).catch(err => {
      console.error('Failed to copy: ', err)
    })
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

