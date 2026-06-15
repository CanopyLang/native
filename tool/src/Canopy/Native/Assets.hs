{-# LANGUAGE OverloadedStrings #-}

-- | Content-addressed asset manifest (Phase 4, OTA M0 / Managed-build M1).
--
-- Every native build emits a @canopy.manifest.json@: the sha256 of the assembled bundle (which
-- IS the @buildId@ / content address), the sha256+size of every declared asset, and the
-- @runtimeVersion@ the bundle is built against. This is the substrate three workstreams consume:
--   * OTA gates an update by @runtimeVersion@ + verifies the downloaded bundle's sha.
--   * Managed-build stamps releases + diffs assets by content hash.
--   * The host verifies the booted bundle against the manifest, killing the hand-copied-bundle
--     footgun (a stale @cp@ now surfaces as a loud mismatch instead of a silent wrong app).
module Canopy.Native.Assets
  ( AssetEntry (..)
  , BytecodeInfo (..)
  , AssetManifest (..)
  , sha256Hex
  , fileEntry
  , collectAssets
  , renderManifest
  ) where

import           Data.Aeson (ToJSON (..), encode, object, (.=))
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Lazy as BL
import           Data.Maybe (catMaybes)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           System.Directory (doesFileExist, getFileSize)
import           System.FilePath (takeFileName)

-- | One content-hashed file as it ships (named by basename).
data AssetEntry = AssetEntry
  { aeName :: !Text     -- ^ shipped name (basename)
  , aeSha  :: !Text     -- ^ lowercase-hex sha256 of the bytes
  , aeSize :: !Integer  -- ^ size in bytes
  } deriving (Eq, Show)

instance ToJSON AssetEntry where
  toJSON e = object [ "name" .= aeName e, "sha256" .= aeSha e, "size" .= aeSize e ]

-- | RNV-7: the real Hermes .hbc bytecode bundle's content address + the bytecode-format version
-- stamped in its header. The @biVersion@ is THE gated contract — the host's load gate
-- (CanopyAbiGate.h: checkBundleBytecode) and the engine both require it to equal the vendored
-- engine's @getBytecodeVersion()@ (pinned in CanopyAbiGate.h, asserted by scripts/check-abi.sh).
-- A build that emits no .hbc (no hermesc available) records 'Nothing', and the host boots the JS.
data BytecodeInfo = BytecodeInfo
  { biEntry   :: !AssetEntry  -- ^ the .hbc file's name + sha256 + size (named "canopy.bundle.hbc")
  , biVersion :: !Int         -- ^ the HBC bytecode-format version in the file header (offset 8)
  } deriving (Eq, Show)

instance ToJSON BytecodeInfo where
  toJSON b = object
    [ "name"    .= aeName (biEntry b)
    , "sha256"  .= aeSha (biEntry b)
    , "size"    .= aeSize (biEntry b)
    , "version" .= biVersion b
    ]

-- | The build manifest: the bundle's content address + its declared assets + the runtime it
-- targets. @amBuildId@ equals the (JS) bundle's sha256. When a real Hermes .hbc was emitted
-- (RNV-7), @amBytecode@ carries its content hash + bytecode-format version — the gated contract.
data AssetManifest = AssetManifest
  { amBundle         :: !AssetEntry
  , amAssets         :: ![AssetEntry]
  , amRuntimeVersion :: !Text
  , amBuildId        :: !Text
  , amBytecode       :: !(Maybe BytecodeInfo)
  } deriving (Eq, Show)

instance ToJSON AssetManifest where
  toJSON m = object $
    [ "schema"         .= (1 :: Int)
    , "buildId"        .= amBuildId m
    , "runtimeVersion" .= amRuntimeVersion m
    , "bundle"         .= amBundle m
    , "assets"         .= amAssets m
    ] ++ maybe [] (\b -> ["bytecode" .= b]) (amBytecode m)

-- | Lowercase-hex sha256 of a byte string.
sha256Hex :: BS.ByteString -> Text
sha256Hex = TE.decodeUtf8 . B16.encode . SHA256.hash

-- | Content-hash a file into an 'AssetEntry' (named by basename). 'Nothing' if it is missing.
fileEntry :: FilePath -> IO (Maybe AssetEntry)
fileEntry path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      bytes <- BS.readFile path
      size  <- getFileSize path
      pure (Just (AssetEntry (T.pack (takeFileName path)) (sha256Hex bytes) size))

-- | Content-hash every present file, dropping any that are missing.
collectAssets :: [FilePath] -> IO [AssetEntry]
collectAssets = fmap catMaybes . mapM fileEntry

-- | Serialize the manifest to compact JSON.
renderManifest :: AssetManifest -> BL.ByteString
renderManifest = encode
