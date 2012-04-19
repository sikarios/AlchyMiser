-- Author      : ckorb
-- Create Date : 3/17/2011 4:53:16 PM

PRICECHECK = 2
SCAN_DELAY = 0.4    -- 400ms ticks usually give enough time for an AH query and response
MAX_PAGE_SCAN_TIME = 4  -- Maximum amount of time it will be allowed to scan a page
AH_CUT = 0.05

local events = {};
local auctionBuyoutPrices = {};

local currentItem = nil;
local waitingToSendQuery = false;
local nextQueryTime = 0;
local nextScanTime = 0
local scannedCount = 0;
local tooltipUpdated = false;
local invalidAuctionCount = 0;
local validAuctionCount = 0;
local numTotalAuctions = 0;
local scanning = false
------------ Create status bar for use when updating price list -----------
local updateStatus = CreateFrame("StatusBar", nil, UIParent)
updateStatus:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
updateStatus:GetStatusBarTexture():SetHorizTile(false)
updateStatus:SetWidth(400)
updateStatus:SetHeight(50)
updateStatus:SetPoint("CENTER",UIParent,"CENTER")
updateStatus:SetStatusBarColor(1,1,0)
updateStatus:Hide()
---------------------------------------------------------------------------

-- get the size for tables that have kv pairs, i.e 2-dimensional
function tableSize(t)
	local c = 0;
	for k,v in pairs(t) do 
		c = c + 1;
	end
	return c;
end

function recipeCost(recipeName)
--Returns the market cost of creating the specified recipe.
  local recipe = recipeList[recipeName] or {}
  local matName, matCost, matCount
  local totalCost = 0
  for i = 1, ((#(recipe) / 2) - 1), 1 do
    matName = recipe[2 * i - 1] or ""
    matCost = priceList[matName] or 0
    matCount = recipe[2 * i] or 0
    totalCost = totalCost +  matCost * matCount
  end
  return totalCost
end

function recipeValue(recipeName)
--Returns the market value of the specified recipe, minus the 5% AH cut.
  local recipe = recipeList[recipeName] or {}
  local itemName, itemValue, itemCount, totalValue
  itemName = recipe[#(recipe)-1] or recipeName
  itemValue = priceList[itemName] or 0
  itemCount = recipe[#(recipe)] or 0
  totalValue = itemValue * itemCount * (1 - AH_CUT) --Minus the AH cut.
  return totalValue
end

function OnTooltipSetItem(tooltip,...)
	if not tooltipUpdated then
		local name, recipe, itemValue, matCost
    local toolTipText = ""
		name = tooltip:GetItem()
		itemValue = priceList[name]
		if (itemValue) then toolTipText = toolTipText .. "Market Value: " .. ((itemValue>0) and GetCoinTextureString(itemValue) or "unkown") end
    recipe = recipeList[name]
    if (recipe) then
      matCost = recipeCost(name)
      if (toolTipText ~= "") then toolTipText = toolTipText .. "\n" end
      toolTipText = toolTipText .. "Material Cost: " .. ((matCost>0) and GetCoinTextureString(matCost) .. " each" or "unknown")
    end
    tooltip:AddLine(toolTipText,1.0,0.6,0.0,true)
		tooltipUpdated = true
	end
end

function OnTooltipCleared(tooltip,...)
  tooltipUpdated = false
end

local aQuery =
{
	query_type,
	start_time,
	started = false,
	item_name = "",
	min_level = nil,
	max_level = nil,
	type_index = 0,
	class_index = 0,
	subclass_index = 0,
  total_pages = 0,
	current_page = 0,
	is_usable = 0,
	quality_index = 0,
};

function money(copper)
	local gold, silver
	gold = math.floor(copper/10000);
	silver = math.floor((copper-gold*10000)/100);
	copper = math.floor(copper-gold*10000-silver*100);
	return gold,silver,copper
end

function moneyString(amount)
  local g,s,c
  g=math.floor(amount/10000)
  s=math.floor((amount-g*10000)/100)
  c=math.floor(amount-g*10000-s*100)
  return (g .. "g" .. s .. "s" .. c .. "c")
end

function sendQuery(auctionQuery)
	QueryAuctionItems(
	auctionQuery.item_name,
	auctionQuery.min_level,
	auctionQuery.max_level,
	auctionQuery.type_index,
	auctionQuery.class_index,
	auctionQuery.subclass_index,
	auctionQuery.current_page,
	auctionQuery.is_usable,
	auctionQuery.quality_index,
	false);
end

function itemPriceScan(itemName)
	auctionBuyoutPrices = {};
	validAuctionCount = 0;
	invalidAuctionCount = 0;
	aQuery.query_type = PRICECHECK;
	aQuery.start_time = GetTime();
	aQuery.started = true;
	aQuery.item_name = itemName;
	aQuery.min_level = nil;
	aQuery.max_level = nil;
	aQuery.type_index = 0;
	aQuery.class_index = 0;
	aQuery.subclass_index = 0;
	aQuery.current_page = 0;
  aQuery.total_pages = 0;
	aQuery.is_usable = 0;
	aQuery.quality_index = 0;
	waitingToSendQuery = true;
end

function scanFinish()
  aQuery.started = false;
  print("Successful: " .. validAuctionCount .. "/" .. numTotalAuctions)
  table.sort(auctionBuyoutPrices)
  -- calculate the average price of the lowest-priced 10%
  local avg, sum, count = 0, 0, 0
  local maxCount = math.ceil(#(auctionBuyoutPrices) * 0.10)
  for k = 1, #(auctionBuyoutPrices) do
    sum = sum + auctionBuyoutPrices[k]
    if (auctionBuyoutPrices[k] > 0) then count = count + 1 end -- this skips any 0's that may be at the beginning of the table
    if (count >= maxCount) then break end
  end
  avg = math.floor(sum / count)
  print(aQuery.item_name .. ":" ..  GetCoinTextureString(avg) .. "(Scanned " .. validAuctionCount .. " auctions).")
  priceList[aQuery.item_name] = avg

  -- ok, we are now completely done with scanning/updating the price for this item, so lets move on.
  scannedCount = scannedCount + 1
  updateStatus:SetValue(scannedCount)
  currentItem = next(priceList, currentItem)  -- get the next item to scan
  if (currentItem) then itemPriceScan(currentItem) else updateStatus:Hide() end -- scan the next item
end

function scanPage()
  if (aQuery.started==false) then return; end
  invalidAuctionCount = 0
  local aBatch = GetNumAuctionItems("list")
  local currentValidAuctions = 0
  local currentValidPrices = {}
  for i = 1, aBatch do
    local name,_,count,_,_,_,_,_,_,buyoutPrice = GetAuctionItemInfo("list", i);
    if (name and count and buyoutPrice) then
      if (name == aQuery.item_name) then
        currentValidAuctions = currentValidAuctions + 1
        currentValidPrices[currentValidAuctions] = (buyoutPrice / count) or 0
      end
    else
      invalidAuctionCount = invalidAuctionCount + 1
    end
  end
  
  -- If all auctions on this page were successful, or if we have timed out, then move on
  if (invalidAuctionCount == 0) or (GetTime() >= aQuery.start_time + MAX_PAGE_SCAN_TIME) then
    if (aQuery.current_page <= aQuery.total_pages) then       -- If there are still more pages to scan
      for i = 1, currentValidAuctions do
        table.insert(auctionBuyoutPrices,currentValidPrices[i])
      end
      validAuctionCount = validAuctionCount + currentValidAuctions
      aQuery.current_page = aQuery.current_page + 1   -- Move the query location to the next page
      nextQueryTime = GetTime() + SCAN_DELAY          -- Schedule the next query time
      waitingToSendQuery = true
    else scanFinish()
    end
  elseif (invalidAuctionCount > 0) then -- If we got invalid auctions, wait a bit and scan this page again
    nextScanTime = GetTime() + SCAN_DELAY
    scanning = true
  end
end

function events:AUCTION_ITEM_LIST_UPDATE(...) -- event fired when the auction house page is refreshed (i.e search results are loaded)
  if (aQuery.started==false) then return; end
  local numBatchAuctions
  numBatchAuctions, numTotalAuctions = GetNumAuctionItems("list"); -- get the number of auctions on the current page, and the total auctions in the query
  if (numTotalAuctions > 0) then
    aQuery.total_pages = math.ceil(numTotalAuctions / NUM_AUCTION_ITEMS_PER_PAGE) - 1;
  else aQuery.total_pages = 0 end
  scanning = true -- this will initiate the scan operation
end

function events:AUCTION_HOUSE_SHOW(...)
	frmMain:Show();
end

function events:ADDON_LOADED(arg1,...)
	print (arg1)
	if(arg1=="AlchyMiser") then
		print ("AlchyMiser Loaded")
		if(recipeList==nil) then
			recipeList = {
				["Flask of Flowing Water"]={"Heartblossom",8,"Stormvine",8,"Volatile Life",8,nil,1},
				["Flask of the Draconic Mind"]={"Twilight Jasmine",8,"Azshara's Veil",8,"Volatile Life",8,nil,1},
				["Flask of Steelskin"]={"Cinderbloom",8,"Twilight Jasmine",8,"Volatile Life",8,nil,1},
				["Flask of Titanic Strength"]={"Cinderbloom",8,"Whiptail",8,"Volatile Life",8,nil,1},
				["Flask of the Winds"]={"Azshara's Veil",8,"Whiptail",8,"Volatile Life",8,nil,1},
				["Living Elements"]={"Volatile Life",15,"Volatile Air",15},
				["Truegold"]={"Volatile Air",10,"Volatile Fire",10,"Volatile Water",10,"Pyrium Bar",3,nil,1}
			}
			print("could not load recipe data")
		end
		if(priceList==nil) then
			priceList = {
				["Cinderbloom"]=0,
				["Heartblossom"]=0,
				["Twilight Jasmine"]=0,
				["Azshara's Veil"]=0,
				["Stormvine"]=0,
				["Whiptail"]=0,
				["Volatile Life"]=0,
				["Volatile Air"]=0,
				["Volatile Earth"]=0,
				["Volatile Water"]=0,
				["Volatile Fire"]=0,
				["Flask of Flowing Water"]=0,
				["Flask of the Draconic Mind"]=0,
				["Flask of Steelskin"]=0,
				["Flask of Titanic Strength"]=0,
				["Flask of the Winds"]=0,
				["Pyrium Bar"]=0,
				["Truegold"]=0,
        ["Crystal Vial"]=0
			}
			print("could not load item price data")
		end
			--print ("AlchyMiser variables have been loaded")
		for k,v in pairs(priceList) do print(k,v) end
	end
end

function UpdatePrices()
	updateStatus:SetMinMaxValues(0, tableSize(priceList)) -- updateStatus is the progress bar for the scan
	updateStatus:SetValue(0)
	updateStatus:Show()
	currentItem = next(priceList, nil)
	itemPriceScan(currentItem)
end

function UpdateRecipes()
	-- future idea:
	-- Implement function to scan the player's professions for any recipes they
	-- have and import the recipes to recipeList, and import the mats and the
	-- crafted items to priceList
	local i, minMade, maxMade, reagentTypeCount, reagentName, reagentCount, skillName, skillType, itemName, itemLink, recipeLink, recipe, failed
	for i = 1, GetNumTradeSkills(), 1 do
		minMade, maxMade = GetTradeSkillNumMade(i)			-- min and max quantity of items produced by recipe
		reagentTypeCount = GetTradeSkillNumReagents(i) 	-- total number of unique materials required for recipe
		skillName, skillType = GetTradeSkillInfo(i)
		failed = false
		recipe = {}
		if (skillType and skillName and skillType~="header" and skillName~="Transmute: Living Elements" and skillName~="Northrend Alchemy Research") then
			recipeLink = GetTradeSkillRecipeLink(i)
			itemLink = GetTradeSkillItemLink(i)
			itemName = GetItemInfo(itemLink)
			--print(skillName .. " - " .. skillType)
			for j = 1, reagentTypeCount, 1 do
				reagentName,_,reagentCount = GetTradeSkillReagentInfo(i, j)
        if (reagentName) then
					recipe[2 * j - 1] = reagentName
					recipe[2 * j] = reagentCount
					if (priceList[reagentName] == nil) then priceList[reagentName] = 0 end -- we don't have this in our price list so add it
				else failed = true
				end
			end
			if (failed) then
				i = i - 1
			else
				local recipeSize = #(recipe)
				recipe[recipeSize + 1] = nil
				recipe[recipeSize + 2] = 1
        if (priceList[itemName] == nil) then priceList[itemName] = 0 end -- we don't have this in our price list so add it
				if (recipeList[itemName] == nil) then
          recipeList[itemName] = recipe
          print("Recipe for " .. itemLink .. " imported.")
        end
			end
		end
	end
end

function AlchyMiserInit()
	frmMain:Hide();
	frmMain:RegisterForDrag("LeftButton");
	frmMain:SetScript("OnEvent", function(self,event,...)events[event](self,...);end);
	GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
	GameTooltip:HookScript("OnTooltipCleared", OnTooltipCleared)
	-- this will register every event that has a handler function up above
	for k,v in pairs(events) do
		frmMain:RegisterEvent(k); 
	end
end

function OnUpdate()
	if (waitingToSendQuery) then
		if (GetTime() >= nextQueryTime) then
			if (CanSendAuctionQuery()) then
				waitingToSendQuery = false;
				sendQuery(aQuery)
			end
		end
	end
  if (scanning) then
    if (GetTime() >= nextScanTime) then
      scanning = false
      scanPage()
    end
  end
end

local update_handler = CreateFrame("Frame", nil, UIParent)
update_handler:SetScript("OnUpdate", OnUpdate)