local H = { count = 0 }
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
H.root = root
vim.opt.runtimepath:prepend(vim.fn.getcwd())

function H.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
end

function H.eq(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

function H.raises(fn, pattern)
  local ok, err = pcall(fn)
  assert(not ok and tostring(err):find(pattern, 1, true), "expected error " .. pattern .. ", got " .. tostring(err))
end

function H.case(name, fn)
  fn()
  H.count = H.count + 1
  print("PASS " .. name)
end

function H.git(dir, ...)
  local cmd = { "git", "-C", dir }
  vim.list_extend(cmd, { ... })
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end

function H.repo(name)
  local dir = root .. "/" .. name
  vim.fn.mkdir(dir, "p")
  H.git(dir, "init", "-q", "-b", "main")
  H.git(dir, "config", "user.name", "Plugin Tools Test")
  H.git(dir, "config", "user.email", "plugin-tools@example.invalid")
  H.git(dir, "config", "commit.gpgsign", "false")
  H.write(dir .. "/lua/" .. name .. ".lua", "return { setup = function() end }")
  H.commit(dir, "initial")
  return dir
end

function H.commit(dir, text)
  H.git(dir, "add", "-A")
  H.git(dir, "commit", "-qm", text)
  return H.git(dir, "rev-parse", "HEAD")
end

function H.wait(task, expect_error)
  local result, err = task:wait(30000)
  assert(task.done, tostring(err))
  if expect_error then
    assert(err and err:find(expect_error, 1, true), "expected " .. expect_error .. ", got " .. tostring(err))
  else
    assert(result and not err, tostring(err))
  end
  return result, err
end

function H.finish()
  vim.fn.delete(root, "rf")
  print(("%d cases passed"):format(H.count))
end

return H
