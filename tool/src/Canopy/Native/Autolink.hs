{-# LANGUAGE OverloadedStrings #-}

-- | Autolinking — the native analogue of the web compiler's FFI inclusion rule
-- ("FFI paths come ONLY from foreign-import statements, never hardcoded";
-- Generate/JavaScript.hs:5-10). A native capability package is self-contained exactly like
-- @canopy/http@ is on web (it ships @external/http.js@): it carries its own native impl under
-- @native/android@ (+ @native/ios@) and DECLARES it via a small @"native"@ block in its
-- @canopy.json@ — the Canopy analogue of @expo-module.config.json@ / @react-native.config.js@.
--
-- This module walks the app's dependency graph, finds every package that declares native
-- modules, and GENERATES the registration glue + build includes — so adding a capability is
-- "add a dependency", with ZERO edits to @canopy/native@ or the host shell:
--
--   * @CanopyGeneratedRegistrant.h@ — the @reg.registerModule(...)@ calls the boot file used to
--     carry by hand (CanopyHostJni.cpp's per-capability block). The host @#if __has_include@s it.
--   * @canopy-autolink.gradle@ — adds each package's @native/android@ to the Gradle source set +
--     its extra Gradle deps, so out-of-tree capability Java/Kotlin compiles into the app.
--
-- The runtime substrate (generic @__canopy_call@ ABI, reflective by-name module lookup, the
-- @CanopyViewRegistry@) already makes this codegen-only: no per-capability runtime code exists.
module Canopy.Native.Autolink
  ( NativeModuleSpec (..)
  , NativeManifest (..)
  , DiscoveredPackage (..)
  , discoverPackages
  , generateAndroidRegistrant
  , generateGradleFragment
  , writeAndroidAutolink
  , hostAndroidFromEnv
  ) where

import           Control.Monad (forM)
import           Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import           Data.List (nub)
import           Data.Maybe (catMaybes)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory, makeAbsolute)
import           System.Environment (lookupEnv)
import           System.FilePath ((</>), takeDirectory)

-- | One native module a package exposes. @nmName@ is the PascalCase capability name the C1 ABI
-- routes on (Android resolves @com.canopyhost.modules.\<name\>Module@; iOS @Canopy\<name\>Module@).
data NativeModuleSpec = NativeModuleSpec
  { nmName      :: !Text     -- ^ e.g. "Ping" -> JniModule("Ping")
  , nmStreaming :: ![Text]   -- ^ method names that emit Subs (-> StreamingJniModule); [] = plain JniModule
  , nmKind      :: !Text     -- ^ "jni" (default; pure Java/Kotlin) | "cpp" (a C++ NativeModule, host-built)
  } deriving (Eq, Show)

instance FromJSON NativeModuleSpec where
  parseJSON = withObject "NativeModuleSpec" $ \o ->
    NativeModuleSpec
      <$> o .:  "name"
      <*> o .:? "streaming" .!= []
      <*> o .:? "kind" .!= "jni"

-- | A package's @native.json@ sidecar — the Canopy analogue of @expo-module.config.json@ /
-- @react-native.config.js@. The COMPILER never reads it (so @canopy.json@ stays untouched and a
-- package needs no compiler change); only @canopy-native@ does. A package with no native side
-- simply omits the file. Every field is optional.
data NativeManifest = NativeManifest
  { manModules     :: ![NativeModuleSpec]
  , manViewTags    :: ![Text]       -- ^ custom host-component tags -> generated CanopyViewRegistry.register
  , manAndroidSrc  :: !(Maybe FilePath)  -- ^ package-relative dir of Android sources, e.g. "native/android"
  , manGradleDeps  :: ![Text]       -- ^ extra Gradle coordinates this capability needs
  } deriving (Eq, Show)

instance FromJSON NativeManifest where
  parseJSON = withObject "NativeManifest" $ \o ->
    NativeManifest
      <$> o .:? "modules" .!= []
      <*> o .:? "viewTags" .!= []
      <*> o .:? "androidSource"
      <*> o .:? "gradleDependencies" .!= []

-- | A package found in the dependency graph that declares native code.
data DiscoveredPackage = DiscoveredPackage
  { dpDir      :: !FilePath        -- ^ absolute package root (holds canopy.json)
  , dpManifest :: !NativeManifest
  } deriving (Eq, Show)

-- Internal: the slice of canopy.json we read purely to DISCOVER candidate package dirs (its
-- source-directories + dependency names). The native manifest itself lives in a sidecar native.json.
data PkgJson = PkgJson
  { pjSourceDirs :: ![FilePath]
  , pjDeps       :: ![Text]
  }

instance FromJSON PkgJson where
  parseJSON = withObject "canopy.json" $ \o -> do
    sds  <- o .:? "source-directories" .!= []
    deps <- maybe [] depNames <$> o .:? "dependencies"
    pure (PkgJson sds deps)

-- | Read a package's @native.json@ sidecar (the manifest), if present.
readManifest :: FilePath -> IO (Maybe NativeManifest)
readManifest path = do
  ok <- doesFileExist path
  if not ok then pure Nothing else decode <$> BL.readFile path

-- | Collect dependency package names from either shape canopy.json uses: a flat
-- @{ "canopy/x": "ver" }@ (packages) or @{ "direct": {...}, "indirect": {...} }@ (apps).
depNames :: Value -> [Text]
depNames (Object o) =
  case KM.lookup "direct" o of
    Just (Object d) -> map K.toText (KM.keys d)
    _               -> filter (T.isPrefixOf "canopy/") (map K.toText (KM.keys o))
depNames _ = []

readPkgJson :: FilePath -> IO (Maybe PkgJson)
readPkgJson path = do
  ok <- doesFileExist path
  if not ok then pure Nothing else decode <$> BL.readFile path

-- | Walk the app's dependency graph and return every dependency that declares a @"native"@ block.
-- Candidates come from two sources, mirroring how the compiler resolves a dependency to a dir:
--   * @source-directories@ entries (e.g. "../../../ping/src" -> the "../../../ping" package), and
--   * @dependencies@ names ("canopy/ping") resolved against the monorepo root (@CANOPY_MONOREPO@,
--     default ~/projects/canopy) — the dev-layout resolution the rest of the toolchain uses.
discoverPackages :: FilePath -> IO [DiscoveredPackage]
discoverPackages appDir = do
  mPj <- readPkgJson (appDir </> "canopy.json")
  case mPj of
    Nothing -> pure []
    Just pj -> do
      monorepo <- resolveMonorepo
      let sdDirs  = [ appDir </> takeDirectory sd | sd <- pjSourceDirs pj ]
          depDirs = [ monorepo </> depToDir d | d <- pjDeps pj ]
      cands <- nub <$> mapM makeAbsolute (sdDirs ++ depDirs)
      found <- forM cands $ \dir -> do
        mm <- readManifest (dir </> "native.json")
        pure $ DiscoveredPackage dir <$> mm
      pure (dedupeByDir (catMaybes found))
  where
    depToDir name = T.unpack (last (T.splitOn "/" name))   -- "canopy/ping" -> "ping"
    dedupeByDir = go []
      where
        go _ [] = []
        go seen (p : rest)
          | dpDir p `elem` seen = go seen rest
          | otherwise           = p : go (dpDir p : seen) rest

resolveMonorepo :: IO FilePath
resolveMonorepo = do
  mEnv <- lookupEnv "CANOPY_MONOREPO"
  case mEnv of
    Just p  -> pure p
    Nothing -> (</> "projects/canopy") <$> getHomeDirectory

-- | The C++ registrant the host @#include@s (guarded by @__has_include@) and calls once. It
-- replaces the hand-maintained per-capability @registerModule@ block in CanopyHostJni.cpp.
generateAndroidRegistrant :: [DiscoveredPackage] -> Text
generateAndroidRegistrant pkgs =
  T.unlines $
    [ "// GENERATED by `canopy-native` autolink — DO NOT EDIT."
    , "// Regenerated each build from the app's dependency graph. The native analogue of the web"
    , "// compiler concatenating every package's external/*.js: here we emit registerModule() calls"
    , "// for every native module a dependency DECLARES in its canopy.json \"native\" block."
    , "#pragma once"
    , "#include \"CanopyModules.h\""
    , "#include \"CanopyJni.h\""
    , "#include \"StreamingJniModule.h\""
    , ""
    , "namespace canopy {"
    , "inline void canopyRegisterGeneratedModules(ModuleRegistry& reg) {"
    ]
    ++ (if null mods then ["  (void)reg;  // no autolinked native modules in this app"] else map line mods)
    ++ [ "}"
       , "}  // namespace canopy"
       ]
  where
    mods = concatMap (manModules . dpManifest) pkgs
    line m
      | not (null (nmStreaming m)) =
          "  reg.registerModule(globalStreamingModule(" <> q (nmName m) <> ", {"
            <> T.intercalate ", " (map q (nmStreaming m)) <> "}));"
      | nmKind m == "cpp" =
          "  // \"" <> nmName m <> "\" is a C++ NativeModule (kind=cpp); its factory is host-built (not autolinked yet)."
      | otherwise =
          "  reg.registerModule(std::make_shared<JniModule>(" <> q (nmName m) <> "));"
    q t = "\"" <> t <> "\""

-- | The Gradle fragment the app's build.gradle conditionally @apply from@s: it folds each
-- package's out-of-tree @native/android@ into the app source set + adds its extra Gradle deps,
-- so capability Java/Kotlin that lives in the PACKAGE (not the host) compiles into the app.
generateGradleFragment :: [DiscoveredPackage] -> Text
generateGradleFragment pkgs =
  T.unlines $
    [ "// GENERATED by `canopy-native` autolink — regenerated each build. Do not commit."
    , "// Folds each dependency package's own native/android sources into the app, mirroring"
    , "// React Native autolinking / Expo Modules — the package carries its native impl."
    , "android {"
    , "    sourceSets {"
    , "        main {"
    ]
    ++ [ "            java.srcDirs += " <> gstr src | src <- srcDirs ]
    ++ [ "        }"
       , "    }"
       , "}"
       , "dependencies {"
       ]
    ++ [ "    implementation " <> gstr (T.unpack dep) | dep <- gradleDeps ]
    ++ [ "}" ]
  where
    srcDirs    = [ dpDir p </> s | p <- pkgs, Just s <- [manAndroidSrc (dpManifest p)] ]
    gradleDeps = concatMap (manGradleDeps . dpManifest) pkgs
    gstr s     = "'" <> T.pack s <> "'"

-- | Write the registrant + Gradle fragment into the host Android project tree.
writeAndroidAutolink :: FilePath -> [DiscoveredPackage] -> IO ()
writeAndroidAutolink hostAndroid pkgs = do
  let genDir       = hostAndroid </> "app" </> "src" </> "main" </> "jni" </> "generated"
      registrant   = genDir </> "CanopyGeneratedRegistrant.h"
      fragment     = hostAndroid </> "canopy-autolink.gradle"
  createDirectoryIfMissing True genDir
  -- Make srcDirs absolute so Gradle resolves them regardless of its working directory.
  absPkgs <- mapM (\p -> (\d -> p { dpDir = d }) <$> makeAbsolute (dpDir p)) pkgs
  TIO.writeFile registrant (generateAndroidRegistrant absPkgs)
  TIO.writeFile fragment   (generateGradleFragment absPkgs)

-- | Resolve the host Android project dir for autolink output: @CANOPY_HOST_ANDROID@ if set, else
-- derived from @CANOPY_HOST_ASSETS@ (…/app/src/main/assets -> …/android). 'Nothing' if neither.
hostAndroidFromEnv :: IO (Maybe FilePath)
hostAndroidFromEnv = do
  mAndroid <- lookupEnv "CANOPY_HOST_ANDROID"
  case mAndroid of
    Just p  -> pure (Just p)
    Nothing -> do
      mAssets <- lookupEnv "CANOPY_HOST_ASSETS"
      pure $ fmap (up 4) mAssets   -- assets -> main -> src -> app -> android
  where
    up n = foldr (.) id (replicate n takeDirectory)
