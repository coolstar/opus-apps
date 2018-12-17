local Config  = require('config')
local Event   = require('event')
local Project = require('neural.project')
local UI      = require('ui')
local Util    = require('util')

local device     = _G.device
local peripheral = _G.peripheral

local ni = device.neuralInterface
local sensor = ni or device['plethora:sensor'] or peripheral.find('manipulator')
if not sensor or not sensor.sense then
	error('Plethora sensor must be equipped')
end

UI:configure('Entities', ...)

local config = Config.load('Entities', { })

local page = UI.Page {
	menuBar = UI.MenuBar {
		buttons = {
			{ text = 'Project', event = 'project' },
		},
	},
	grid = UI.ScrollingGrid {
		columns = {
			{ heading = 'Name', key = 'displayName' },
			{ heading = '  X',    key = 'x', width = 3, justify = 'right' },
			{ heading = '  Y',    key = 'y', width = 3, justify = 'right' },
			{ heading = '  Z',    key = 'z', width = 3, justify = 'right' },
		},
		values = sensor.sense(),
		sortColumn = 'displayName',
	},
	accelerators = {
		q = 'quit',
	},
}

function page.grid:getDisplayValues(row)
	row = Util.shallowCopy(row)
	row.x = math.floor(row.x)
	row.y = math.floor(row.y)
	row.z = math.floor(row.z)
	return row
end

function page:eventHandler(event)
	if event.type == 'quit' then
		Event.exitPullEvents()
	elseif event.type == 'project' then
		config.projecting = not config.projecting
		if config.projecting then
			Project:init(ni.canvas())
		else
			Project.canvas:clear()
		end
		Config.update('Entities', config)
	end
	UI.Page.eventHandler(self, event)
end

Event.onInterval(.5, function()
	local entities = sensor.sense()
	local meta = ni.getMetaOwner()
	Util.filterInplace(entities, function(e) return e.id ~= meta.id end)

	if config.projecting then
		Project.canvas:clear()
		Project:drawPoints(meta, entities, 'X', 0xFFDF50AA)
	end

	page.grid:setValues(entities)
	page.grid:draw()
	page:sync()
end)

if config.projecting then
	Project:init(ni.canvas())
end

UI:setPage(page)
UI:pullEvents()

if config.projecting then
	Project.canvas:clear()
end
