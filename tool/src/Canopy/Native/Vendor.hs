{-# LANGUAGE OverloadedStrings #-}

-- | Vendor provenance lock (RNV-1).
--
-- Every third-party artifact the native host ships — the Hermes\/JSI\/fbjni prebuilts,
-- the onnxruntime prebuilt, the header trees they come with, and the iOS pod pins — is
-- recorded in a committed @host\/vendor.lock.json@ with its source, version, date, and
-- (for files) a sha256 + size. The generator walks the REAL files on disk; the verifier
-- recomputes and diffs, returning a structured per-artifact mismatch list so a checksum
-- drift "fails loud" (names the file, expected != actual) instead of silently shipping a
-- swapped binary. This is the substrate every later ABI gate consumes.
--
-- Design mirrors "Canopy.Native.Assets": same 'sha256Hex', same aeson @object@\/@.=@
-- serialization, plus a 'FromJSON' (like "Canopy.Native.Config") so the committed lock can
-- be re-read and diffed. Header trees are hashed order-independently (a digest over the
-- sorted @relpath\\tsha256@ lines) so the lock is deterministic regardless of readdir order.
module Canopy.Native.Vendor
  ( -- * Static manifest
    ArtifactSpec (..)
  , ArtifactKind (..)
  , vendoredArtifacts
    -- * Lock records
  , LockEntry (..)
  , LockFile (..)
    -- * Generate / verify
  , Mismatch (..)
  , generateLock
  , verifyLock
  , renderLock
  , decodeLock
    -- * Repo root resolution
  , resolveRoot
    -- * Tree digest (exported for testing)
  , treeDigest
  ) where

import           Canopy.Native.Assets (sha256Hex)
import           Control.Monad (foldM)
import           Data.Aeson (FromJSON (..), ToJSON (..), eitherDecode, encode,
                             object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson.Types as AT
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import           Data.List (sort, sortOn)
import           Data.Maybe (catMaybes)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           System.Directory (doesDirectoryExist, doesFileExist, getFileSize,
                                    listDirectory)
import           System.FilePath ((</>))

-- ---------------------------------------------------------------------------
-- Static manifest: WHAT to lock + the provenance facts.
-- ---------------------------------------------------------------------------

-- | The shape of a vendored artifact.
data ArtifactKind
  = KindBinary   -- ^ a single prebuilt file: sha256 + size are recorded.
  | KindTree     -- ^ a header directory: an order-independent digest of the tree.
  | KindPodPin   -- ^ an iOS CocoaPods pin: version only, no checksum (no binary in-repo).
  deriving (Eq, Ord, Show)

-- | One artifact to lock. @asPath@ is the repo-root-relative path (a file for 'KindBinary',
-- a directory for 'KindTree'; for 'KindPodPin' it is the pod name and no file is read).
data ArtifactSpec = ArtifactSpec
  { asPath    :: !Text          -- ^ repo-root-relative path (or pod name for a pod-pin)
  , asKind    :: !ArtifactKind
  , asSource  :: !Text          -- ^ where it came from (AAR / prebuilt / pod)
  , asVersion :: !Text          -- ^ pinned upstream version
  , asDate    :: !Text          -- ^ vendoring date (YYYY-MM-DD)
  } deriving (Eq, Show)

-- | The complete inventory the lock must cover. Source\/version\/date facts are baked in
-- from binary @strings@ + repo docs (see RNV-1 spec). Files are walked at generate time.
vendoredArtifacts :: [ArtifactSpec]
vendoredArtifacts =
     -- Hermes / JSI / fbjni prebuilts (React Native 0.76.9 AARs), per-ABI .so files.
     [ bin (abi </> lib) | abi <- ["arm64-v8a", "x86_64"]
                         , lib <- ["libhermes.so", "libjsi.so", "libfbjni.so"] ]
  ++ -- onnxruntime prebuilt (1.26.0), per-ABI .so files.
     [ onnx (abi </> "libonnxruntime.so") | abi <- ["arm64-v8a", "x86_64"] ]
  ++ -- Header trees (hashed order-independently).
     [ tree "host/android/vendor/hermes-include"        rnSrc       rnVer
     , tree "host/android/vendor/jsi-include"           rnSrc       rnVer
     , tree "host/android/vendor/onnxruntime/include"   onnxSrc     onnxVer
     , tree "host/shared/third_party/jsi/jsi"           rnSrc       rnVer
     ]
  ++ -- iOS pod pins (no in-repo binary — version provenance only).
     [ pod "hermes-engine" rnVer
     , pod "Yoga"          rnVer
     ]
  where
    rnSrc   = "react-native 0.76.9 (hermes-android / react-android / fbjni AARs)"
    rnVer   = "0.76.9"
    onnxSrc = "onnxruntime-android prebuilt"
    onnxVer = "1.26.0"
    vendDate = "2026-06-12"

    bin rel  = ArtifactSpec ("host/android/vendor/lib/" <> T.pack rel) KindBinary rnSrc rnVer vendDate
    onnx rel = ArtifactSpec ("host/android/vendor/onnxruntime/lib/" <> T.pack rel) KindBinary onnxSrc onnxVer vendDate
    tree p s v = ArtifactSpec (T.pack p) KindTree s v vendDate
    pod name v = ArtifactSpec name KindPodPin "CocoaPods (react-native 0.76.9)" v vendDate

-- ---------------------------------------------------------------------------
-- Lock records.
-- ---------------------------------------------------------------------------

-- | One recorded artifact in the lockfile. @leSha@\/@leSize@ are 'Nothing' for pod pins.
data LockEntry = LockEntry
  { leRelPath :: !Text
  , leKind    :: !ArtifactKind
  , leSource  :: !Text
  , leVersion :: !Text
  , leDate    :: !Text
  , leSha     :: !(Maybe Text)     -- ^ sha256 (binary: of the bytes; tree: tree digest)
  , leSize    :: !(Maybe Integer)  -- ^ bytes (binary only; total bytes for a tree)
  } deriving (Eq, Show)

-- | The committed lockfile: a schema version, a generated-at stamp, and the entries.
-- Entries are sorted by relPath so the file is deterministic.
data LockFile = LockFile
  { lfGeneratedAt :: !Text         -- ^ free-form stamp (not part of the verify surface)
  , lfEntries     :: ![LockEntry]
  } deriving (Eq, Show)

kindText :: ArtifactKind -> Text
kindText KindBinary = "binary"
kindText KindTree   = "tree"
kindText KindPodPin = "pod-pin"

kindFromText :: Text -> AT.Parser ArtifactKind
kindFromText "binary"  = pure KindBinary
kindFromText "tree"    = pure KindTree
kindFromText "pod-pin" = pure KindPodPin
kindFromText other     = fail ("unknown artifact kind: " <> T.unpack other)

instance ToJSON LockEntry where
  toJSON e = object $
    [ "relPath" .= leRelPath e
    , "kind"    .= kindText (leKind e)
    , "source"  .= leSource e
    , "version" .= leVersion e
    , "date"    .= leDate e
    ]
    ++ maybe [] (\s -> ["sha256" .= s]) (leSha e)
    ++ maybe [] (\s -> ["size"   .= s]) (leSize e)

instance FromJSON LockEntry where
  parseJSON = withObject "LockEntry" $ \o -> do
    kindStr <- o .: "kind"
    kind    <- kindFromText kindStr
    LockEntry
      <$> o .:  "relPath"
      <*> pure kind
      <*> o .:  "source"
      <*> o .:  "version"
      <*> o .:  "date"
      <*> o .:? "sha256"
      <*> o .:? "size"

instance ToJSON LockFile where
  toJSON lf = object
    [ "schema"      .= (1 :: Int)
    , "generatedAt" .= lfGeneratedAt lf
    , "artifacts"   .= lfEntries lf
    ]

instance FromJSON LockFile where
  parseJSON = withObject "LockFile" $ \o ->
    LockFile
      <$> o .:? "generatedAt" AT..!= ""
      <*> o .:  "artifacts"

-- | Serialize the lockfile to JSON.
renderLock :: LockFile -> BL.ByteString
renderLock = encode

-- | Parse lockfile bytes.
decodeLock :: BL.ByteString -> Either String LockFile
decodeLock = eitherDecode

-- ---------------------------------------------------------------------------
-- Tree digest: order-independent over a header directory.
-- ---------------------------------------------------------------------------

-- | Recursively list every file under a directory, as paths relative to it.
listTreeFiles :: FilePath -> IO [FilePath]
listTreeFiles root = go ""
  where
    go rel = do
      let dir = root </> rel
      names <- listDirectory dir
      fmap concat $ mapM (visit rel) names
    visit rel name = do
      let relChild = if null rel then name else rel </> name
          abs'     = root </> relChild
      isDir <- doesDirectoryExist abs'
      if isDir
        then go relChild
        else do
          isFile <- doesFileExist abs'
          pure [relChild | isFile]

-- | Order-independent digest of a header tree, plus its total byte size.
--
-- The digest is the sha256 of the sorted @"relpath\\tsha256"@ lines (one per file), so
-- two runs agree regardless of readdir order. Returns 'Nothing' if the directory is absent.
treeDigest :: FilePath -> IO (Maybe (Text, Integer))
treeDigest dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure Nothing
    else do
      rels <- listTreeFiles dir
      lns  <- mapM lineFor (sort rels)
      let totalSize = sum (map snd lns)
          payload   = TE.encodeUtf8 (T.unlines (map fst lns))
      pure (Just (sha256Hex payload, totalSize))
  where
    lineFor rel = do
      bytes <- BS.readFile (dir </> rel)
      size  <- getFileSize (dir </> rel)
      let normRel = T.pack (map slash rel)   -- normalize separators for cross-OS stability
      pure (normRel <> "\t" <> sha256Hex bytes, size)
    slash '\\' = '/'
    slash c    = c

-- ---------------------------------------------------------------------------
-- Generate.
-- ---------------------------------------------------------------------------

-- | Compute a 'LockEntry' for one artifact spec, walking the real file(s) under @root@.
-- Returns 'Nothing' if a 'KindBinary'\/'KindTree' artifact is missing on disk (the generator
-- skips it with that signal; the verifier treats a missing-vs-recorded file as a mismatch).
entryFor :: FilePath -> ArtifactSpec -> IO (Maybe LockEntry)
entryFor root spec = case asKind spec of
  KindPodPin -> pure (Just base)   -- pod pins carry no file; always present.
  KindBinary -> do
    let path = root </> T.unpack (asPath spec)
    exists <- doesFileExist path
    if not exists
      then pure Nothing
      else do
        bytes <- BS.readFile path
        size  <- getFileSize path
        pure (Just base { leSha = Just (sha256Hex bytes), leSize = Just size })
  KindTree -> do
    md <- treeDigest (root </> T.unpack (asPath spec))
    case md of
      Nothing          -> pure Nothing
      Just (dig, size) -> pure (Just base { leSha = Just dig, leSize = Just size })
  where
    base = LockEntry
      { leRelPath = asPath spec
      , leKind    = asKind spec
      , leSource  = asSource spec
      , leVersion = asVersion spec
      , leDate    = asDate spec
      , leSha     = Nothing
      , leSize    = Nothing
      }

-- | Generate a 'LockFile' over a static manifest, rooted at @root@. @stamp@ is the
-- @generatedAt@ value (the CLI passes the current date; tests pass a fixed string so the
-- output is byte-stable). Entries are sorted by relPath for determinism.
generateLock :: FilePath -> Text -> [ArtifactSpec] -> IO LockFile
generateLock root stamp specs = do
  entries <- catMaybes <$> mapM (entryFor root) specs
  pure (LockFile stamp (sortOn leRelPath entries))

-- ---------------------------------------------------------------------------
-- Verify.
-- ---------------------------------------------------------------------------

-- | A single verification failure, with enough detail to "fail loud".
data Mismatch = Mismatch
  { mmRelPath  :: !Text
  , mmReason   :: !Text         -- ^ human reason: "sha256 drift", "missing file", "size drift", ...
  , mmExpected :: !Text         -- ^ what the committed lock recorded
  , mmActual   :: !Text         -- ^ what was recomputed on disk now
  } deriving (Eq, Show)

-- | Recompute every artifact in the committed lock and diff it against what the lock records.
-- Returns @[]@ when everything matches, or one 'Mismatch' per drifted\/missing artifact.
-- Pod pins are skipped (no checksum to verify — their provenance is the recorded version).
verifyLock :: FilePath -> LockFile -> IO [Mismatch]
verifyLock root lf = foldM step [] (lfEntries lf)
  where
    step acc entry = do
      ms <- verifyEntry root entry
      pure (acc ++ ms)

verifyEntry :: FilePath -> LockEntry -> IO [Mismatch]
verifyEntry root entry = case leKind entry of
  KindPodPin -> pure []   -- version-pin only; nothing on disk to recompute.
  KindBinary -> do
    let path = root </> T.unpack (leRelPath entry)
    exists <- doesFileExist path
    if not exists
      then pure [missing]
      else do
        bytes <- BS.readFile path
        size  <- getFileSize path
        pure (diffShaSize (sha256Hex bytes) size)
  KindTree -> do
    md <- treeDigest (root </> T.unpack (leRelPath entry))
    case md of
      Nothing          -> pure [missing]
      Just (dig, size) -> pure (diffShaSize dig size)
  where
    missing = Mismatch (leRelPath entry) "missing file/dir"
                       (maybe "<no recorded sha>" id (leSha entry)) "<absent on disk>"
    diffShaSize actualSha actualSize =
      let expectedSha = maybe "" id (leSha entry)
          shaBad  = leSha entry  /= Just actualSha
          sizeBad = leSize entry /= Just actualSize
      in if shaBad
           then [Mismatch (leRelPath entry) "sha256 drift" expectedSha actualSha]
           else if sizeBad
             then [Mismatch (leRelPath entry) "size drift"
                            (maybe "" (T.pack . show) (leSize entry))
                            (T.pack (show actualSize))]
             else []

-- ---------------------------------------------------------------------------
-- Repo-root resolution.
-- ---------------------------------------------------------------------------

-- | Resolve the repo root: if @--root@ was given use it; otherwise walk up from the CWD to
-- the first ancestor that contains a @host/@ directory (the canopy/native marker).
resolveRoot :: Maybe FilePath -> FilePath -> IO (Maybe FilePath)
resolveRoot (Just r) _   = do
  ok <- doesDirectoryExist (r </> "host")
  pure (if ok then Just r else Nothing)
resolveRoot Nothing  cwd = walkUp cwd
  where
    walkUp dir = do
      hasHost <- doesDirectoryExist (dir </> "host")
      if hasHost
        then pure (Just dir)
        else let parent = takeParent dir
             in if parent == dir then pure Nothing else walkUp parent
    takeParent d =
      let trimmed = reverse (dropWhile (/= '/') (drop 1 (reverse d)))
      in if null trimmed then "/" else trimmed
