--// Services
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

local _Required = false

local GlobalStockService = {}
GlobalStockService.__index = GlobalStockService

local stocks = {}

local _onStockChangedCallbacks = {}
local _onStockForceChangeCallbacks = {}
local _onForcedStockExpiredCallbacks = {}

--// Constants
local _KEY_DATASTORE_NAME = "GlobalStockKeyStore"
local _KEY_DATASTORE_KEY = "GlobalStockKey_v1"
local _FORCED_STOCK_KEY = "ForcedNextStock"
local _KEY_LENGTH = 16
local _MAX_UPDATE_ATTEMPTS = 5

local _SEED_ZERO_FALLBACK = 0xCAFEBABE
local _SEED_INITIAL_ZERO = 0xDEADBEEF
local _SEED_FALLBACK_OFFSET_1 = 99999
local _SEED_FALLBACK_OFFSET_2 = 88888
local _SEED_COUNT_OFFSET = 10000

local DAY_NAME_TO_ID = {
	sunday = 1,
	monday = 2,
	tuesday = 3,
	wednesday = 4,
	thursday = 5,
	friday = 6,
	saturday = 7
}

--// Debug config
local _debug = false
local _forcedLogLimit = 5
local _forcedLogCount = 0

--// Private
local _Version = "1.0.8"
local VERSION_URL = "https://raw.githubusercontent.com/V1nyI/roblox-GlobalStockService/refs/heads/main/Version.txt"

--// Logging Utility
local function _log(level, msg, force)
	if not _debug and not force then return end
	if force then
		if _forcedLogCount >= _forcedLogLimit then return end
		_forcedLogCount += 1
	end
	
	level = tostring(level):lower()
	if level == "warn" then
		warn("[GlobalStockService] " .. tostring(msg))
	elseif level == "error" then
		error("[GlobalStockService] " .. tostring(msg))
	else
		print("[GlobalStockService] " .. tostring(msg))
	end
end

local function CheckForUpdates(currentVersion)
	local success, response = pcall(function()
		return HttpService:GetAsync(VERSION_URL)
	end)
	
	if success then
		local remoteVersion = response:match("%S+")
		if remoteVersion and remoteVersion ~= currentVersion then
			warn("[GlobalStockService] A newer version is available: " .. remoteVersion .. " (current: " .. currentVersion .. ")")
		else
			print("[GlobalStockService] You are using the latest version: " .. currentVersion)
		end
	else
		warn("[GlobalStockService] Failed to check for updates.")
	end
end

if _Required == false then
	_Required = true
	CheckForUpdates(_Version)
end

local function _rol32(x, n)
	n = n % 32
	local left = bit32.lshift(x, n)
	local right = bit32.rshift(x, 32 - n)
	
	return bit32.band(bit32.bor(left, right), 0xFFFFFFFF)
end

local function _makeXorShift32(seed)
	local s = bit32.band(tonumber(seed) or 0, 0xFFFFFFFF)
	if s == 0 then s = _SEED_INITIAL_ZERO end
	
	return function()
		s = bit32.bxor(s, bit32.lshift(s, 13))
		s = bit32.bxor(s, bit32.rshift(s, 17))
		s = bit32.bxor(s, bit32.lshift(s, 5))
		s = bit32.band(s, 0xFFFFFFFF)
		return s / 0x100000000
	end
end

local function _generateRandomKey()
	local rng = Random.new()
	local key = {}
	for i = 1, _KEY_LENGTH do
		key[i] = rng:NextInteger(0, 0x7FFFFFFF)
	end
	
	return key
end

local function _getOrCreateGlobalKeyFromDataStore()
	local store = DataStoreService:GetDataStore(_KEY_DATASTORE_NAME)
	
	for attempt = 1, _MAX_UPDATE_ATTEMPTS do
		local success, result = pcall(function()
			return store:UpdateAsync(_KEY_DATASTORE_KEY, function(oldValue)
				if oldValue and type(oldValue) == "table" and oldValue.numbers then
					return oldValue
				end
				return {
					numbers = _generateRandomKey(),
					created = os.time()
				}
			end)
		end)
		
		if success and type(result) == "table" and result.numbers then
			_log("info", "Global key obtained on attempt " .. attempt, false)
			return result.numbers
		end
		
		task.wait(math.min(attempt, 5))
	end
	
	_log("warn", "Failed to obtain/create global key after retries", true)
	return nil
end

local function _forceRotateGlobalKey()
	local store = DataStoreService:GetDataStore(_KEY_DATASTORE_NAME)
	
	local success, result = pcall(function()
		return store:UpdateAsync(_KEY_DATASTORE_KEY, function()
			return {
				numbers = _generateRandomKey(),
				created = os.time()
			}
		end)
	end)
	
	if success and type(result) == "table" and result.numbers then
		_log("info", "Global key rotated successfully", false)
		return result.numbers
	end
	
	_log("warn", "Failed to rotate global key: " .. tostring(result), true)
	return nil
end

local function _keyAndTimeToSeed(keyNumbers, restockTime)
	local seed = bit32.band(tonumber(restockTime) or os.time(), 0xFFFFFFFF)
	
	for i = 1, #keyNumbers do
		local num = keyNumbers[i] or 0
		local rotated = _rol32(bit32.band(num, 0xFFFFFFFF), i)
		seed = bit32.bxor(seed, rotated)
		seed = bit32.band(seed + (num % 0x100000000), 0xFFFFFFFF)
	end
	
	if seed == 0 then seed = _SEED_ZERO_FALLBACK end
	return seed
end

--// MemoryStore access helpers for forced stock

local function _getMemoryStoreMap()
	return MemoryStoreService:GetSortedMap(_FORCED_STOCK_KEY)
end

local function _getForcedStockFromMemoryStore()
	local memStore = _getMemoryStoreMap()
	
	local success, data = pcall(function()
		return memStore:GetRangeAsync(Enum.SortDirection.Ascending, 100)
	end)
	
	if success and data then
		local forcedStocks = {}
		
		for _, entry in ipairs(data) do
			if type(entry.value) == "table" and entry.key then
				forcedStocks[entry.key] = entry.value
			end
		end
		
		return forcedStocks
	end
	
	return nil
end

local function _saveForcedStockToMemoryStore(stockName, stockList, restocks)
	local memStore = _getMemoryStoreMap()
	
	local expiration = tonumber(restocks) or 1
	expiration = expiration * (stocks[stockName] and stocks[stockName].RESTOCK_INTERVAL or 600)
	
	pcall(function()
		memStore:SetAsync(stockName, stockList, expiration)
	end)
end

local function _clearForcedStockInMemoryStore(stockName)
	local memStore = _getMemoryStoreMap()
	
	pcall(function()
		memStore:RemoveAsync(stockName)
	end)
end

local function _getForcedStock(stockName)
	local map = _getMemoryStoreMap()
	
	local success, forcedStock = pcall(function()
		return map:GetAsync(stockName)
	end)
	
	if success and type(forcedStock) == "table" then
		return forcedStock
	end
	
	return nil
end

local function _callCallbacks(callbacks, stockName, oldStock, newStock, timer)
	for _, callback in ipairs(callbacks) do
		local ok, err = pcall(callback, stockName, oldStock, newStock, timer)
		
		if not ok then
			_log("warn", "Stock callback error for '" .. tostring(stockName) .. "': " .. tostring(err), true)
		end
	end
end

--// Predict stock based on seed and stock data
local function _predictStock(stockData, restockTime)
	assert(stockData.globalKey and type(stockData.globalKey) == "table", "Global key not set")
	
	local seed = _keyAndTimeToSeed(stockData.globalKey, restockTime)
	local rand = _makeXorShift32(seed)
	
	local candidates = {}
	
	for _, itemData in ipairs(stockData.stockItems) do
		if type(itemData) == "table" then
			local itemName = itemData.name
			if type(itemName) == "string" then
				local chance = math.clamp(tonumber(itemData.chance) or 100, 0, 100)
				local minAmount = math.max(1, tonumber(itemData.minAmount) or 1)
				local maxAmount = math.max(minAmount, tonumber(itemData.maxAmount) or minAmount)
				
				if rand() <= (chance / 100) then
					local amountRand = _makeXorShift32(seed + (#candidates + 1))
					local amount = minAmount
					if maxAmount > minAmount then
						amount = minAmount + math.floor(amountRand() * (maxAmount - minAmount + 1))
						amount = math.min(amount, maxAmount)
					end
					table.insert(candidates, {name = itemName, amount = amount})
				end
			end
		end
	end
	
	if #candidates == 0 and #stockData.stockItems > 0 then
		local fallbackRand = _makeXorShift32(seed + _SEED_FALLBACK_OFFSET_1)
		local idx = 1 + math.floor(fallbackRand() * #stockData.stockItems)
		idx = math.clamp(idx, 1, #stockData.stockItems)
		
		local fallbackItem = stockData.stockItems[idx]
		local minAmount = math.max(1, tonumber(fallbackItem.minAmount) or 1)
		local maxAmount = math.max(minAmount, tonumber(fallbackItem.maxAmount) or minAmount)
		
		local amount = minAmount
		if maxAmount > minAmount then
			local amountRand = _makeXorShift32(seed + _SEED_FALLBACK_OFFSET_2)
			amount = minAmount + math.floor(amountRand() * (maxAmount - minAmount + 1))
			amount = math.min(amount, maxAmount)
		end
		
		return {{name = fallbackItem.name or "Unknown", amount = amount}}
	end
	
	local minCount = math.max(1, math.min(stockData.minItems, #candidates))
	local maxCount = math.max(minCount, math.min(stockData.maxItems, #candidates))
	local countToReturn = minCount
	
	if maxCount > minCount then
		local randCount = _makeXorShift32(seed + _SEED_COUNT_OFFSET)
		countToReturn = minCount + math.floor(randCount() * (maxCount - minCount + 1))
		countToReturn = math.min(countToReturn, maxCount)
	end
	
	for i = #candidates, 2, -1 do
		local j = 1 + math.floor(rand() * i)
		candidates[i], candidates[j] = candidates[j], candidates[i]
	end
	
	local predictedStock = {}
	
	for i = 1, countToReturn do
		table.insert(predictedStock, candidates[i])
	end
	
	return predictedStock
end

local function _getCurrentRestockTime(stockData, currentTime)
	currentTime = currentTime or os.time()
	local interval = stockData.RESTOCK_INTERVAL or 100
	
	return currentTime - (currentTime % interval)
end

local function _isDayAllowed(stockData, now)
	if not stockData.allowedDays then return true end
	local currentDayId = tonumber(os.date("!%w", now)) + 1
	return stockData.allowedDays[currentDayId] == true
end

local function normalizeDayInput(day)
	if type(day) == "number" then
		assert(day >= 1 and day <= 7, "Day number must be 1-7")
		return day
	elseif type(day) == "string" then
		local lower = string.lower(day)
		assert(DAY_NAME_TO_ID[lower], "Invalid day name: " .. tostring(day))
		return DAY_NAME_TO_ID[lower]
	else
		error("Day must be string or number")
	end
end

local function convertToTime(date)
	assert(type(date) == "table" and date.year and date.month and date.day, "Date must have at least {year, month, day}")

	local hour = date.hour or 0
	local min = date.min or date.minute or 0
	local sec = date.sec or date.second or 0
	local timezone = date.timezoneOffset or date.tzOffset or 0
	
	local timezoneSeconds = timezone * 3600
	
	local timestamp = os.time({
		year = date.year,
		month = date.month,
		day = date.day,
		hour = hour,
		min = min,
		sec = sec
	})

	return timestamp - timezoneSeconds
end

local function _isWithinDateRange(stockData, now)
	if not stockData.dateStart or not stockData.dateEnd then return true end
	return now >= stockData.dateStart and now <= stockData.dateEnd
end

local function _stockUpdateLoop(stockName)
	local stockData = stocks[stockName]
	if not stockData then return end

	while stockData._running do
		local now = os.time()

		local inDate = _isWithinDateRange(stockData, now)
		local inDays = _isDayAllowed(stockData, now)
		local inWindow = inDate and inDays

		if not inWindow then
			if stockData._currentStock and #stockData._currentStock > 0 then
				local oldStock = stockData._currentStock
				stockData._currentStock = {}
				_callCallbacks(_onStockChangedCallbacks, stockName, oldStock, {}, 0)
				_log("info", "Stock '" .. stockName .. "' cleared (out of allowed window).", false)
			end
			task.wait(math.max(1, stockData.RESTOCK_INTERVAL or 600))
		else
			local forcedStock = _getForcedStock(stockName)
			if forcedStock then
				if stockData._currentStock ~= forcedStock then
					local oldStock = stockData._currentStock
					stockData._currentStock = forcedStock
					_callCallbacks(_onStockForceChangeCallbacks, stockName, oldStock, forcedStock, 0)
				end
			else
				local predicted = _predictStock(stockData, now) or {}
				if stockData._currentStock ~= predicted then
					local oldStock = stockData._currentStock
					stockData._currentStock = predicted
					_callCallbacks(_onStockChangedCallbacks, stockName, oldStock, predicted, now)
				end
			end
			task.wait(math.max(1, stockData.RESTOCK_INTERVAL or 600))
		end
	end
end

--// Public API

--[[
	Creates and registers a new global stock configuration
	
	@param stockName string Unique name of the stock
	@param stockItems table List of items with chance, minAmount, maxAmount
	@param minItems number Minimum items to pick
	@param maxItems number Maximum items to pick
	@param restockInterval number Interval in seconds for stock refresh
	@param info table Optional info
]]
function GlobalStockService.CreateStock(stockName, stockItems, minItems, maxItems, restockInterval, stockType, Info)
	assert(type(stockName) == "string", "stockName must be string")
	assert(type(stockItems) == "table", "stockItems must be table")
	minItems = tonumber(minItems) or 1
	maxItems = tonumber(maxItems) or minItems
	restockInterval = tonumber(restockInterval) or 600
	stockType = stockType or "Normal"

	if stocks[stockName] then
		_log("warn", "Stock '" .. stockName .. "' already exists. Overwriting.", true)
	end

	local stockData = {
		stockItems = stockItems,
		minItems = minItems,
		maxItems = maxItems,
		RESTOCK_INTERVAL = restockInterval,
		globalKey = _getOrCreateGlobalKeyFromDataStore() or _generateRandomKey(),
		_currentStock = {},
		_running = true,
		_type = string.lower(stockType),
	}
	
	if stockType:lower() == "datelimited" or stockType:lower() == "dayofweeklimited" then
		-- DateLimited setup (Info.start / Info.end with {year,month,day})
		if Info.start and Info["end"] then
			stockData.dateStart = convertToTime(Info.start)
			stockData.dateEnd   = convertToTime(Info["end"])
		end
		
		-- DayOfWeekLimited setup (Info.days = {"Monday", "Friday"})
		if Info.days then
			stockData.allowedDays = {}
			for _, d in ipairs(Info.days) do
				local dayId = normalizeDayInput(d)
				stockData.allowedDays[dayId] = true
			end
		end
	end
	
	stocks[stockName] = stockData
	task.spawn(function()
		_stockUpdateLoop(stockName)
	end)
	
	return stockData
end

--[[
	Gets the current stock list for a stock name
	
	@param stockName string
	@return table Current stock array 
]]
function GlobalStockService.GetCurrentStock(stockName)
	local stockData = stocks[stockName]
	
	if stockData then
		return stockData._currentStock or {}
	end
	
	return nil
end

--[[
	Forces the next stock to be a specific list for a given number of restocks
	
	@param stockName string
	@param stockList table The stock items list to force
	@param restocks number Number of restocks before forced stock expires
]]
function GlobalStockService.ForceNextStock(stockName, stockList, restocks)
	assert(type(stockName) == "string", "stockName must be string")
	assert(type(stockList) == "table", "stockList must be table")
	
	restocks = tonumber(restocks) or 1
	
	local stockData = stocks[stockName]
	if not stockData then
		_log("warn", "ForceNextStock failed: Stock '" .. stockName .. "' does not exist", true)
		return false
	end
	
	_saveForcedStockToMemoryStore(stockName, stockList, restocks)
	
	local oldStock = stockData._currentStock
	stockData._currentStock = stockList
	_callCallbacks(_onStockForceChangeCallbacks, stockName, oldStock, stockList, 0)
	
	_log("info", "Forced stock set for '" .. stockName .. "' with expiration in " .. tostring(restocks) .. " restocks", false)
	return true
end

--[[
	Clears forced stock override for a stock name
	
	@param stockName string
]]
function GlobalStockService.ClearForcedStock(stockName)
	assert(type(stockName) == "string", "stockName must be string")
	
	_clearForcedStockInMemoryStore(stockName)
	_log("info", "Forced stock cleared for '" .. stockName .. "'", false)
end

--[[
	Subscribe to stock changed events (normal stock changes)
	
	@param callback function(stockName, oldStock, newStock, restockTime)
]]
function GlobalStockService.OnStockChanged(callback)
	assert(type(callback) == "function", "callback must be function")
	table.insert(_onStockChangedCallbacks, callback)
end

--[[
	Subscribe to forced stock changed events
	
	@param callback function(stockName, oldStock, newStock, timer)
]]
function GlobalStockService.OnStockForceChanged(callback)
	assert(type(callback) == "function", "callback must be function")
	table.insert(_onStockForceChangeCallbacks, callback)
end

--[[
	Subscribe to forced stock expiration events
	
	@param callback function(stockName)
]]
function GlobalStockService.OnForcedStockExpired(callback)
	assert(type(callback) == "function", "callback must be function")
	table.insert(_onForcedStockExpiredCallbacks, callback)
end

--[[
	Rotates the global key manually
	
	@return boolean success, newKey or error string
]]
function GlobalStockService.ForceRotateGlobalKey()
	local newKey = _forceRotateGlobalKey()
	
	if newKey then
		for name, stockData in pairs(stocks) do
			stockData.globalKey = newKey
		end
		return true, newKey
	end
	
	return false, "Failed to rotate global key"
end

--[[
	Stops a stock update loop cleanly
	
	@param stockName string
]]
function GlobalStockService.StopStock(stockName)
	local stockData = stocks[stockName]
	if stockData then
		stockData._running = false
	end
end

--[[
	Enables or disables debug logging globally
	
	@param enabled boolean
]]
function GlobalStockService.SetDebug(enabled)
	if not game:GetService("RunService"):IsStudio() then
		warn("Debug can only be set in Studio")
		return false, "Debug can only be set in Studio"
	end
	_debug = enabled and true or false
	if _debug then
		_log("info", "Debug logging enabled", true)
	end
end

return GlobalStockService
