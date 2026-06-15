{-# LANGUAGE DeriveGeneric #-}

-- | The typed model of a native component and its props: the single source of truth
-- the codegen turns into a Fabric mapping for every target (JSON manifest, C++ header,
-- TypeScript). This is the Canopy-side of "map @Native@ attributes to Fabric props"
-- (feasibility report §2/§5) — hand-authored here, mirroring how React Native's own
-- Codegen maps a component spec to native view props.
module Canopy.Native.Component
  ( PropKind (..)
  , PropSpec (..)
  , ComponentSpec (..)
  , defaultComponents
  , floatStyleKeys
  , lookupComponent
  ) where

import           Data.Text (Text)
import qualified Data.Text as T

-- | How a Canopy fact value must be coerced before it reaches a Fabric prop. Canopy
-- emits all style values as strings (because @VirtualDom.style@ is @String -> String@);
-- Yoga wants floats for most layout props, so the host coerces using this kind.
data PropKind
  = PropString   -- ^ pass through as a string
  | PropFloat    -- ^ coerce a numeric-looking string to a float (Yoga layout)
  | PropColor    -- ^ a color string ("#rgb" / named) — host parses to a platform color
  | PropBool     -- ^ a boolean prop
  | PropEvent    -- ^ a gesture/text event the host must emit back into JS
  deriving (Eq, Show)

-- | One prop a component understands, plus how to coerce it.
data PropSpec = PropSpec
  { propName :: !Text
  , propKind :: !PropKind
  } deriving (Eq, Show)

-- | A native component: the Canopy tag the walker emits, the Fabric component name,
-- the platform view classes the host registers, and the props it accepts.
data ComponentSpec = ComponentSpec
  { compCanopyTag    :: !Text  -- ^ tag @external/native.js@ passes to @__fabric_createView@
  , compFabricName   :: !Text  -- ^ React Native component name
  , compIOSClass     :: !Text  -- ^ iOS Fabric component-view class
  , compAndroidClass :: !Text  -- ^ Android view-manager class
  , compProps        :: ![PropSpec]
  } deriving (Eq, Show)

-- | The built-in component set the wedge ships (feasibility report §5, item 2). Every
-- one is a stock React Native Fabric component, so the host registers nothing custom —
-- it only needs this mapping to coerce props. Adding a component is one entry here.
defaultComponents :: [ComponentSpec]
defaultComponents =
  [ viewLike "RCTView" "View" "RCTViewComponentView" "ReactViewManager"
  , textComponent
  , rawTextComponent
  , scrollComponent
  , imageComponent
  , textInputComponent
  ]

-- | A flexbox container (@view@/@column@/@row@/@pressable@ all map here).
viewLike :: Text -> Text -> Text -> Text -> ComponentSpec
viewLike tag name ios android =
  ComponentSpec tag name ios android (layoutProps ++ viewProps)

textComponent :: ComponentSpec
textComponent =
  ComponentSpec "RCTText" "Text" "RCTTextComponentView" "ReactTextViewManager"
    ( PropSpec "text" PropString
    : PropSpec "color" PropColor
    : PropSpec "fontSize" PropFloat
    : PropSpec "fontWeight" PropString
    : layoutProps ++ pressEvents )

rawTextComponent :: ComponentSpec
rawTextComponent =
  ComponentSpec "RCTRawText" "RawText" "RCTRawTextComponentView" "ReactRawTextManager"
    [ PropSpec "text" PropString ]

scrollComponent :: ComponentSpec
scrollComponent =
  ComponentSpec "RCTScrollView" "ScrollView" "RCTScrollViewComponentView" "ReactScrollViewManager"
    ( PropSpec "scroll" PropEvent : layoutProps ++ viewProps )

imageComponent :: ComponentSpec
imageComponent =
  ComponentSpec "RCTImageView" "Image" "RCTImageComponentView" "ReactImageManager"
    ( PropSpec "source" PropString : PropSpec "resizeMode" PropString : layoutProps )

textInputComponent :: ComponentSpec
textInputComponent =
  ComponentSpec "RCTSinglelineTextInputView" "TextInput"
    "RCTTextInputComponentView" "ReactTextInputManager"
    ( PropSpec "value" PropString
    : PropSpec "placeholder" PropString
    : PropSpec "editable" PropBool
    : PropSpec "changeText" PropEvent
    : PropSpec "submitEditing" PropEvent
    : layoutProps )

-- | Yoga flexbox props — all coerced to floats except the enum-ish alignment props.
layoutProps :: [PropSpec]
layoutProps =
  map (`PropSpec` PropFloat)
      [ "width", "height", "flex", "padding", "margin", "borderRadius"
      , "paddingHorizontal", "paddingVertical", "marginHorizontal", "marginVertical" ]
  ++ map (`PropSpec` PropString) [ "flexDirection", "alignItems", "justifyContent" ]

-- | Visual + interaction props common to container views.
viewProps :: [PropSpec]
viewProps =
  PropSpec "backgroundColor" PropColor
  : PropSpec "opacity" PropFloat
  : PropSpec "accessibilityRole" PropString
  : PropSpec "testID" PropString
  : pressEvents

pressEvents :: [PropSpec]
pressEvents =
  map (`PropSpec` PropEvent) [ "press", "longPress", "pressIn", "pressOut" ]

-- | The set of (tag, propName) pairs the host must coerce from string to float.
floatStyleKeys :: [ComponentSpec] -> [(Text, Text)]
floatStyleKeys comps =
  [ (compCanopyTag c, propName p)
  | c <- comps, p <- compProps c, propKind p == PropFloat ]

-- | Find a component by its Canopy tag.
lookupComponent :: Text -> [ComponentSpec] -> Maybe ComponentSpec
lookupComponent tag = go
  where
    go [] = Nothing
    go (c : rest) = if compCanopyTag c == T.strip tag then Just c else go rest
