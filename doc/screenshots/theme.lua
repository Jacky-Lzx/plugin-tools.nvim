-- Capture-session appearance only; plugin layouts and highlights stay native.
vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.showmode = false
vim.o.ruler = false
vim.o.showcmd = false
vim.o.fillchars = "eob: "
vim.o.shortmess = "filnxtToOFc"
vim.o.guicursor = "a:ver15-blinkon0"
vim.o.background = "dark"
local groups = {
  Normal = { fg = "#c0caf5", bg = "#161923" },
  NormalFloat = { fg = "#c0caf5", bg = "#1e2230" },
  FloatBorder = { fg = "#626e97", bg = "#1e2230" },
  FloatTitle = { fg = "#7aa2f7", bg = "#1e2230", bold = true },
  FloatFooter = { fg = "#7b86ad", bg = "#1e2230" },
  CursorLine = { bg = "#2b3248" },
  Comment = { fg = "#8993b5" },
  Special = { fg = "#bb9af7" },
  Number = { fg = "#e0af68" },
  Directory = { fg = "#7dcfff" },
  Visual = { bg = "#293b42" },
  DiagnosticOk = { fg = "#9ece6a" },
  DiagnosticInfo = { fg = "#7aa2f7" },
  DiagnosticWarn = { fg = "#e0af68" },
  DiagnosticError = { fg = "#f7768e" },
}
for group, value in pairs(groups) do
  vim.api.nvim_set_hl(0, group, value)
end
