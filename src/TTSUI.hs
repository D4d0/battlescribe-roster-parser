{-# LANGUAGE Arrows            #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE RecordWildCards   #-}

module TTSUI where

import           Control.Arrow
import           Data.List
import           Data.Maybe
import           Data.Monoid
import qualified Data.Text          as T
import qualified Data.Text.Encoding as E

import           Crypto.Hash.MD5
import           Data.HexString
import           Data.List.Index
import qualified Data.Text.IO
import           Debug.Trace        as Debug
import qualified NeatInterpolation  as NI
import           Safe
import           Text.XML.HXT.Core
import           TTSJson
import           Types
import           XmlHelper

scriptFromXml :: ArrowXml a => ScriptOptions -> T.Text -> String -> String -> a XmlTree String
scriptFromXml options rosterId name id =
  if shouldAddScripts options then
    uiFromXML options name >>> arr (asScript options rosterId (T.pack id)) >>> arr T.unpack
  else
    arr (const "")

uiFromXML :: ArrowXml a => ScriptOptions -> String -> a XmlTree (T.Text, [Table])
uiFromXML options name = (listA (deep (hasName "profile")) &&&
                  (listA (deep (hasName "category")) &&&
                  listA (deep (hasName "cost"))))  >>> profilesToXML name

mapA :: ArrowXml a => a b c -> a [b] [c]
mapA a = listA (unlistA >>> a)

profilesToXML :: ArrowXml a => String -> a ([XmlTree], ([XmlTree], [XmlTree])) (T.Text, [Table])
profilesToXML name = proc (profiles, (categories, costs)) -> do
    categoryTab <- optional (oneCellTable "Categories: ") categoryTable -< categories
    ptsCost <- optional 0 (costsTable "pts") -< costs
    plCost <- optional 0 (costsTable " PL") -< costs
    profileTabs <- inferTables -< profiles
    let costTab = oneCellTable (escapes (T.pack ("Cost: " ++ show ptsCost ++ "pts" ++ " " ++ show plCost ++ " PL")))
    returnA -< (T.pack name , costTab : categoryTab : filter tableNotEmpty profileTabs)

optional :: ArrowXml a => c -> a b c -> a b c
optional defaultVal a = listA a >>> arr listToMaybe >>> arr (fromMaybe defaultVal)

categoryTable :: ArrowXml a => a [XmlTree] Table
categoryTable = mapA (getAttrValue0 "name")  >>> arr (intercalate ", ") >>> arr (\x -> oneCellTable (escapes (T.pack ("Keywords: " ++ x))))

costsTable :: ArrowXml a => String -> a [XmlTree] Integer
costsTable typeName = mapA (hasAttrValue "name" (== typeName) >>> getAttrValue "value" >>> arr readMay)
    >>> arr catMaybes >>> arr sumOfDoubles >>> arr floor

sumOfDoubles :: [Double] -> Double
sumOfDoubles = sum

tableNotEmpty :: Table -> Bool
tableNotEmpty Table{..} = not (null rows)

stat :: ArrowXml a => String -> a XmlTree T.Text
stat statName = child "characteristics" /> hasAttrValue "name" (== statName) >>> getBatScribeValue >>> arr T.pack

rowFetcher :: ArrowXml a => [a XmlTree T.Text] -> a XmlTree [T.Text]
rowFetcher = catA >>> listA

fetchStats :: ArrowXml a => [String] -> [a XmlTree T.Text]
fetchStats names = getAttrValueT "name" : map stat names

inferTables :: ArrowXml a => a [XmlTree] [Table]
inferTables = proc profiles -> do
    profileTypes <- mapA getType >>> arr nub >>> arr sort -< profiles
    tables <- listA (catA (map inferTable profileTypes)) -<< profiles
    returnA -< tables

inferTable :: ArrowXml a => String -> a [XmlTree] Table
inferTable profileType = proc profiles -> do
    matchingProfiles <-  mapA (isType profileType) -< profiles
    characteristics <- mapA (this /> hasName "characteristics" /> hasName "characteristic" >>> getAttrValue "name") >>> arr nub -<< matchingProfiles
    let header = map T.pack (profileType : characteristics)
    rows <- mapA (rowFetcher (fetchStats characteristics)) -<< matchingProfiles
    let widths = computeWidths (header : rows)
    let sortedUniqueRows = sort (nubBy (\o t -> head o == head t ) rows)
    returnA -< normalTable header sortedUniqueRows widths

bound :: Double -> Double -> Double -> Double
bound min max i =  minimum [maximum [i, min], max]

computeWidths :: [[T.Text]] -> [Double]
computeWidths vals = widths where
    asLengths = map (map (bound 12 90 . fromIntegral . T.length)) vals :: [[Double]]
    asLineLengths = map maximum (transpose asLengths) :: [Double]
    avg = sum asLineLengths
    widths = map (/ avg) asLineLengths

descriptionId = "desc-id"

descriptionScript :: T.Text -> T.Text -> T.Text
descriptionScript rosterId unitId = [NI.text|
function onLoad()
  self.setVar("$descriptionId", "$uniqueId")
end
|] where
  uniqueId = rosterId <> ":" <> unitId

asScript :: ScriptOptions -> T.Text -> T.Text -> (T.Text, [Table]) -> T.Text
asScript options rosterId unitId (name, tables) = [NI.text|

function uiSub(uiTable, target, value)
  if uiTable["attributes"] then
    for k,v in pairs(uiTable["attributes"]) do
      uiTable["attributes"][k] = nil
      uiTable["attributes"][string.gsub(k, target, value)] = string.gsub(v, target, value)
    end
  end
  if uiTable["children"] then
    for k,child in pairs(uiTable["children"]) do
      uiTable["children"][k] = uiSub(child, target, value)
    end
  end
  return uiTable
end

function createUI(uiId, playerColor)
  local guid = self.getGUID()
  local uiTable = uiSub(
                   uiSub(
                   uiSub($ui, "thepanelid", uiId),
                              "theguid", guid),
                              "thevisibility", playerColor)
  return uiTable
end

function onLoad()
  self.setVar("$descriptionId", desc())
end

function copyUITable(uiTable)
  local result = {}
  for k, element in pairs(uiTable) do
    local newElement = {}
    newElement["tag"] = element["tag"]
    if element["value"] ~= nil then
      newElement["value"], times = string.gsub(element["value"],"[ ]+"," ")
    end
    newElement["attributes"] = element["attributes"]
    newElement["children"] = {}
    if element["children"] ~= nil then
      newElement["children"] = copyUITable(element["children"])
    end
    table.insert(result, newElement)
  end
  return result
end


function loadUI(playerColor)
  local panelId = createName(playerColor)
  local uiTable = createUI(panelId, playerColor)
  local currentUI = UI.getXmlTable()
  local inserted = false
  for k,element in pairs(currentUI) do
    if element["attributes"] ~= nil and element["attributes"]["id"] == panelId then
      currentUI[k]["children"] = uiTable["children"]
      inserted = true
    end
  end
  if not inserted then
    table.insert(currentUI, uiTable)
  end
  local result = copyUITable(currentUI)
  UI.setXmlTable(result)
end

function unloadUI(playerColor)
  local panelId = createName(playerColor)
  local uiTable = UI.getXmlTable()
  local panelIndex = -1
  for index, element in pairs(uiTable) do
    if element["attributes"]["id"] == panelId then
      panelIndex = index
      break
    end
  end
  if panelIndex >= 0 then
    local el = uiTable[panelIndex]
  end
  uiCreated[playerColor] = false
end

uiCreated = {}

timesActivated = 0

function onScriptingButtonDown(index, peekerColor)
  local player = Player[peekerColor]
  local name = createName(peekerColor)
  if index == 1 and player.getHoverObject()
                and player.getHoverObject().getVar("$descriptionId") == desc() then
      loadUI(peekerColor)
      Wait.frames(function()
        updateModelCount()
        UI.setAttribute(createName(peekerColor), "active", true)
      end, 2)
  end
   if index == 2 and player.getHoverObject()
                and player.getHoverObject().getVar("$descriptionId") == desc() then
     local target = player.getHoverObject()
     local name = target.getName()
     local current, total = string.gmatch(name,"([0-9]+)/([0-9]+)")()
     current = math.max(tonumber(current) - 1,0)
     local newName = string.gsub(name, "([0-9]+)/([0-9]+)", tostring(current) .. "/" .. total)
     target.setName(newName)
  end
   if index == 3 and player.getHoverObject()
                and player.getHoverObject().getVar("$descriptionId") == desc() then
     local target = player.getHoverObject()
     local name = target.getName()
     local current, total = string.gmatch(name,"([0-9]+)/([0-9]+)")()
     current = tonumber(current) + 1
     local newName = string.gsub(name, "([0-9]+)/([0-9]+)", tostring(current) .. "/" .. total)
     target.setName(newName)
  end
end

function onObjectDrop(playerColor, obj)
  scheduleUpdateIfInUnit(obj)
end

function onObjectDestroy(obj)
  if obj.getGUID() ~= self.getGUID() then
    scheduleUpdateIfInUnit(obj)
  end
end

function scheduleUpdateIfInUnit(obj)
if obj.getVar("$descriptionId") == desc() then
  local id = desc() .. "countModels"
  Timer.destroy(id)
  Timer.create(
  {
    identifier = id,
    function_name = "updateModelCount",
    parameters = {},
    delay = 0.2
  }
)
end
end

function distance2D(point1, point2)
  local x = point1.x - point2.x
  local z = point1.z - point2.z
  return math.sqrt(x * x + z * z)
end

unitModels = nil

function collectUnitModels()
  unitModels = {}
  for k,v in pairs(getAllObjects()) do
    if v.getVar("$descriptionId") == desc() then
      table.insert(unitModels, v)
    end
  end
end

function operateOnModels(fn)
  if not unitModels then
    collectUnitModels()
  end
  local originModel = nil
  local dist = 10000
  for k, model in pairs(unitModels) do
    local newDist = distance2D({x=0,y=0,z=0}, model.getPosition())
    if not model.is_face_down and newDist < dist then
      originModel = model
      dist = newDist
    end
  end
  local seenModels = {}
  searchModels(originModel, seenModels, fn)
end

function updateModelCount()
  local modelCounts = {}
  if unitModels then
    for k, model in pairs(unitModels) do
      model.highlightOff()
    end
  end
  local getModelNames = function(model)
    if not modelCounts[model.getName()] then
      modelCounts[model.getName()] = 0
    end
    modelCounts[model.getName()] = modelCounts[model.getName()] + 1
    if highlighting then
      model.highlightOn(highlighting)
    end
  end
  operateOnModels(getModelNames)
  local label = ""
  local keys = {}
  for k in pairs(modelCounts) do table.insert(keys, k) end
  table.sort(keys)
  for index,k in pairs(keys) do
    local v = modelCounts[k]
    modelName = string.gsub(k, "[0-9]+/[0-9]+","")
    label = label .. modelName .. " - " .. tostring(v) .. "\n"
  end
  local theid = self.getGUID() .. "-modelcount"
  UI.setAttribute(theid, "text", label )
end

function getCenterDist(obj)
  local boundsSize = obj.getBoundsNormalized().size
  local longest = math.max(boundsSize.x, boundsSize.z)
  return longest/2
end

function searchModels(origin, seen, fn)
  for k, model in pairs(unitModels) do
    if not model.is_face_down and not seen[model.getGUID()] then
      local originCenterDist = getCenterDist(origin)
      local modelCenterDist = getCenterDist(model)
      local dist = distance2D(origin.getPosition(), model.getPosition())
      if dist < (2.05 + originCenterDist + modelCenterDist) then
        seen[model.getGUID()] = true
        fn(model)
        searchModels(model, seen, fn)
      end
    end
  end
end

highlighting = false

function highlightUnitRed() highlightUnit("Red") end
function highlightUnitGreen() highlightUnit("Green") end
function highlightUnitBlue() highlightUnit("Blue") end
function highlightUnitPurple() highlightUnit("Purple") end
function highlightUnitYellow() highlightUnit("Yellow") end
function highlightUnitWhite() highlightUnit("White") end
function highlightUnitOrange() highlightUnit("Orange") end
function highlightUnitTeal() highlightUnit("Teal") end
function highlightUnitPink() highlightUnit("Pink") end

function highlightUnitNone()
  highlighting = false
  updateModelCount()
end

function highlightUnit(color)
  if highlighting ~= color then
    highlighting = color
  else
    highlighting = false
  end
  updateModelCount()
end

function onDestroy()
  local id = desc() .. "countModels"
  Timer.destroy(id)
  for k,v in pairs(Player.getColors()) do
    UI.hide(createName(v))
  end
  broadcastToAll("Script owner for $name has been destroyed. Scripts for this unit will no longer function.")
end

function closeUI(player, val, id)
  local peekerColor = player.color
  UI.setAttribute(createName(peekerColor), "active", false)
end

function desc()
  return "$uniqueId"
end

function createName(color)
  local guid = self.getGUID()
  return "bs2tts" .. "-" .. color
end

|] where
    ui = toLua $ masterPanel name (maybe 700 fromIntegral (uiWidth options)) (maybe 450 fromIntegral (uiHeight options)) 30 tables
    uniqueId = rosterId <> ":" <> unitId

escape :: Char -> String -> String -> String
escape target replace (c : s) = if c == target then replace ++ escape target replace s else c : escape target replace s
escape _ _ [] = []

escapeT :: Char -> String -> T.Text -> T.Text
escapeT c s = T.pack . escape c s . T.unpack

escapes :: T.Text -> T.Text
escapes = escapeT '"' "\\u{201D}"

masterPanel :: T.Text -> Integer -> Integer -> Integer -> [Table] -> LuaUIElement
masterPanel name widthN heightN controlHeightN tables =
    LUI "Panel" [("id","thepanelid"), ("visibility","thevisibility"), ("active","false"), ("width",width), ("height",height), ("returnToOriginalPositionWhenReleased","false"), ("allowDragging","true"), ("color","#FFFFFF"), ("childForceExpandWidth","false"), ("childForceExpandHeight","false")] [
      LUI "TableLayout" [("autoCalculateHeight","true"), ("width",width), ("childForceExpandWidth","false"), ("childForceExpandHeight","false")] [
        LUI "Row" [("preferredHeight",controlHeight)] [
          LUI "Text" [("resizeTextForBestFit","true"), ("resizeTextMinSize","6"), ("resizeTextMaxSize","30"), ("fontSize","25"), ("rectAlignment","MiddleCenter"), ("text",name), ("width",width)] [],
          LUI "HorizontalLayout" [("rectAlignment","UpperRight"), ("height",controlHeight), ("width",buttonPanelWidth)] [
            LUI "Button" [("id","theguid-close"), ("class","topButtons"), ("color","#990000"), ("textColor","#FFFFFF"), ("text","X"), ("height",controlHeight), ("width",controlHeight), ("onClick","theguid/closeUI")] []
          ]
        ],
        LUI "Row" [("id","theguid-scrollRow"), ("preferredHeight",scrollHeight)] [
          LUI "VerticalScrollView" [("id","theguid-scrollView"), ("scrollSensitivity","30"), ("height",scrollHeight), ("width",width)] [
            LUI "TableLayout" [("padding","10"), ("cellPadding","5"), ("horizontalOverflow","Wrap"), ("columnWidths",width), ("autoCalculateHeight","true")] 
              tableXml
          ]
        ],
        LUI "Row" [("preferredHeight",modelCountHeight)] [
          LUI "Text" [("id","theguid-modelcount"), ("padding","5"), ("height",modelCountHeight), ("alignment","UpperLeft"), ("text","Default"), ("rectAlignment","UpperLeft"), ("width",modelCountWidth), ("resizeTextForBestFit","true"), ("horizontalOverflow","Wrap"), ("resizeTextMinSize","6"), ("fontSize","18"), ("resizeTextMaxSize","30")] []
        ],
        LUI "Row" [("preferredHeight",fnBtnHeight)] [
          LUI "HorizontalLayout" [("rectAlignment","UpperRight"), ("preferredHeight",fnBtnHeight)] [
            redBtn,
            greenBtn,
            blueBtn,
            purpleBtn,
            yellowBtn,
            whiteBtn,
            orangeBtn,
            tealBtn,
            pinkBtn,
            noneBtn
          ]
        ]
      ]
    ] where
        height = numToT heightN
        controlHeight = numToT controlHeightN
        modelCountHeightN = controlHeightN * 2
        modelCountHeight = numToT modelCountHeightN
        modelCountWidthN = widthN `quot` 2
        modelCountWidth = numToT modelCountWidthN
        fnBtnWidthN = widthN `quot` 4
        fnBtnWidth = numToT fnBtnWidthN
        fnBtnHeightN = (controlHeightN * 3) `quot` 4
        fnBtnHeight = numToT fnBtnHeightN
        buttonPanelWidthN = controlHeightN
        buttonPanelWidth = numToT buttonPanelWidthN
        scrollHeight = numToT (heightN - controlHeightN - modelCountHeightN)
        width = numToT widthN
        tableXml = imap (tableToXml widthN) tables
        colorHighlightButton colorName hexCode = LUI "Button" [("id","theguid-coherency-" <> colorName), ("height", fnBtnHeight), ("color", hexCode), ("width", fnBtnHeight), ("onClick","theguid/highlightUnit" <> colorName)] []
        redBtn = colorHighlightButton "Red" "#BB2222"
        greenBtn = colorHighlightButton "Green" "#22BB22"
        blueBtn = colorHighlightButton "Blue" "#2222BB"
        purpleBtn = colorHighlightButton "Purple" "#BB22BB"
        yellowBtn = colorHighlightButton "Yellow" "#DDDD22"
        whiteBtn = colorHighlightButton "White" "#FFFFFF"
        orangeBtn = colorHighlightButton "Orange" "#DD6633"
        tealBtn = colorHighlightButton "Teal" "#29D9D9"
        pinkBtn = colorHighlightButton "Pink" "#DD77CC"
        noneBtn = colorHighlightButton "None" "#BBBBBB"


data Table = Table {
    columnWidthPercents :: [Double],
    headerHeight        :: Integer,
    textSize            :: Integer,
    headerTextSize      :: Integer,
    header              :: [T.Text],
    rows                :: [[T.Text]]
} deriving Show

oneCellTable header = Table [1] 40 15 20 [header] []
oneRowTable header row = Table [1] 40 15 20 [header] [[row]]
normalTable header rows widths = Table widths 40 18 20 header rows

numToT :: Integer -> T.Text
numToT = T.pack . show

inferRowHeight :: Integer -> [T.Text] -> Integer
inferRowHeight tableWidth = maximum . map (inferCellHeight tableWidth)

inferCellHeight :: Integer -> T.Text -> Integer
inferCellHeight tableWidth t = maximum [(ceiling(tLen / lengthPerLine) + newlines) * 20, 80] where
  newlines = fromIntegral (T.count "\n" t)
  tLen = fromIntegral $ T.length t
  tableWidthFloat = fromIntegral tableWidth :: Double
  lengthPerLine = 80.0 * (tableWidthFloat / 900.0)

tableToXml :: Integer -> Int -> Table -> LuaUIElement
tableToXml tableWidth index Table{..} =  LUI "Row" [("id","theguid-rowtab-" <> idex), ("preferredHeight",tableHeight)] [
    LUI "TableLayout" [("autoCalculateHeight","false"), ("cellPadding","5"),("columnWidths",colWidths)] (headerText : bodyText)]
  where
    idex = T.pack( show index)
    asId k i = "theguid-" <> idex <> "-" <> k <> "-" <> T.pack (show i)
    rowHeights = map (inferRowHeight tableWidth) rows
    tableHeight = numToT $ headerHeight + sum rowHeights
    colWidths = T.intercalate " " $ map (numToT . floor . (* fromIntegral tableWidth)) columnWidthPercents
    headHeight = numToT headerHeight
    tSize = numToT textSize
    htSize = numToT headerTextSize
    headerText = tRow (asId "header" 0) htSize "Bold" headHeight (map escapes header)
    rowsAndHeights = zip rowHeights rows
    bodyText = imap (\index (height, row) -> (tRow (asId "row" index) tSize "Normal" (numToT height) . map escapes) row) rowsAndHeights

tCell :: T.Text -> T.Text -> T.Text -> LuaUIElement
tCell fs stl val = LUI "Cell" [] [LUI "Text" [("resizeTextForBestFit","true"), ("resizeTextMaxSize",fs), ("resizeTextMinSize","6"),
  ("text",val), ("fontStyle",stl), ("fontSize",fs)] []]

tRow :: T.Text -> T.Text -> T.Text -> T.Text -> [T.Text] -> LuaUIElement
tRow id fs stl h vals = LUI "Row" [("id", id), ("flexibleHeight","1"), ("preferredHeight",h)] cells where
  cells = map (tCell fs stl) vals

child :: ArrowXml a => String -> a XmlTree XmlTree
child tag = getChildren >>> hasName tag

getAttrValueT :: ArrowXml a => String -> a XmlTree T.Text
getAttrValueT attr = getAttrValue attr >>> arr T.pack

data LuaUIElement = LUI T.Text [(T.Text, T.Text)] [LuaUIElement]

toLua :: LuaUIElement -> T.Text
toLua (LUI tag attributes children) = [NI.text| {tag = "$tag", attributes = { $attrs }, children = { $chil }} |] where
  attrs = T.intercalate ", " $ fmap attrToString attributes
  chil = T.intercalate ", " $ fmap toLua children

attrToString :: (T.Text, T.Text) -> T.Text
attrToString (attrKey, attrVal) = [NI.text| $attrKey = "$attrVal" |]

