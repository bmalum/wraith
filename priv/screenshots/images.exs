# Writes six abstract SVG feature images to priv/static/images/demo/ so the
# screenshot seed has pictures without touching the network.
dir = Path.join([:code.priv_dir(:wraith), "static", "images", "demo"])
File.mkdir_p!(dir)

pics = [
  {"night", "#0b1220", "#2a3a6e", "#e0b84d"},
  {"ember", "#3a1010", "#b03a1e", "#ffb347"},
  {"moss", "#10261b", "#2f6f4a", "#cfe9b6"},
  {"dusk", "#2a1f3d", "#7a4b9e", "#f2a7c3"},
  {"sea", "#07263a", "#1b6f8a", "#9fe3f0"},
  {"sand", "#4a3a22", "#a67c3a", "#f3e2b8"}
]

for {name, a, b, c} <- pics do
  svg = """
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 1000">
    <defs>
      <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#{a}"/><stop offset="1" stop-color="#{b}"/>
      </linearGradient>
      <radialGradient id="r" cx="0.75" cy="0.3" r="0.6">
        <stop offset="0" stop-color="#{c}" stop-opacity="0.9"/><stop offset="1" stop-color="#{c}" stop-opacity="0"/>
      </radialGradient>
    </defs>
    <rect width="1600" height="1000" fill="url(#g)"/>
    <rect width="1600" height="1000" fill="url(#r)"/>
    <circle cx="1180" cy="300" r="140" fill="#{c}" fill-opacity="0.85"/>
    <path d="M0 760 C 300 640, 520 900, 900 760 S 1400 620, 1600 740 V1000 H0Z" fill="#{a}" fill-opacity="0.55"/>
    <path d="M0 850 C 400 760, 700 980, 1100 860 S 1450 780, 1600 860 V1000 H0Z" fill="#{b}" fill-opacity="0.6"/>
  </svg>
  """

  File.write!(Path.join(dir, name <> ".svg"), svg)
end

IO.puts("images: #{length(pics)}")
