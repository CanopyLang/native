{-# LANGUAGE OverloadedStrings #-}

-- | Module extraction (AUTO-D-JNI, plan §5 Phase D) — turn a hand-wired in-HOST native module
-- into a self-contained @canopy/*@ package, the native analogue of a web capability package that
-- ships its own @external/*.js@.
--
-- The autolinking substrate (AUTO-A/B/C) already discovers a package's @native.json@ + native
-- sources and generates the registrant + build includes. What was MISSING was that the ~14
-- pure-JNI capabilities still lived inside the host app (@host/android/.../modules/<Name>Module.java@
-- + @host/ios/.../Canopy<Name>Module.mm@), registered by a hand-maintained block in
-- @CanopyHostJni.cpp@ / @CanopyModuleHost.mm@. This module makes them PACKAGE-RESIDENT:
--
--   1. it knows the canonical @ExtractSpec@ for each pure-JNI capability (its package dir, its
--      module name, whether it has an iOS impl, its Android permissions, its streaming methods); and
--   2. 'extractModule' materializes the package's native side — copying the host Java (+ iOS .mm)
--      into @<pkg>/native/android@ (+ @<pkg>/native/ios@) and writing the @native.json@ manifest —
--      so @canopy-native build@ autolinks the capability from the dependency graph with ZERO host
--      edits, exactly like @canopy/ping@.
--
-- This is the mechanical "Phase D" half. DELETING the host's now-redundant hardcoded registration
-- block (and the in-host source files) is Phase E (AUTO-E-DELETE); this module is what makes that
-- deletion safe, by proving every capability has a package-resident equivalent the generated
-- registrant covers.
--
-- The pure-Canopy @.can@ side is intentionally NOT moved here: the @Native.*@ effect modules
-- (@Native.Http@, @Native.Vibration@, …) are exposed by @canopy/native@ core and imported as such
-- by existing apps (e.g. examples/captest imports @Native.Vibration@); a capability package that
-- owns its OWN top-level module (Image/Photos/Album/ShareImage/Notify/Http) already ships that
-- @.can@ in its @src/@. Re-homing the core @Native.*@ modules is a separate, breaking change.
module Canopy.Native.Extract
  ( ExtractSpec (..)
  , AndroidPerm (..)
  , pureJniSpecs
  , renderNativeJson
  , androidImplFileName
  , iosImplFileName
  , extractModule
  , extractAll
  , ExtractResult (..)
  ) where

import           Canopy.Native.Autolink (IosPermission (..))
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import           System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import           System.FilePath ((</>))

-- | One Android @uses-permission@ a capability needs in the host @AndroidManifest.xml@ (the
-- Android analogue of an 'IosPermission'). Travels with the package via @native.json@ so adding
-- the dependency adds the permission, mirroring the web rule "permissions travel with the package".
newtype AndroidPerm = AndroidPerm { apName :: Text } deriving (Eq, Show)

-- | The canonical description of a pure-JNI capability to extract from the host into its package.
data ExtractSpec = ExtractSpec
  { esModule      :: !Text            -- ^ the C1 ABI module name, e.g. "Http" (-> JniModule("Http"))
  , esPackageDir  :: !FilePath        -- ^ the package dir under the monorepo root, e.g. "http"
  , esHasIos      :: !Bool            -- ^ does the host ship a Canopy<Name>Module.mm for it?
  , esStreaming   :: ![Text]          -- ^ streaming method names ([] for a pure one-shot JNI module)
  , esAndroidPerms:: ![AndroidPerm]   -- ^ AndroidManifest uses-permission entries the cap needs
  , esIosPerms    :: ![IosPermission] -- ^ Info.plist usage-description keys the cap needs
  } deriving (Eq, Show)

-- | A simple spec with no permissions and no streaming (the common pure one-shot capability).
plain :: Text -> FilePath -> Bool -> ExtractSpec
plain name dir hasIos = ExtractSpec name dir hasIos [] [] []

-- | The canonical set of pure-JNI capabilities that are SAFE to extract (no host static
-- back-dependency, no Activity-result wiring, no streaming). Notably EXCLUDED:
--
--   * @Photos@ — its picker rides MainActivity's @registerForActivityResult@ launcher, and
--     MainActivity statically calls @PhotosModule.onPickResult@; it is not pure-JNI yet.
--   * @Billing@ / @Lifecycle@ / @AppShell@ / @RestoreEngine@ — C++/streaming (AUTO-D-CPP-STREAMING).
--
-- Each entry names the existing host source so 'extractModule' can copy it into the package.
pureJniSpecs :: [ExtractSpec]
pureJniSpecs =
  [ -- Capabilities that already own a top-level @.can@ in their package's @src/@:
    plain "Image"      "image"      True
  , plain "Album"      "album"      True
  , plain "ShareImage" "share-image" True
  , plain "StorageSecure" "storage-secure" True
  , (plain "Notify"    "notify"     True)
      { esAndroidPerms = [ AndroidPerm "android.permission.POST_NOTIFICATIONS" ] }
  , (plain "Http"      "http"       True)
      { esAndroidPerms = [ AndroidPerm "android.permission.INTERNET" ] }
    -- Capabilities whose pure-Canopy module is the core @Native.*@ module (the @.can@ stays in
    -- canopy/native core; only the native impl + manifest move into the package):
  , plain "Platform"  "platform"   True
  , plain "Vibration"  "vibration"  False
  , plain "Battery"    "battery"    False
  , plain "DeviceInfo" "device-info" False
  , (plain "NetInfo"   "net-info"   False)
      { esAndroidPerms = [ AndroidPerm "android.permission.ACCESS_NETWORK_STATE" ] }
  , plain "Haptics"    "haptics"    False
  , plain "Brightness" "brightness" False
  ]

-- | The host Java source file name for a capability, e.g. "HttpModule.java".
androidImplFileName :: ExtractSpec -> FilePath
androidImplFileName es = T.unpack (esModule es) <> "Module.java"

-- | The host iOS source file name for a capability, e.g. "CanopyHttpModule.mm".
iosImplFileName :: ExtractSpec -> FilePath
iosImplFileName es = "Canopy" <> T.unpack (esModule es) <> "Module.mm"

-- | Render the @native.json@ manifest for a spec — the exact schema 'Canopy.Native.Autolink'
-- parses ('NativeManifest'). Built as text by hand (matching the codebase's codegen style in
-- 'Canopy.Native.Autolink') so the tool keeps a minimal dependency set; the JSON is small and
-- fully determined by the spec, so a hand-emitter is unambiguous and stable.
renderNativeJson :: ExtractSpec -> Text
renderNativeJson es = T.unlines $
  [ "{" ]
  ++ field "_comment" (jstr comment)
  ++ [ "  \"modules\": [" ]
  ++ [ "    { \"name\": " <> jstr (esModule es)
         <> streamingField <> ", \"kind\": \"jni\" }" ]
  ++ [ "  ]," ]
  ++ [ "  \"androidSource\": " <> jstr "native/android" <> iosComma ]
  ++ iosLine
  ++ permsLines
  ++ [ "}" ]
  where
    -- "streaming": [...] only when the module emits Subs (a pure JNI module omits it).
    streamingField
      | null (esStreaming es) = ""
      | otherwise = ", \"streaming\": [" <> T.intercalate ", " (map jstr (esStreaming es)) <> "]"
    -- Trailing comma after androidSource iff something follows it (iosSource or permissions).
    iosComma = if esHasIos es || hasPerms then "," else ""
    iosLine
      | esHasIos es = [ "  \"iosSource\": " <> jstr "native/ios" <> (if hasPerms then "," else "") ]
      | otherwise   = []
    hasPerms = not (null (esAndroidPerms es)) || not (null (esIosPerms es))
    -- "permissions": { "android": [...], "ios": { key: desc } } — both halves optional.
    permsLines
      | not hasPerms = []
      | otherwise =
          [ "  \"permissions\": {" ]
          ++ androidPermLines
          ++ iosPermLines
          ++ [ "  }" ]
    androidPermLines
      | null (esAndroidPerms es) = []
      | otherwise =
          [ "    \"android\": ["
              <> T.intercalate ", " (map (jstr . apName) (esAndroidPerms es))
              <> "]" <> (if null (esIosPerms es) then "" else ",") ]
    iosPermLines
      | null (esIosPerms es) = []
      | otherwise =
          [ "    \"ios\": {" ]
          ++ commaJoin [ "      " <> jstr (ipKey p) <> ": " <> jstr (ipDescription p)
                       | p <- esIosPerms es ]
          ++ [ "    }" ]
    field k v = [ "  " <> jstr k <> ": " <> v <> "," ]
    comment :: Text
    comment =
      "native.json — the canopy-native autolink manifest for canopy/" <> T.pack (esPackageDir es)
      <> ". GENERATED by `canopy-native extract-modules` (AUTO-D-JNI). The COMPILER never reads "
      <> "this; only `canopy-native` does. Declaring the module here + shipping native/android "
      <> "(+ native/ios) is all it takes to autolink this capability into an app with NO host edits."

-- | Join lines with a trailing comma on every line but the last (for JSON object/array bodies).
commaJoin :: [Text] -> [Text]
commaJoin []  = []
commaJoin [x] = [x]
commaJoin (x : rest) = (x <> ",") : commaJoin rest

-- | JSON string literal with the minimal escaping native.json values need (quote + backslash).
jstr :: Text -> Text
jstr t = "\"" <> T.replace "\"" "\\\"" (T.replace "\\" "\\\\" t) <> "\""

-- | The outcome of extracting one module, for a human-readable report.
data ExtractResult = ExtractResult
  { erModule       :: !Text
  , erPackageDir   :: !FilePath
  , erAndroidCopied:: !Bool      -- ^ the host Java impl was found + copied into the package
  , erIosCopied    :: !Bool      -- ^ the host iOS impl was found + copied (only when esHasIos)
  , erManifest     :: !FilePath  -- ^ the written native.json path
  } deriving (Eq, Show)

-- | Extract ONE capability into its package: copy @<Name>Module.java@ from the host Android tree
-- into @<pkg>/native/android/@, copy @Canopy<Name>Module.mm@ from the host iOS tree into
-- @<pkg>/native/ios/@ (when it exists), and write @<pkg>/native.json@.
--
-- @hostAndroidModules@ = the host's @app/src/main/java/com/canopyhost/modules@ dir.
-- @hostIosModules@     = the host's @CanopyHostCore/Modules@ dir.
-- @pkgRoot@            = the package's root dir (where @canopy.json@ + the new @native.json@ live).
--
-- Copying (not moving) keeps the host compiling during Phase D; Phase E (AUTO-E-DELETE) removes the
-- now-duplicate host source. The copy is skipped (and reported) if the host source is absent, so
-- this is idempotent + safe to re-run.
extractModule :: FilePath -> FilePath -> FilePath -> ExtractSpec -> IO ExtractResult
extractModule hostAndroidModules hostIosModules pkgRoot es = do
  let androidDir = pkgRoot </> "native" </> "android"
      iosDir     = pkgRoot </> "native" </> "ios"
      javaSrc    = hostAndroidModules </> androidImplFileName es
      javaDst    = androidDir </> androidImplFileName es
      iosSrc     = hostIosModules </> iosImplFileName es
      iosDst     = iosDir </> iosImplFileName es
      manifest   = pkgRoot </> "native.json"
  createDirectoryIfMissing True androidDir
  javaThere <- doesFileExist javaSrc
  androidCopied <-
    if javaThere then copyFile javaSrc javaDst >> pure True else pure False
  iosCopied <-
    if esHasIos es
      then do
        createDirectoryIfMissing True iosDir
        iosThere <- doesFileExist iosSrc
        if iosThere then copyFile iosSrc iosDst >> pure True else pure False
      else pure False
  BL.writeFile manifest (BL.fromStrict (TE.encodeUtf8 (renderNativeJson es)))
  pure ExtractResult
    { erModule        = esModule es
    , erPackageDir    = pkgRoot
    , erAndroidCopied = androidCopied
    , erIosCopied     = iosCopied
    , erManifest      = manifest
    }

-- | Extract every 'pureJniSpec' into its package under @monorepoRoot@. The host source dirs are
-- the fixed canopy/native locations under @hostRoot@ (= canopy/native/host).
extractAll :: FilePath -> FilePath -> IO [ExtractResult]
extractAll monorepoRoot hostRoot =
  mapM (\es -> extractModule hostAndroidModules hostIosModules (monorepoRoot </> esPackageDir es) es)
       pureJniSpecs
  where
    hostAndroidModules = hostRoot </> "android" </> "app" </> "src" </> "main"
                           </> "java" </> "com" </> "canopyhost" </> "modules"
    hostIosModules     = hostRoot </> "ios" </> "CanopyHostCore" </> "Modules"
