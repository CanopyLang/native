{-# LANGUAGE DeriveGeneric #-}

-- | The @native.config.json@ project descriptor: what a canopy/native app build needs
-- beyond @canopy.json@ — the entry module, the app display name, and any custom Fabric
-- components to fold into the generated mapping.
module Canopy.Native.Config
  ( NativeConfig (..)
  , defaultConfig
  , decodeConfig
  , encodeConfig
  ) where

import           Data.Aeson
import qualified Data.ByteString.Lazy as BL
import           Data.Text (Text)
import           GHC.Generics (Generic)

-- | Parsed @native.config.json@.
data NativeConfig = NativeConfig
  { ncAppName    :: !Text        -- ^ human-facing app name (host display name)
  , ncBundleId   :: !Text        -- ^ reverse-DNS id, e.g. "org.canopy.counter"
  , ncMainModule :: !Text        -- ^ Canopy module exposing @main@, e.g. "Main"
  , ncEntry      :: !FilePath     -- ^ path to that module's source, e.g. "src/Main.can"
  , ncOutputDir  :: !FilePath     -- ^ where build artifacts land, e.g. "build"
  , ncRuntimeVersion :: !Text     -- ^ host-ABI version the bundle targets (OTA gating); default "1"
  , ncAssets     :: ![FilePath]   -- ^ extra files (images/fonts/model) to content-hash + ship
  } deriving (Eq, Show, Generic)

instance FromJSON NativeConfig where
  parseJSON = withObject "NativeConfig" $ \o ->
    NativeConfig
      <$> o .:  "appName"
      <*> o .:  "bundleId"
      <*> o .:? "mainModule" .!= "Main"
      <*> o .:? "entry"      .!= "src/Main.can"
      <*> o .:? "outputDir"  .!= "build"
      <*> o .:? "runtimeVersion" .!= "1"
      <*> o .:? "assets"     .!= []

instance ToJSON NativeConfig where
  toJSON c =
    object
      [ "appName"    .= ncAppName c
      , "bundleId"   .= ncBundleId c
      , "mainModule" .= ncMainModule c
      , "entry"      .= ncEntry c
      , "outputDir"  .= ncOutputDir c
      , "runtimeVersion" .= ncRuntimeVersion c
      , "assets"     .= ncAssets c
      ]

-- | A sensible default config for a freshly scaffolded app.
defaultConfig :: Text -> Text -> NativeConfig
defaultConfig name bundleId =
  NativeConfig
    { ncAppName = name
    , ncBundleId = bundleId
    , ncMainModule = "Main"
    , ncEntry = "src/Main.can"
    , ncOutputDir = "build"
    , ncRuntimeVersion = "1"
    , ncAssets = []
    }

-- | Parse config bytes.
decodeConfig :: BL.ByteString -> Either String NativeConfig
decodeConfig = eitherDecode

-- | Serialize config to bytes.
encodeConfig :: NativeConfig -> BL.ByteString
encodeConfig = encode
