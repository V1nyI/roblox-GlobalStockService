# GlobalStockService

A Roblox module for managing global stock across servers using DataStoreService and MemoryStoreService. Supports forced stock overrides, automatic restocking, random stock prediction based on a global key, callbacks for stock changes

---

## Features

- global stock generation with a shared global key
- Automatic periodic restocking with configurable intervals
- Forced stock overrides with expiration via MemoryStoreService
- Callbacks for stock changes and forced stock updates
- Safe update retries and key rotation support
- Debug logging and version update notifications

---

## Installation

1. Copy `GlobalStockService.lua` into your Roblox project (ideally in `ServerScriptService`).
2. Require it in your script:
```lua
local GlobalStockService = require(path.to.GlobalStockService)
```

## Basic Usage
### Create a stock configuration and start its update loop:
```lua
local stockItems = {
    {name = "ItemA", chance = 50, minAmount = 1, maxAmount = 3},
    {name = "ItemB", chance = 30, minAmount = 2, maxAmount = 5},
    {name = "ItemC", chance = 80, minAmount = 1, maxAmount = 1},
}

local myStock = GlobalStockService.CreateStock("MyShopStock", stockItems, 1, 3, 600)

local currentStock = GlobalStockService.GetCurrentStock("MyShopStock")
for _, item in ipairs(currentStock) do
    print(item.name, item.amount)
end
```

## Forced Stock Overrides
### Force the next stock to a specific list for a defined number of restocks:
```lua
local forcedStock = {
    {name = "SpecialItem", amount = 10}
}

GlobalStockService.ForceNextStock("MyShopStock", forcedStock, 2)

-- Clear forced stock override:

GlobalStockService.ClearForcedStock("MyShopStock")
```

## Event Callbacks
### Subscribe to stock change events:
```lua
GlobalStockService.OnStockChanged(function(stockName, oldStock, newStock, restockTime)
    print("Stock changed for", stockName)
end)
```
### Subscribe to forced stock change events:
```lua
GlobalStockService.OnStockForceChanged(function(stockName, oldStock, newStock, timer)
    print("Forced stock changed for", stockName)
end)
```
### Subscribe to forced stock expiration events:
```lua
GlobalStockService.OnForcedStockExpired(function(stockName)
    print("Forced stock expired for", stockName)
end)
```

## Advanced Usage
### Rotate the global key manually
```lua
local success, newKeyOrError = GlobalStockService.ForceRotateGlobalKey()
if success then
    print("Global key rotated successfully")
else
    warn("Failed to rotate global key:", newKeyOrError)
end
```
### Enable or disable debug logging
```lua
GlobalStockService.SetDebug(true) -- Enable debug logs
GlobalStockService.SetDebug(false) -- Disable debug logs
```

## API Overview
- CreateStock(name, items, min, max, interval) - Create and start a new stock configuration
- GetCurrentStock(name) - Get current stock for a stock name
- ForceNextStock(name, list, restocks) - Force next stock list for a given number of restocks
- ClearForcedStock(name) - Clear forced stock override
- OnStockChanged(callback) - Subscribe to normal stock change events
- OnStockForceChanged(callback) - Subscribe to forced stock change events
- OnForcedStockExpired(callback) - Subscribe to forced stock expiration events
- ForceRotateGlobalKey() - Manually rotate the global key
- StopStock(name) - Stop the stock update loop for a stock
- SetDebug(enabled) - Enable or disable debug logging

## License

MIT — see [LICENSE](LICENSE) for details.
