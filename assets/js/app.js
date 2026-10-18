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
import {hooks as colocatedHooks} from "phoenix-colocated/wraith"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// The post and widget editors: the server can replace the textarea's text
// (`editor:set`, after inserting a snippet or loading a version); Tab
// indents instead of leaving the field; ⌘S / Ctrl-S saves.
const Editor = {
  mounted() {
    const area = this.el.querySelector("textarea")
    this.handleEvent("editor:insert", ({text}) => {
      if (!area) return
      const s = area.selectionStart ?? area.value.length, e = area.selectionEnd ?? s
      area.value = area.value.slice(0, s) + text + area.value.slice(e)
      area.selectionStart = area.selectionEnd = s + text.length
      area.dispatchEvent(new Event("input", {bubbles: true}))
      area.focus()
    })
    this.handleEvent("editor:set", ({markdown, source}) => {
      if (!area) return
      area.value = markdown ?? source ?? area.value
      area.dispatchEvent(new Event("input", {bubbles: true}))
      area.focus()
      area.selectionStart = area.selectionEnd = area.value.length
    })
    area?.addEventListener("keydown", (e) => {
      if (e.key === "Tab") {
        e.preventDefault()
        const s = area.selectionStart, end = area.selectionEnd
        area.value = area.value.slice(0, s) + "  " + area.value.slice(end)
        area.selectionStart = area.selectionEnd = s + 2
        area.dispatchEvent(new Event("input", {bubbles: true}))
      }
    })
    this.el.addEventListener("keydown", (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "s") {
        e.preventDefault()
        const save = this.el.querySelector("[phx-click='save']")
        save?.click()
      }
    })
  }
}

// The studio transcript sticks to the bottom as entries stream in; Enter in
// the composer sends (Shift-Enter for a newline).
const ScrollBottom = {
  mounted() { this.scroll(); this.observer = new MutationObserver(() => this.scroll()); this.observer.observe(this.el, {childList: true, subtree: true, characterData: true}) },
  destroyed() { this.observer?.disconnect() },
  scroll() { const near = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 160; if (near || !this.scrolledOnce) { this.el.scrollTop = this.el.scrollHeight; this.scrolledOnce = true } }
}
document.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && e.target.matches("#composer textarea")) {
    e.preventDefault()
    e.target.form.requestSubmit()
  }
})

// light / dark: the choice lives in localStorage and is applied before paint by root.html.heex
window.addEventListener("wraith:toggle-mode", () => {
  const html = document.documentElement
  const dark = html.dataset.mode === "dark" || (!html.dataset.mode && matchMedia("(prefers-color-scheme: dark)").matches)
  html.dataset.mode = dark ? "light" : "dark"
  localStorage.setItem("wraith:mode", html.dataset.mode)
})

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, Editor, ScrollBottom},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

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
    window.addEventListener("keyup", _e => keyDown = null)
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

