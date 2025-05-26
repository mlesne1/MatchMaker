-- Maid
-- Author: Quenty
-- Source: https://github.com/Quenty/NevermoreEngine/blob/version2/Modules/Shared/Events/Maid.lua
-- License: MIT (https://github.com/Quenty/NevermoreEngine/blob/version2/LICENSE.AP)
-- This module has been modified for use in AeroGameFramework

--[[

	maid = Maid.new()

	maid:GiveTask(task)
		> task is an event connection, function, or instance/table with a 'Destroy' method

	maid:GivePromise(promise)
	
	maid:DoCleaning()
		> Alias for Destroy
	
	maid:Destroy()
		> Goes through each task & disconnects events, destroys instances, and calls functions

--]]

---	Manages the cleaning of events and other things.
-- Useful for encapsulating state and make deconstructors easy
-- @classmod Maid
-- @see Signal

local Maid = {}
Maid.ClassName = "Maid"

local Promise


--- Returns a new Maid object
-- @constructor Maid.new()
-- @treturn Maid
function Maid.new()
	local self = setmetatable({
		_tasks = {};
	}, Maid)
	return self
end


--- Returns Maid[key] if not part of Maid metatable
-- @return Maid[key] value
function Maid:__index(index)
	if (Maid[index]) then
		return Maid[index]
	else
		return self._tasks[index]
	end
end


--- Add a task to clean up
-- @usage
-- Maid[key] = (function)         Adds a task to perform
-- Maid[key] = (event connection) Manages an event connection
-- Maid[key] = (Maid)             Maids can act as an event connection, allowing a Maid to have other maids to clean up.
-- Maid[key] = (Object)           Maids can cleanup objects with a `Destroy` method
-- Maid[key] = nil                Removes a named task. If the task is an event, it is disconnected. If it is an object,
--                                it is destroyed.
function Maid:__newindex(index, newTask)
	if (Maid[index] ~= nil) then
		error(("'%s' is reserved"):format(tostring(index)), 2)
	end

	local tasks = self._tasks
	local oldTask = tasks[index]
	tasks[index] = newTask

	if (oldTask) then
		if (type(oldTask) == "function") then
			oldTask()
		elseif (typeof(oldTask) == "RBXScriptConnection") then
			oldTask:Disconnect()
		elseif (oldTask.Destroy) then
			oldTask:Destroy()
		end
	end
end


--- Same as indexing, but uses an incremented number as a key.
-- @param task An item to clean
-- @treturn number taskId
function Maid:GiveTask(_task, ID)
	assert(_task, "Task cannot be false or nil")

	local taskId = ID or (#self._tasks + 1)
	self[taskId] = _task

	if (type(_task) == "table" and (not _task.Destroy)) then
		warn("[Maid.GiveTask] - Gave table task without .Destroy\n\n" .. debug.traceback())
	end

	return _task, taskId
end


function Maid:GivePromise(promise)
	if (promise:GetStatus() ~= Promise.Status.Started) then
		return promise
	end

	local newPromise = Promise.Resolve(promise)
	local id = self:GiveTask(newPromise)

	-- Ensure GC
	newPromise:Finally(function()
		self[id] = nil
	end)

	return newPromise
end


--- Cleans up all tasks.
-- @alias Destroy
function Maid:DoCleaning()

	--print("Maid is cleaning ...", self)

	local tasks = self._tasks

	-- Disconnect all events first as we know this is safe
	for index, _task in pairs(tasks) do
		if (typeof(_task) == "RBXScriptConnection") then
			tasks[index] = nil
			_task:Disconnect()
		end
	end

	-- Clear out tasks table completely, even if clean up tasks add more tasks to the maid
	local index, _task = next(tasks)
	while (_task ~= nil) do
		tasks[index] = nil
		if (type(_task) == "function") then
			_task()
		elseif (typeof(_task) == "RBXScriptConnection") then
			_task:Disconnect()
		elseif (_task.Destroy) then
			_task:Destroy()
		end
		index, _task = next(tasks)
	end
end


function Maid:Init()
	Promise = self.Shared.Promise
end

--- Alias for DoCleaning()
-- @function Destroy
Maid.Destroy = Maid.DoCleaning

return Maid