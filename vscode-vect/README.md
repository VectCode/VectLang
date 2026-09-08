# Vect for VS Code

Language support for **Vect** (`.vt`, `.vth`) — ultra-compact low-level language.
https://vect.onrender.com

## Features

- Syntax highlighting (TextMate grammar)
- `cmt` comment toggling + auto-indent rules
- Snippets: `vheader` `vectfn` `vif` `vlo` `vlow` `vmath` `varr` `vfile` `vecho`

## Try it (no publishing needed)

1. Open this folder in VS Code.
2. Press `F5` — an Extension Development Host opens with Vect enabled.
3. Open any `.vt` file.

## Publish to Marketplace (maintainer)

```powershell
npm install -g @vscode/vsce
vsce package        # builds vect-0.2.1.vsix
vsce publish        # needs publisher "merixcipher" (Microsoft account)
```

## Files

| File | What |
| ---- | ---- |
| `package.json` | Extension manifest |
| `syntaxes/vect.tmLanguage.json` | Highlighting grammar |
| `language-configuration.json` | Comments, brackets, indent |
| `snippets/vect.json` | Code snippets |
