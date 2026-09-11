document.querySelectorAll("[data-copy]").forEach(function (btn) {
  btn.addEventListener("click", function () {
    var el = document.getElementById(btn.getAttribute("data-copy"));
    if (!el) return;
    navigator.clipboard.writeText(el.innerText).then(function () {
      var old = btn.innerText; btn.innerText = "copied!";
      setTimeout(function () { btn.innerText = old; }, 1200);
    });
  });
});

/* docs sidebar: injected on documentation pages only */
(function () {
  var GROUPS = [
    { h: "Start", links: [["getting-started.html", "5-minute start"], ["install.html", "Installation"], ["tutorial.html", "Tutorial: guess the word"], ["examples.html", "Examples"], ["faq.html", "FAQ"]] },
    { h: "Reference", links: [["docs-syntax.html", "1 · Syntax & math"], ["docs-control.html", "2 · Control & functions"], ["docs-data.html", "3 · Data & I/O"], ["docs-system.html", "4 · System"], ["cli.html", "CLI reference"], ["formats.html", "File formats"]] },
    { h: "Internals", links: [["isa.html", "Bytecode ISA"], ["errors.html", "Error catalog"], ["style.html", "Style guide"], ["perf.html", "Performance"]] },
    { h: "Project", links: [["changelog.html", "Changelog"], ["archive.html", "Archive"], ["support.html", "Support"], ["vscode.html", "VS Code"], ["scoop.html", "Scoop"]] }
  ];
  var DOCS = ["getting-started.html", "install.html", "tutorial.html", "examples.html", "faq.html",
    "docs.html", "docs-syntax.html", "docs-control.html", "docs-data.html", "docs-system.html",
    "cli.html", "formats.html", "isa.html", "errors.html", "style.html", "perf.html",
    "changelog.html", "archive.html", "support.html", "vscode.html", "scoop.html"];
  var page = (location.pathname.split("/").pop() || "index.html").split("?")[0].split("#")[0];
  if (DOCS.indexOf(page) === -1) return;
  document.body.classList.add("has-side");
  var aside = document.createElement("aside");
  aside.className = "side";
  var html = "";
  GROUPS.forEach(function (g) {
    html += "<h4>" + g.h + "</h4>";
    g.links.forEach(function (l) {
      html += '<a href="' + l[0] + '"' + (l[0] === page ? ' class="on"' : "") + ">" + l[1] + "</a>";
    });
  });
  aside.innerHTML = html;
  document.body.appendChild(aside);
  var btn = document.createElement("button");
  btn.className = "side-toggle";
  btn.innerText = "☰ Docs";
  btn.addEventListener("click", function () { document.body.classList.toggle("side-open"); });
  document.body.appendChild(btn);
})();
