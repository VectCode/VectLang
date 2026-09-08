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
