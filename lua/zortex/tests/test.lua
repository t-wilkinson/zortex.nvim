-- tests/phase1_spec.lua
-- Test suite for Phase 1 components using busted/plenary
local M = {}

-- Mock config.get("obals") for testing
local function setup_vim_mocks()
  _G.vim = _G.vim or {}
  config.get("")= config.get("or") {}
  vim.api = vim.api or {}
  vim.fn = vim.fn or {}
  vim.loop = vim.loop or {}
  vim.schedule = vim.schedule or function(fn) fn() end
  vim.notify = vim.notify or print
  vim.log = vim.log or { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } }
  vim.loop.hrtime = vim.loop.hrtime or function() return os.clock() * 1e9 end
  vim.tbl_extend = vim.tbl_extend or function(mode, ...)
    local result = {}
    for i = 1, select('#', ...) do
      local t = select(i, ...)
      for k, v in pairs(t) do
        result[k] = v
      end
    end
    return result
  end
  vim.tbl_count = vim.tbl_count or function(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
  end
  vim.inspect = vim.inspect or tostring
end

-- EventBus Tests
M.test_eventbus = function()
  setup_vim_mocks()
  
  describe("EventBus", function()
    local EventBus = require("zortex.core.event_bus")
    
    before_each(function()
      EventBus.clear()
    end)
    
    it("should emit and handle events", function()
      local called = false
      local received_data = nil
      
      EventBus.on("test:event", function(data)
        called = true
        received_data = data
      end)
      
      EventBus.emit("test:event", { value = 42 })
      
      -- Wait for async execution
      vim.wait(10, function() return called end)
      
      assert.is_true(called)
      assert.equals(42, received_data.value)
    end)
    
    it("should respect priority order", function()
      local order = {}
      
      EventBus.on("test:priority", function()
        table.insert(order, "low")
      end, { priority = 10 })
      
      EventBus.on("test:priority", function()
        table.insert(order, "high")
      end, { priority = 90 })
      
      EventBus.on("test:priority", function()
        table.insert(order, "medium")
      end, { priority = 50 })
      
      EventBus.emit("test:priority", {}, { sync = true })
      
      assert.same({ "high", "medium", "low" }, order)
    end)
    
    it("should handle handler removal", function()
      local count = 0
      local handler = function() count = count + 1 end
      
      EventBus.on("test:remove", handler)
      EventBus.emit("test:remove", {}, { sync = true })
      assert.equals(1, count)
      
      EventBus.off("test:remove", handler)
      EventBus.emit("test:remove", {}, { sync = true })
      assert.equals(1, count) -- Should not increase
    end)
    
    it("should apply middleware", function()
      local middleware_called = false
      
      EventBus.add_middleware(function(event, data)
        middleware_called = true
        data.modified = true
        return true, data
      end)
      
      local received_data = nil
      EventBus.on("test:middleware", function(data)
        received_data = data
      end)
      
      EventBus.emit("test:middleware", { original = true }, { sync = true })
      
      assert.is_true(middleware_called)
      assert.is_true(received_data.original)
      assert.is_true(received_data.modified)
    end)
    
    it("should track performance", function()
      EventBus.on("test:perf", function()
        -- Simulate some work
        local sum = 0
        for i = 1, 1000 do sum = sum + i end
      end, { max_time = 1 })
      
      EventBus.emit("test:perf", {}, { sync = true })
      
      local report = EventBus.get_performance_report()
      assert.is_not_nil(report["test:perf"])
      assert.equals(1, report["test:perf"].count)
      assert.is_true(report["test:perf"].avg_time >= 0)
    end)
  end)
end

-- Section Model Tests
M.test_section = function()
  setup_vim_mocks()
  
  describe("Section", function()
    local Section = require("zortex.core.section")
    local constants = require("zortex.constants")
    
    it("should create sections with correct properties", function()
      local section = Section.Section:new({
        type = constants.SECTION_TYPE.HEADING,
        text = "Test Section",
        level = 2,
        start_line = 10,
        end_line = 20,
      })
      
      assert.equals(constants.SECTION_TYPE.HEADING, section.type)
      assert.equals("Test Section", section.text)
      assert.equals(2, section.level)
      assert.equals(10, section.start_line)
      assert.equals(20, section.end_line)
    end)
    
    it("should manage parent-child relationships", function()
      local parent = Section.Section:new({
        type = constants.SECTION_TYPE.HEADING,
        text = "Parent",
        level = 1,
      })
      
      local child = Section.Section:new({
        type = constants.SECTION_TYPE.HEADING,
        text = "Child",
        level = 2,
      })
      
      parent:add_child(child)
      
      assert.equals(parent, child.parent)
      assert.equals(1, #parent.children)
      assert.equals(child, parent.children[1])
    end)
    
    it("should check containment rules", function()
      local article = Section.Section:new({
        type = constants.SECTION_TYPE.ARTICLE,
      })
      
      local h1 = Section.Section:new({
        type = constants.SECTION_TYPE.HEADING,
        level = 1,
      })
      
      local h2 = Section.Section:new({
        type = constants.SECTION_TYPE.HEADING,
        level = 2,
      })
      
      local label = Section.Section:new({
        type = constants.SECTION_TYPE.LABEL,
      })
      
      assert.is_true(article:can_contain(h1))
      assert.is_true(h1:can_contain(h2))
      assert.is_true(h2:can_contain(label))
      assert.is_false(label:can_contain(h1))
      assert.is_false(h2:can_contain(h1))
    end)
    
    it("should build section paths", function()
      local root = Section.Section:new({ text = "Root" })
      local parent = Section.Section:new({ text = "Parent" })
      local child = Section.Section:new({ text = "Child" })
      
      root:add_child(parent)
      parent:add_child(child)
      
      local path = child:get_path()
      assert.equals(2, #path)
      assert.equals(root, path[1])
      assert.equals(parent, path[2])
      
      assert.equals("Root > Parent > Child", child:get_breadcrumb())
    end)
    
    it("should find sections at lines", function()
      local root = Section.Section:new({
        start_line = 1,
        end_line = 100,
      })
      
      local child1 = Section.Section:new({
        text = "Child 1",
        start_line = 10,
        end_line = 30,
      })
      
      local child2 = Section.Section:new({
        text = "Child 2", 
        start_line = 31,
        end_line = 50,
      })
      
      local grandchild = Section.Section:new({
        text = "Grandchild",
        start_line = 15,
        end_line = 20,
      })
      
      root:add_child(child1)
      root:add_child(child2)
      child1:add_child(grandchild)
      
      assert.equals(grandchild, root:find_child_at_line(17))
      assert.equals(child1, root:find_child_at_line(25))
      assert.equals(child2, root:find_child_at_line(40))
      assert.is_nil(root:find_child_at_line(60))
    end)
  end)
end

-- Document Manager Tests
M.test_document_manager = function()
  setup_vim_mocks()
  
  describe("DocumentManager", function()
    local DocumentManager = require("zortex.core.document_manager")
    local test_lines = {
      "@@Test Article",
      "@todo @important",
      "",
      "# Section One",
      "- [ ] Task one @id(task1) @size(md)",
      "- [x] Task two @id(task2) @done(2024-01-15)",
      "",
      "## Subsection",
      "Some content",
      "",
      "**Bold Section:**",
      "- [ ] Task three @id(task3)",
    }
    
    -- Mock buffer functions
    vim.api.nvim_buf_get_lines = function(bufnr, start_line, end_line, strict)
      return test_lines
    end
    
    vim.api.nconfig.get("t_current_buf") = function()
      return 1
    end
    
    it("should parse document structure", function()
      local doc = DocumentManager._instance:load_buffer(1, "test.zortex")
      
      assert.is_not_nil(doc)
      assert.equals("Test Article", doc.article_name)
      assert.equals(2, #doc.tags)
      assert.is_true(doc.stats.sections > 0)
      assert.equals(3, doc.stats.tasks)
      assert.equals(1, doc.stats.completed)
    end)
    
    it("should build section tree", function()
      local doc = DocumentManager._instance:load_buffer(1, "test.zortex")
      
      assert.is_not_nil(doc.sections)
      
      -- Should have article root with sections as children
      local sections = doc.sections.children
      assert.is_true(#sections > 0)
      
      -- First section should be "Section One"
      local section1 = sections[1]
      assert.equals("Section One", section1.text)
      assert.equals(1, section1.level)
      
      -- Should have subsection
      assert.is_true(#section1.children > 0)
      local subsection = section1.children[1]
      assert.equals("Subsection", subsection.text)
      assert.equals(2, subsection.level)
    end)
    
    it("should create line map", function()
      local doc = DocumentManager._instance:load_buffer(1, "test.zortex")
      
      -- Line 5 should be in "Section One"
      local section = doc:get_section_at_line(5)
      assert.is_not_nil(section)
      assert.equals("Section One", section.text)
      
      -- Line 9 should be in "Subsection"
      section = doc:get_section_at_line(9)
      assert.is_not_nil(section)
      assert.equals("Subsection", section.text)
    end)
    
    it("should parse tasks", function()
      local doc = DocumentManager._instance:load_buffer(1, "test.zortex")
      
      local tasks = doc:get_all_tasks()
      assert.equals(3, #tasks)
      
      -- Check task properties
      local task1 = tasks[1]
      assert.equals("Task one", task1.text)
      assert.is_false(task1.completed)
      assert.equals("task1", task1.attributes.id)
      assert.equals("md", task1.attributes.size)
      
      local task2 = tasks[2]
      assert.is_true(task2.completed)
      assert.equals("2024-01-15", task2.attributes.done)
    end)
    
    it("should handle document updates", function()
      local doc = DocumentManager._instance:load_buffer(1, "test.zortex")
      
      -- Update a task
      local success = doc:update_task("task1", { completed = true })
      assert.is_true(success)
      
      local task = doc:get_task("task1")
      assert.is_true(task.completed)
      
      -- Should mark as dirty
      assert.equals(1, #doc.dirty_ranges)
      assert.equals(task.line, doc.dirty_ranges[1][1])
    end)
  end)
end

-- Logger Tests
M.test_logger = function()
  setup_vim_mocks()
  
  describe("Logger", function()
    local Logger = require("zortex.core.logger")
    
    before_each(function()
      Logger.clear_logs()
      Logger.enable()
    end)
    
    it("should log messages at different levels", function()
      Logger.debug("test", "Debug message")
      Logger.info("test", "Info message")
      Logger.warn("test", "Warning message")
      Logger.error("test", "Error message")
      
      local logs = Logger.get_recent_logs(10)
      assert.equals(4, #logs)
    end)
    
    it("should respect log level", function()
      Logger.set_level("WARN")
      
      Logger.debug("test", "Debug - should not appear")
      Logger.info("test", "Info - should not appear")
      Logger.warn("test", "Warning - should appear")
      Logger.error("test", "Error - should appear")
      
      local logs = Logger.get_recent_logs(10)
      assert.equals(2, #logs)
    end)
    
    it("should track performance", function()
      local stop = Logger.start_timer("test_operation")
      
      -- Simulate work
      local sum = 0
      for i = 1, 10000 do sum = sum + i end
      
      local elapsed = stop()
      assert.is_true(elapsed >= 0)
      
      local report = Logger.get_performance_report()
      assert.is_not_nil(report.test_operation)
      assert.equals(1, report.test_operation.count)
    end)
    
    it("should wrap functions", function()
      local call_count = 0
      local test_fn = function(a, b)
        call_count = call_count + 1
        return a + b
      end
      
      local wrapped = Logger.wrap_function("wrapped_fn", test_fn)
      local result = wrapped(5, 3)
      
      assert.equals(8, result)
      assert.equals(1, call_count)
      
      local report = Logger.get_performance_report()
      assert.is_not_nil(report.wrapped_fn)
    end)
  end)
end

-- Integration Tests
M.test_integration = function()
  setup_vim_mocks()
  
  describe("Phase 1 Integration", function()
    local Phase1 = require("zortex.core.phase1_init")
    local EventBus = require("zortex.core.event_bus")
    local DocumentManager = require("zortex.core.document_manager")
    
    it("should initialize all components", function()
      local ok = Phase1.init({
        debug = true,
        log_level = "DEBUG",
      })
      
      assert.is_true(ok)
      assert.is_true(Phase1.initialized)
      assert.is_true(Phase1.components.event_bus)
      assert.is_true(Phase1.components.document_manager)
      assert.is_true(Phase1.components.logger)
    end)
    
    it("should emit initialization event", function()
      local init_called = false
      
      EventBus.on("phase1:initialized", function(data)
        init_called = true
      end)
      
      Phase1.init()
      
      vim.wait(10, function() return init_called end)
      assert.is_true(init_called)
    end)
    
    it("should provide healthcheck", function()
      Phase1.init()
      
      local health = Phase1.healthcheck()
      assert.is_not_nil(health)
      assert.is_true(health.initialized)
      assert.is_not_nil(health.components)
      assert.is_not_nil(health.documents)
      assert.is_not_nil(health.events)
      assert.is_not_nil(health.performance)
    end)
  end)
end

-- Run all tests
function M.run_all()
  M.test_eventbus()
  M.test_section()
  M.test_document_manager()
  M.test_logger()
  M.test_integration()
  print("All Phase 1 tests completed!")
end

return M