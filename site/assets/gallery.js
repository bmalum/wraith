// The theme gallery: pick a theme and a view, the frame shows that screenshot.
// Without JavaScript the <noscript> list links every screenshot instead.
(() => {
  const root = document.querySelector("[data-gallery]");
  if (!root) return;

  const img = root.querySelector(".frame-scroll img");
  const scroller = root.querySelector(".frame-scroll");
  const frame = root.querySelector(".frame");
  const capName = root.querySelector("[data-cap-name]");
  const capLayout = root.querySelector("[data-cap-layout]");
  const capDesc = root.querySelector("[data-cap-desc]");
  const chips = [...root.querySelectorAll("[data-theme]")];
  const viewButtons = [...root.querySelectorAll("[data-view-option]")];
  const viewNames = { home: "front page", post: "a post", mobile: "on a phone" };

  let theme = root.dataset.initialTheme;
  let view = root.dataset.initialView;
  const src = (t, v) => `shots/${t}-${v}.webp`;

  root.hidden = false;

  function show() {
    const chip = chips.find((c) => c.dataset.theme === theme);
    if (img.getAttribute("src") !== src(theme, view)) {
      img.classList.add("is-loading");
      img.src = src(theme, view);
    }
    img.alt = `The ${chip.dataset.label} theme, ${viewNames[view]}`;
    capName.textContent = chip.dataset.label;
    capLayout.textContent = chip.dataset.layout;
    capDesc.textContent = chip.dataset.desc;
    frame.dataset.view = view;
    scroller.scrollTop = 0;
    chips.forEach((c) => c.setAttribute("aria-pressed", String(c === chip)));
    viewButtons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.viewOption === view)));
  }

  img.addEventListener("load", () => img.classList.remove("is-loading"));
  img.addEventListener("error", () => img.classList.remove("is-loading"));

  chips.forEach((c) => {
    c.addEventListener("click", () => {
      theme = c.dataset.theme;
      show();
    });
    // warm the cache for the shot a pointer is about to pick
    c.addEventListener("pointerenter", () => {
      new Image().src = src(c.dataset.theme, view);
    });
  });

  viewButtons.forEach((b) =>
    b.addEventListener("click", () => {
      view = b.dataset.viewOption;
      show();
    })
  );

  show();
})();
