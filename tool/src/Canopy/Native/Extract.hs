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
  , cppStreamingSpecs
  , allExtractSpecs
  , renderNativeJson
  , renderNativeJsonPackage
  , androidImplFileName
  , iosImplFileName
  , extractModule
  , extractModuleInto
  , extractAll
  , extractAllCppStreaming
  , ExtractResult (..)
  ) where

import           Canopy.Native.Autolink (IosPermission (..))
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import           System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import           System.FilePath ((</>), takeDirectory)

-- | One Android @uses-permission@ a capability needs in the host @AndroidManifest.xml@ (the
-- Android analogue of an 'IosPermission'). Travels with the package via @native.json@ so adding
-- the dependency adds the permission, mirroring the web rule "permissions travel with the package".
newtype AndroidPerm = AndroidPerm { apName :: Text } deriving (Eq, Show)

-- | The canonical description of a capability to extract from the host into its package. Covers
-- both the pure-JNI capabilities (AUTO-D-JNI) and the C++/streaming ones (AUTO-D-CPP-STREAMING:
-- Billing, Lifecycle, AppShell, RestoreEngine).
data ExtractSpec = ExtractSpec
  { esModule      :: !Text            -- ^ the C1 ABI module name, e.g. "Http" (-> JniModule("Http"))
  , esPackageDir  :: !FilePath        -- ^ the package dir under the monorepo root, e.g. "http"
  , esHasIos      :: !Bool            -- ^ does the host ship a Canopy<Name>Module.mm for it?
  , esStreaming   :: ![Text]          -- ^ streaming method names ([] for a pure one-shot JNI module)
  , esAndroidPerms:: ![AndroidPerm]   -- ^ AndroidManifest uses-permission entries the cap needs
  , esIosPerms    :: ![IosPermission] -- ^ Info.plist usage-description keys the cap needs
  , esKind        :: !Text            -- ^ "jni" (default) | "cpp" (a portable-C++ NativeModule)
  , esHasJava     :: !Bool            -- ^ does the host ship a <Name>Module.java? (False for the
                                      --   model-bytes-only RestoreEngine; True for everything else)
  , esCppSources  :: ![FilePath]      -- ^ basenames under host/shared/cpp to copy into native/cpp
                                      --   (the .cpp/.h pair for a kind=cpp module; [] for pure JNI)
  , esExtraAndroid:: ![FilePath]      -- ^ extra host Java files to copy into native/android beyond
                                      --   <Name>Module.java (e.g. StreamingBridge.java for streamers)
  , esExtraIos    :: ![FilePath]      -- ^ extra host iOS sources to copy into native/ios beyond the
                                      --   Canopy<Name>Module.mm (e.g. CanopyBillingStoreKit2.swift —
                                      --   the StoreKit 2 driver the Billing .mm forwards to, L-I5)
  , esFactory     :: !(Maybe Text)    -- ^ for a kind=cpp module: the C++ factory free-function that
                                      --   returns the module to register (e.g. "globalBillingModule")
  , esFactoryHeader :: !(Maybe Text)  -- ^ for a kind=cpp module with a factory: its header basename
                                      --   the generated registrant #includes (e.g. "BillingModule.h")
  } deriving (Eq, Show)

-- | A simple spec with no permissions and no streaming (the common pure one-shot capability).
plain :: Text -> FilePath -> Bool -> ExtractSpec
plain name dir hasIos = ExtractSpec name dir hasIos [] [] [] "jni" True [] [] [] Nothing Nothing

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
    -- canopy/native core; only the native impl + manifest move into the package). All six of these
    -- ship an iOS twin (the IOS-7 capability-parity set: Canopy<Name>Module.mm under the host's
    -- Modules dir), so esHasIos is True — extraction copies the .mm into the package's native/ios
    -- too, making the capability package-resident on BOTH platforms (AUTO-E-DELETE parity gate).
  , plain "Platform"  "platform"   True
  , plain "Vibration"  "vibration"  True
  , plain "Battery"    "battery"    True
  , plain "DeviceInfo" "device-info" True
  , (plain "NetInfo"   "net-info"   True)
      { esAndroidPerms = [ AndroidPerm "android.permission.ACCESS_NETWORK_STATE" ] }
  , plain "Haptics"    "haptics"    True
  , plain "Brightness" "brightness" True
  ]

-- | The C++/streaming capabilities (plan §5 Phase D tail, AUTO-D-CPP-STREAMING). These were
-- intentionally EXCLUDED from 'pureJniSpecs' because they exercise the C++ and streaming codegen
-- paths (and, for RestoreEngine, the model-bytes-after-boot wiring). Extracting them makes them
-- package-resident exactly like the pure-JNI set, so the generated registrant + CMake fragment
-- autolink them from the dependency graph with zero host edits:
--
--   * @canopy/billing@ — Billing: a bespoke C++ NativeModule (kind=cpp) that owns its own
--     @entitlementChanges@ stream sinks. Ships @native/cpp/BillingModule.{cpp,h}@ + the Java fake
--     store + the iOS StoreKit impl. Its factory @globalBillingModule@ lets the registrant register
--     it with @reg.registerModule(globalBillingModule())@.
--   * @canopy/navigation@ — Lifecycle (appState/memoryPressure/backPressed) + AppShell (colorScheme):
--     streaming JNI modules that ride the GENERIC @StreamingJniModule@ (host substrate, NOT shipped
--     by the package — like a runtime). The package ships only the Java sides + @StreamingBridge.java@
--     (the JNI emit bridge) + the iOS impls. The registrant registers them by name via
--     @globalStreamingModule(name, {channels})@.
--   * @canopy/inference@ — RestoreEngine: an ORT-backed C++ NativeModule (kind=cpp) whose model
--     bytes are handed in AFTER boot (host-specific wiring). It ships @native/cpp/RestoreEngineModule.
--     {cpp,h}@ + the iOS impl, has NO Java side, and NO factory (so the registrant leaves its
--     registration to the host — the comment-only cpp branch). This is the one capability that
--     stays partly host-wired by design.
cppStreamingSpecs :: [ExtractSpec]
cppStreamingSpecs =
  [ -- Billing: a streaming C++ NativeModule with a factory + a Java fake-store delegate.
    (plain "Billing" "billing" True)
      { esKind          = "cpp"
      , esStreaming     = [ "entitlementChanges" ]
      , esHasJava       = True
      , esCppSources    = [ "BillingModule.cpp", "BillingModule.h" ]
      , esFactory       = Just "globalBillingModule"
      , esFactoryHeader = Just "BillingModule.h"
        -- L-I5: the iOS StoreKit 2 driver the Billing .mm forwards to (Product/Transaction are
        -- Swift-only). It ships INSIDE canopy/billing's native/ios alongside CanopyBillingModule.mm,
        -- so the package stays self-contained on iOS (the DoD: adding the dep brings the whole paywall).
      , esExtraIos      = [ "CanopyBillingStoreKit2.swift" ]
      }
    -- Navigation/Lifecycle: a streaming JNI module (generic StreamingJniModule by name). The
    -- generic wrapper is HOST substrate, so the package ships only the Java side + the emit bridge.
  , (plain "Lifecycle" "navigation" True)
      { esStreaming   = [ "appState", "memoryPressure", "backPressed" ]
      , esExtraAndroid = [ "StreamingBridge.java" ]
      }
    -- Navigation/AppShell: the second streaming JNI module in canopy/navigation. StreamingBridge.java
    -- is shared with Lifecycle (copyFile is idempotent), so listing it here is harmless.
  , (plain "AppShell" "navigation" True)
      { esStreaming   = [ "colorScheme" ]
      , esExtraAndroid = [ "StreamingBridge.java" ]
      }
    -- Inference/RestoreEngine: a host-built C++ NativeModule (no factory, no Java) — its model
    -- bytes arrive after boot via the host's setRestoreEngineModel, so registration stays host-side.
  , (plain "RestoreEngine" "inference" True)
      { esKind       = "cpp"
      , esHasJava    = False
      , esCppSources = [ "RestoreEngineModule.cpp", "RestoreEngineModule.h" ]
      }
  ]

-- | Every capability this tool knows how to extract — the pure-JNI set plus the C++/streaming set.
allExtractSpecs :: [ExtractSpec]
allExtractSpecs = pureJniSpecs ++ cppStreamingSpecs

-- | The host Java source file name for a capability, e.g. "HttpModule.java".
androidImplFileName :: ExtractSpec -> FilePath
androidImplFileName es = T.unpack (esModule es) <> "Module.java"

-- | The host iOS source file name for a capability, e.g. "CanopyHttpModule.mm".
iosImplFileName :: ExtractSpec -> FilePath
iosImplFileName es = "Canopy" <> T.unpack (esModule es) <> "Module.mm"

-- | Render the @native.json@ manifest for ALL the modules a package ships — the exact schema
-- 'Canopy.Native.Autolink' parses ('NativeManifest'). Built as text by hand (matching the codebase's
-- codegen style in 'Canopy.Native.Autolink') so the tool keeps a minimal dependency set; the JSON
-- is small and fully determined by the specs, so a hand-emitter is unambiguous and stable.
--
-- Takes a NON-EMPTY list of specs that share a package (e.g. @[Lifecycle, AppShell]@ for
-- @canopy/navigation@) so a multi-module package gets ONE manifest listing every module. The
-- package-level fields (androidSource/iosSource/cppSource/permissions) are the UNION across the
-- specs; the head spec names the package (for the comment). For the common single-module case
-- ('renderNativeJsonOne'), this is just a one-element list.
renderNativeJsonPackage :: [ExtractSpec] -> Text
renderNativeJsonPackage [] = "{}\n"
renderNativeJsonPackage specs@(es0 : _) = T.unlines $
  [ "{" ]
  ++ field "_comment" (jstr comment)
  ++ [ "  \"modules\": [" ]
  ++ commaJoin (map moduleObj specs)
  ++ [ "  ]," ]
  ++ [ "  \"androidSource\": " <> jstr "native/android" <> iosComma ]
  ++ iosLine
  ++ cppLine
  ++ permsLines
  ++ [ "}" ]
  where
    -- One { ... } object per module, kind-aware. A streaming module carries "streaming": [...];
    -- a kind=cpp module carries "kind":"cpp" plus its factory/factoryHeader (when it has one).
    moduleObj es = "    { \"name\": " <> jstr (esModule es)
                     <> streamingField es <> ", \"kind\": " <> jstr (esKind es)
                     <> factoryFields es <> " }"
    streamingField es
      | null (esStreaming es) = ""
      | otherwise = ", \"streaming\": [" <> T.intercalate ", " (map jstr (esStreaming es)) <> "]"
    -- factory/factoryHeader only for a kind=cpp module that ships a registrable factory (Billing).
    factoryFields es = case esFactory es of
      Nothing  -> ""
      Just fac -> ", \"factory\": " <> jstr fac
                    <> maybe "" (\h -> ", \"factoryHeader\": " <> jstr h) (esFactoryHeader es)
    -- Any spec in the package ships an iOS impl? a portable-C++ source? a permission?
    anyIos   = any esHasIos specs
    anyCpp   = any (not . null . esCppSources) specs
    androidPerms = concatMap esAndroidPerms specs
    iosPerms     = concatMap esIosPerms specs
    hasPerms = not (null androidPerms) || not (null iosPerms)
    -- Trailing comma after androidSource iff something follows it (iosSource / cppSource / perms).
    iosComma = if anyIos || anyCpp || hasPerms then "," else ""
    iosLine
      | anyIos    = [ "  \"iosSource\": " <> jstr "native/ios" <> (if anyCpp || hasPerms then "," else "") ]
      | otherwise = []
    -- A kind=cpp package points cppSource at its native/cpp DIR (the CMake/iOS fragments glob it).
    cppLine
      | anyCpp    = [ "  \"cppSource\": " <> jstr "native/cpp" <> (if hasPerms then "," else "") ]
      | otherwise = []
    permsLines
      | not hasPerms = []
      | otherwise =
          [ "  \"permissions\": {" ]
          ++ androidPermLines
          ++ iosPermLines
          ++ [ "  }" ]
    androidPermLines
      | null androidPerms = []
      | otherwise =
          [ "    \"android\": ["
              <> T.intercalate ", " (map (jstr . apName) androidPerms)
              <> "]" <> (if null iosPerms then "" else ",") ]
    iosPermLines
      | null iosPerms = []
      | otherwise =
          [ "    \"ios\": {" ]
          ++ commaJoin [ "      " <> jstr (ipKey p) <> ": " <> jstr (ipDescription p)
                       | p <- iosPerms ]
          ++ [ "    }" ]
    field k v = [ "  " <> jstr k <> ": " <> v <> "," ]
    comment :: Text
    comment =
      "native.json — the canopy-native autolink manifest for canopy/" <> T.pack (esPackageDir es0)
      <> ". GENERATED by `canopy-native extract-modules`. The COMPILER never reads "
      <> "this; only `canopy-native` does. Declaring the module(s) here + shipping native/android "
      <> "(+ native/ios + native/cpp) is all it takes to autolink this capability into an app with NO host edits."

-- | Render the @native.json@ for a SINGLE-module package (the common case; pure-JNI capabilities
-- and the single-module C++ ones). A thin wrapper over 'renderNativeJsonPackage'.
renderNativeJson :: ExtractSpec -> Text
renderNativeJson es = renderNativeJsonPackage [es]

-- | Join lines with a trailing comma on every line but the last (for JSON object/array bodies).
commaJoin :: [Text] -> [Text]
commaJoin []  = []
commaJoin [x] = [x]
commaJoin (x : rest) = (x <> ",") : commaJoin rest

-- | JSON string literal with the minimal escaping native.json values need (quote + backslash).
jstr :: Text -> Text
jstr t = "\"" <> T.replace "\"" "\\\"" (T.replace "\\" "\\\\" t) <> "\""

-- | The outcome of extracting one capability, for a human-readable report.
data ExtractResult = ExtractResult
  { erModule       :: !Text
  , erPackageDir   :: !FilePath
  , erAndroidCopied:: !Bool      -- ^ the host Java impl was found + copied into the package
  , erIosCopied    :: !Bool      -- ^ the host iOS impl was found + copied (only when esHasIos)
  , erCppCopied    :: !Bool      -- ^ the host C++ source(s) were found + copied (only kind=cpp)
  , erManifest     :: !FilePath  -- ^ the written native.json path
  } deriving (Eq, Show)

-- | Extract ONE capability into its package: copy @<Name>Module.java@ (+ any 'esExtraAndroid' files)
-- from the host Android tree into @<pkg>/native/android/@, copy @Canopy<Name>Module.mm@ from the
-- host iOS tree into @<pkg>/native/ios/@ (when it ships one), copy each 'esCppSources' file from the
-- host SHARED C++ tree into @<pkg>/native/cpp/@ (for a kind=cpp module), and write @<pkg>/native.json@.
--
-- @hostAndroidModules@ = the host's @app/src/main/java/com/canopyhost/modules@ dir.
-- @hostIosModules@     = the host's @CanopyHostCore/Modules@ dir.
-- @hostSharedCpp@      = the host's @shared/cpp@ dir (where BillingModule.cpp / RestoreEngineModule.cpp live).
-- @pkgRoot@            = the package's root dir (where @canopy.json@ + the new @native.json@ live).
-- @manifestSpecs@      = ALL the specs that share this package, for the multi-module manifest
--                        (e.g. @[Lifecycle, AppShell]@ for @canopy/navigation@). The manifest is
--                        rendered from THIS list, not just @es@, so the package's native.json lists
--                        every module. For a single-module package it is @[es]@.
--
-- Copying (not moving) keeps the host compiling during Phase D; Phase E (AUTO-E-DELETE) removes the
-- now-duplicate host source. A copy is skipped (and reported) if its host source is absent, so this
-- is idempotent + safe to re-run. The same @StreamingBridge.java@ copied by both Lifecycle and
-- AppShell is harmless (identical bytes, idempotent).
extractModuleInto :: FilePath -> FilePath -> FilePath -> FilePath -> [ExtractSpec] -> ExtractSpec -> IO ExtractResult
extractModuleInto hostAndroidModules hostIosModules hostSharedCpp pkgRoot manifestSpecs es = do
  let androidDir = pkgRoot </> "native" </> "android"
      iosDir     = pkgRoot </> "native" </> "ios"
      cppDir     = pkgRoot </> "native" </> "cpp"
      iosSrc     = hostIosModules </> iosImplFileName es
      iosDst     = iosDir </> iosImplFileName es
      manifest   = pkgRoot </> "native.json"
      -- The Java files to copy: the module's own <Name>Module.java (when it has a Java side) plus
      -- any shared extras (StreamingBridge.java for the streaming JNI modules).
      javaFiles  = [ androidImplFileName es | esHasJava es ] ++ esExtraAndroid es
  createDirectoryIfMissing True androidDir
  -- Android Java side: copy each declared Java file that exists in the host modules dir.
  androidResults <- mapM (copyIfThere hostAndroidModules androidDir) javaFiles
  let androidCopied = and androidResults && not (null androidResults)
  -- iOS side: the Canopy<Name>Module.mm (when the package ships one) PLUS any extra iOS sources
  -- (e.g. CanopyBillingStoreKit2.swift — the StoreKit 2 driver the Billing .mm forwards to, L-I5),
  -- so a package with a Swift companion stays self-contained on iOS.
  iosCopied <-
    if esHasIos es
      then do
        createDirectoryIfMissing True iosDir
        iosThere <- doesFileExist iosSrc
        mmCopied <- if iosThere then copyFile iosSrc iosDst >> pure True else pure False
        extraResults <- mapM (copyIfThere hostIosModules iosDir) (esExtraIos es)
        pure (mmCopied && and extraResults)
      else pure False
  -- Portable C++ side (only for a kind=cpp module): copy each .cpp/.h from host/shared/cpp.
  cppCopied <-
    if null (esCppSources es)
      then pure False
      else do
        createDirectoryIfMissing True cppDir
        rs <- mapM (copyIfThere hostSharedCpp cppDir) (esCppSources es)
        pure (and rs && not (null rs))
  BL.writeFile manifest (BL.fromStrict (TE.encodeUtf8 (renderNativeJsonPackage manifestSpecs)))
  pure ExtractResult
    { erModule        = esModule es
    , erPackageDir    = pkgRoot
    , erAndroidCopied = androidCopied
    , erIosCopied     = iosCopied
    , erCppCopied     = cppCopied
    , erManifest      = manifest
    }
  where
    copyIfThere srcDir dstDir fileName = do
      let src = srcDir </> fileName
      there <- doesFileExist src
      if there then copyFile src (dstDir </> fileName) >> pure True else pure False

-- | Back-compat single-spec extraction (the manifest lists just this module). Kept for the
-- pure-JNI single-module callers + the AUTO-D-JNI tests.
extractModule :: FilePath -> FilePath -> FilePath -> ExtractSpec -> IO ExtractResult
extractModule hostAndroidModules hostIosModules pkgRoot es =
  extractModuleInto hostAndroidModules hostIosModules (takeDirectory hostAndroidModules) pkgRoot [es] es

-- | Group specs that share a package (so a multi-module package — navigation: Lifecycle + AppShell —
-- gets ONE manifest covering both). Preserves first-seen package order.
groupByPackage :: [ExtractSpec] -> [(FilePath, [ExtractSpec])]
groupByPackage = foldr ins [] . reverse
  where
    ins es acc = case lookup (esPackageDir es) acc of
      Just _  -> map (\(d, ss) -> if d == esPackageDir es then (d, ss ++ [es]) else (d, ss)) acc
      Nothing -> acc ++ [(esPackageDir es, [es])]

-- | Extract a list of specs, package-grouped (the manifest each package writes lists ALL its
-- modules). Returns one 'ExtractResult' per spec.
extractSpecs :: FilePath -> FilePath -> [ExtractSpec] -> IO [ExtractResult]
extractSpecs monorepoRoot hostRoot specs =
  fmap concat $ mapM perPackage (groupByPackage specs)
  where
    perPackage (pkgDir, pkgSpecs) =
      let pkgRoot = monorepoRoot </> pkgDir
       in mapM (extractModuleInto hostAndroidModules hostIosModules hostSharedCpp pkgRoot pkgSpecs) pkgSpecs
    hostAndroidModules = hostRoot </> "android" </> "app" </> "src" </> "main"
                           </> "java" </> "com" </> "canopyhost" </> "modules"
    hostIosModules     = hostRoot </> "ios" </> "CanopyHostCore" </> "Modules"
    hostSharedCpp      = hostRoot </> "shared" </> "cpp"

-- | Extract every 'pureJniSpec' into its package under @monorepoRoot@. The host source dirs are
-- the fixed canopy/native locations under @hostRoot@ (= canopy/native/host).
extractAll :: FilePath -> FilePath -> IO [ExtractResult]
extractAll monorepoRoot hostRoot = extractSpecs monorepoRoot hostRoot pureJniSpecs

-- | Extract every 'cppStreamingSpec' (Billing, Lifecycle, AppShell, RestoreEngine) into its package
-- — the AUTO-D-CPP-STREAMING half. Navigation (Lifecycle + AppShell) is package-grouped into one
-- multi-module native.json.
extractAllCppStreaming :: FilePath -> FilePath -> IO [ExtractResult]
extractAllCppStreaming monorepoRoot hostRoot = extractSpecs monorepoRoot hostRoot cppStreamingSpecs
