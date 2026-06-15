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
  , ViewTagSpec (..)
  , IosPermission (..)
  , NativeManifest (..)
  , DiscoveredPackage (..)
  , discoverPackages
  , generateAndroidRegistrant
  , generateAndroidViewRegistrant
  , generateGradleFragment
  , generateIosRegistrant
  , generateIosProjectFragment
  , generateIosPodfileFragment
  , generateIosInfoPlistFragment
  , writeAndroidAutolink
  , writeIosAutolink
  , hostAndroidFromEnv
  , hostIosFromEnv
  ) where

import           Control.Monad (forM)
import           Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import           Data.List (nub, sortOn)
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

-- | One custom host-component tag a package exposes, plus the Java factory that constructs its
-- native @android.view.View@. The tag mounts through 'CanopyHost.makeView's DEFAULT case once
-- 'CanopyViewRegistry.register' is called for it (CanopyHost.java:302) — so the only missing seam
-- is the boot-time @register(tag, factory)@ call, which this codegen emits.
--
-- @vtAndroidFactory@ is a fully-qualified Java class implementing @CanopyComponentFactory@
-- (e.g. "com.acme.blur.BlurViewFactory"); it lives in the PACKAGE, never the host (plan §6:
-- zero host edits for a new capability). An empty factory means the tag was declared without one
-- (emits a TODO comment, not a register call).
data ViewTagSpec = ViewTagSpec
  { vtTag            :: !Text   -- ^ the custom Fabric tag, e.g. "BlurView"
  , vtAndroidFactory :: !Text   -- ^ FQCN of the CanopyComponentFactory, or "" if none declared
  } deriving (Eq, Show)

-- | Accepts BOTH shapes for ergonomics/back-compat: a bare string @"BlurView"@ (tag only — no
-- factory, emits a TODO) OR an object @{"tag": "BlurView", "androidFactory": "com.acme.X"}@.
instance FromJSON ViewTagSpec where
  parseJSON (String s) = pure (ViewTagSpec s "")
  parseJSON v          = flip (withObject "ViewTagSpec") v $ \o ->
    ViewTagSpec
      <$> o .:  "tag"
      <*> o .:? "androidFactory" .!= ""

-- | One iOS @Info.plist@ permission/usage entry a package needs: the Info.plist KEY (e.g.
-- @NSPhotoLibraryUsageDescription@) paired with the human-readable usage STRING shown in the
-- system permission prompt. These autolink into the host app's Info.plist the same way an
-- Android @uses-permission@ travels with the package — the iOS analogue of the plan's
-- "permissions travel with the package" rule (§4.1 / DoD #5). The compiler never reads them;
-- the package's @native.json@ declares them and @canopy-native@ merges them at build time.
data IosPermission = IosPermission
  { ipKey         :: !Text   -- ^ Info.plist key, e.g. "NSPhotoLibraryUsageDescription"
  , ipDescription :: !Text   -- ^ the usage-description string shown in the permission prompt
  } deriving (Eq, Show)

-- | A package's @native.json@ sidecar — the Canopy analogue of @expo-module.config.json@ /
-- @react-native.config.js@. The COMPILER never reads it (so @canopy.json@ stays untouched and a
-- package needs no compiler change); only @canopy-native@ does. A package with no native side
-- simply omits the file. Every field is optional.
data NativeManifest = NativeManifest
  { manModules     :: ![NativeModuleSpec]
  , manViewTags    :: ![ViewTagSpec]  -- ^ custom host-component tags -> generated CanopyViewRegistry.register
  , manAndroidSrc  :: !(Maybe FilePath)  -- ^ package-relative dir of Android sources, e.g. "native/android"
  , manGradleDeps  :: ![Text]       -- ^ extra Gradle coordinates this capability needs
  , manIosSrc      :: !(Maybe FilePath)  -- ^ package-relative dir of iOS (.swift/.mm) sources, e.g. "native/ios"
  , manCppSrc      :: !(Maybe FilePath)  -- ^ package-relative dir of portable C++ sources, e.g. "native/cpp"
  , manPodDeps     :: ![Text]       -- ^ extra CocoaPods this capability needs (raw `pod '...'` line bodies)
  , manIosPerms    :: ![IosPermission]  -- ^ Info.plist usage-description keys this capability needs
  } deriving (Eq, Show)

instance FromJSON NativeManifest where
  parseJSON = withObject "NativeManifest" $ \o -> do
    mods   <- o .:? "modules" .!= []
    views  <- o .:? "viewTags" .!= []
    asrc   <- o .:? "androidSource"
    gdeps  <- o .:? "gradleDependencies" .!= []
    isrc   <- o .:? "iosSource"
    csrc   <- o .:? "cppSource"
    pdeps  <- o .:? "podDependencies" .!= []
    -- Permissions are nested under "permissions": { "ios": { "<Key>": "<desc>" } } so the same
    -- block can later carry "android" too (mirrors plan §4.3's permissions schema). The iOS map
    -- is key->description; we flatten it (sorted by key) into [IosPermission] for stable output.
    perms  <- o .:? "permissions"
    let iosPerms = case perms of
          Just (Object p) -> case KM.lookup "ios" p of
            Just (Object iosMap) ->
              sortOn ipKey
                [ IosPermission (K.toText k) desc
                | (k, String desc) <- KM.toList iosMap ]
            _ -> []
          _ -> []
    pure (NativeManifest mods views asrc gdeps isrc csrc pdeps iosPerms)

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

-- | The Java view-tag registrant the host calls once at boot (MainActivity). It emits a
-- @CanopyViewRegistry.register(tag, factory)@ call for every @viewTags@ entry across every
-- discovered package — the Java analogue of 'generateAndroidRegistrant' (which handles C1-ABI
-- modules in C++). Android view registration CANNOT be done from the C++ registrant: a factory
-- must construct an @android.view.View@, which is package-shipped Java (CanopyComponentFactory).
--
-- Each factory is instantiated reflectively (Class.forName) inside a try/catch so a missing or
-- renamed factory class LOGS instead of crashing boot — mirroring the iOS "not-yet-landed module
-- logs info, not error" tolerance (plan §4.5). Tags are deduped (last wins, matching
-- CanopyViewRegistry.register's idempotency, CanopyViewRegistry.java:24).
generateAndroidViewRegistrant :: [DiscoveredPackage] -> Text
generateAndroidViewRegistrant pkgs =
  T.unlines $
    [ "// GENERATED by `canopy-native` autolink — DO NOT EDIT."
    , "// Regenerated each build from the app's dependency graph. Calls CanopyViewRegistry.register()"
    , "// once per custom view tag a dependency DECLARES in its native.json \"viewTags\" block, so the"
    , "// tag mounts through CanopyHost.makeView's default case with ZERO host edits."
    , "package com.canopyhost.generated;"
    , ""
    , "import android.content.Context;"
    , "import com.canopyhost.CanopyViewRegistry;"
    , ""
    , "public final class CanopyGeneratedViews {"
    , "  /** Register every autolinked package's custom view tags. Called once at boot. */"
    , "  public static void registerAll(Context ctx) {"
    ]
    ++ (if null tags then ["    // no autolinked view tags"] else map line tags)
    ++ [ "  }"
       , "  private CanopyGeneratedViews() {}"
       , "}"
       ]
  where
    -- Dedupe by tag, last declaration wins (matches register() idempotency). We reverse, keep the
    -- first occurrence per tag, then reverse back to preserve source order of the kept entries.
    tags = dedupeByTag (concatMap (manViewTags . dpManifest) pkgs)
    dedupeByTag = reverse . go [] . reverse
      where
        go _ [] = []
        go seen (v : rest)
          | vtTag v `elem` seen = go seen rest
          | otherwise           = v : go (vtTag v : seen) rest
    line v
      | T.null (vtAndroidFactory v) =
          "    // TODO: " <> vtTag v <> " declared no androidFactory — no register() emitted."
      | otherwise =
          "    try { CanopyViewRegistry.register(" <> q (vtTag v)
            <> ", (com.canopyhost.CanopyComponentFactory) Class.forName(" <> q (vtAndroidFactory v)
            <> ").getDeclaredConstructor().newInstance()); }"
            <> " catch (Throwable t) { android.util.Log.i(\"CanopyAutolink\", \"view "
            <> vtTag v <> " factory " <> vtAndroidFactory v <> " not available: \" + t); }"
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

-- | The iOS registrant the host @#import@s (guarded by @__has_include@) and iterates once. It is
-- the iOS analogue of 'generateAndroidRegistrant': instead of emitting C++ @registerModule@ calls,
-- it emits an ObjC @caps[]@ array of @{name, streaming}@ dictionaries — the EXACT shape the
-- hand-maintained NSArray in CanopyModuleHost.mm:175-187 has — consumed by the existing
-- @registerAll@ loop (CanopyModuleHost.mm:189-204), which routes every entry through the one
-- by-name bridge call @+registerModuleNamed:…streamingMethods:@.
--
-- KEY DIFFERENCE from Android: iOS routes plain AND streaming modules through that single by-name
-- call (there is no JniModule vs StreamingJniModule split), so the generator emits only @(name,
-- streaming)@ pairs. A @kind=cpp@ module on iOS is a weak-linked C++ NativeModule (e.g.
-- RestoreEngine), registered directly — never by name — so it is left OUT of @caps[]@ (it gets a
-- comment-only line, exactly as Android's @generateAndroidRegistrant@ does for its cpp branch).
--
-- @streaming@ is @[NSNull null]@ for a plain capability and @\@[ \@"m1", \@"m2" ]@ for a streaming
-- one (the registerAll loop treats a non-array — i.e. NSNull — as @nil@ streaming).
generateIosRegistrant :: [DiscoveredPackage] -> Text
generateIosRegistrant pkgs =
  T.unlines $
    [ "// GENERATED by `canopy-native` autolink — DO NOT EDIT."
    , "// Regenerated each build from the app's dependency graph. The iOS analogue of the web"
    , "// compiler concatenating every package's external/*.js: here we emit the (name, streaming)"
    , "// caps[] entries for every native module a dependency DECLARES in its native.json \"modules\"."
    , "// Consumed by CanopyModuleHost.mm -registerAll, which routes each through the by-name bridge"
    , "// (+registerModuleNamed:…streamingMethods:) — the same path the hardcoded caps[] uses."
    , "#pragma once"
    , "#import <Foundation/Foundation.h>"
    , ""
    , "static inline NSArray<NSDictionary *> *CanopyGeneratedCaps(void) {"
    ]
    ++ (if null capLines
          then [ "  return @[];  // no autolinked native modules in this app" ]
          else [ "  return @[" ] ++ capLines ++ [ "  ];" ])
    ++ [ "}" ]
  where
    mods     = concatMap (manModules . dpManifest) pkgs
    -- Lines for the @[ ... ] body: skip cpp modules (emit a comment only, no array element).
    capLines = concatMap line mods
    line m
      | nmKind m == "cpp" =
          [ "    // \"" <> nmName m <> "\" is a C++ NativeModule (kind=cpp); weak-linked on iOS, not name-registered." ]
      | not (null (nmStreaming m)) =
          [ "    @{ @\"name\": " <> q (nmName m) <> ", @\"streaming\": @[ "
              <> T.intercalate ", " (map q (nmStreaming m)) <> " ] }," ]
      | otherwise =
          [ "    @{ @\"name\": " <> q (nmName m) <> ", @\"streaming\": [NSNull null] }," ]
    q t = "@\"" <> t <> "\""

-- | The XcodeGen fragment the host @project.yml@ @include:@s — the iOS analogue of
-- 'generateGradleFragment' and the direct mirror of React Native's @use_native_modules!@: it
-- folds each dependency package's own out-of-tree @native/ios@ (Swift/ObjC++) and optional
-- @native/cpp@ (portable C++) sources INTO the @CanopyHostCore@ static library target, so a
-- capability's native impl that lives in the PACKAGE compiles into the app with ZERO host edits.
--
-- XcodeGen merges a fragment listed under the project's top-level @include:@ key (a "project
-- spec template"); a fragment that re-declares a target with only a @sources:@ list is MERGED
-- into the existing target (XcodeGen unions target sources), so we add sources without
-- redefining the whole @CanopyHostCore@ target. Paths are emitted ABSOLUTE so XcodeGen resolves
-- them regardless of where the host @project.yml@ sits relative to the package.
--
-- C++ sources are added BY REFERENCE under a @CanopySharedCpp@ group exactly as the host adds
-- its own @../shared/cpp/*.cpp@ (project.yml:113-124) — this closes the plan's "C++ capabilities
-- cost a second iOS edit to project.yml" gap (§2 / §4.4a). Swift/ObjC++ are added as a directory
-- @path:@ so every file under @native/ios@ is picked up (XcodeGen globs a directory source).
generateIosProjectFragment :: [DiscoveredPackage] -> Text
generateIosProjectFragment pkgs =
  T.unlines $
    [ "# GENERATED by `canopy-native` autolink — DO NOT EDIT. Regenerated each build."
    , "# Included by the host project.yml via `include:`. The iOS analogue of React Native's"
    , "# use_native_modules! — folds each dependency package's native/ios (+ native/cpp) sources"
    , "# into the CanopyHostCore static library so out-of-tree capability code compiles in."
    , "targets:"
    , "  CanopyHostCore:"
    , "    sources:"
    ]
    ++ (if null sourceLines
          then [ "      []  # no autolinked iOS native sources in this app" ]
          else sourceLines)
  where
    -- One Swift/ObjC++ directory source per package that ships native/ios, then each native/cpp
    -- file by reference (grouped like the host's own SharedCpp). Directory sources let XcodeGen
    -- glob the whole native/ios dir; cpp must be per-file so the group/buildable mirrors the host.
    sourceLines = concatMap iosDir pkgs ++ concatMap cppRefs pkgs
    iosDir p = case manIosSrc (dpManifest p) of
      Nothing  -> []
      Just src -> [ "      - path: " <> ystr (dpDir p </> src)
                  , "        group: CanopyAutolinkIos" ]
    cppRefs p = case manCppSrc (dpManifest p) of
      Nothing  -> []
      Just src -> [ "      - path: " <> ystr (dpDir p </> src)
                  , "        group: CanopySharedCpp" ]
    -- YAML-quote a path (always quote: paths may contain spaces or leading special chars).
    ystr s = "\"" <> T.replace "\"" "\\\"" (T.pack s) <> "\""

-- | The Podfile include the host @Podfile@ @eval_podfile@s (or the dev pastes inside the
-- abstract target): one @pod '...'@ line per @podDependencies@ entry a capability declares. It
-- is the iOS counterpart of 'generateGradleFragment's @dependencies { implementation ... }@
-- block — extra CocoaPods a native capability needs (e.g. an SDK pod), autolinked from the dep
-- graph so the host @Podfile@ never grows a per-capability line. Pods are deduped (a pod pulled
-- by two packages links once — DoD #5's path-keyed-dedup analogue, here keyed by the pod line).
generateIosPodfileFragment :: [DiscoveredPackage] -> Text
generateIosPodfileFragment pkgs =
  T.unlines $
    [ "# GENERATED by `canopy-native` autolink — DO NOT EDIT. Regenerated each build."
    , "# Included by the host Podfile inside the CanopyShared abstract target via:"
    , "#   eval_podfile File.join(__dir__, 'Podfile.canopy-autolink')   # or paste these lines"
    , "# The iOS analogue of the generated Gradle `dependencies {}` block: extra CocoaPods a"
    , "# native capability declares in its native.json \"podDependencies\", autolinked from the graph."
    ]
    ++ (if null pods then [ "# no autolinked pod dependencies in this app" ] else map line pods)
  where
    pods    = nub (concatMap (manPodDeps . dpManifest) pkgs)
    line pd = "pod " <> pd

-- | The @Info.plist@ permission fragment the host merges into @CanopyHostApp/Info.plist@ (its
-- @<dict>@ body) — one @<key>…</key><string>…</string>@ pair per iOS permission a capability
-- declares. This is the iOS analogue of the package-shipped Android @uses-permission@ entries
-- and the direct fulfillment of the plan's "permissions travel with the package" rule (§4.1, DoD
-- #5): a @canopy/photos@ dependency makes @NSPhotoLibraryUsageDescription@ appear in the built
-- app's Info.plist with no host edit.
--
-- The output is a plist FRAGMENT (the inner key/value pairs, NOT a full @<plist>@ document) so it
-- drops straight into the host's existing @<dict>@. Keys are deduped across packages (first
-- declaration wins — a usage string two packages both need appears once). Description strings are
-- XML-escaped so a description with @&@/@<@ stays valid plist XML.
generateIosInfoPlistFragment :: [DiscoveredPackage] -> Text
generateIosInfoPlistFragment pkgs =
  T.unlines $
    [ "<!-- GENERATED by `canopy-native` autolink — DO NOT EDIT. Regenerated each build. -->"
    , "<!-- Merge these key/value pairs into the CanopyHostApp Info.plist dict. The iOS analogue"
    , "     of package-shipped Android uses-permission entries: each capability's required usage"
    , "     strings autolink from the dependency graph (native.json \"permissions\".\"ios\"). -->"
    ]
    ++ (if null perms
          then [ "<!-- no autolinked iOS permissions in this app -->" ]
          else concatMap line perms)
  where
    -- Dedupe by Info.plist key, FIRST declaration wins (one usage string per key in the plist).
    perms = dedupeByKey (concatMap (manIosPerms . dpManifest) pkgs)
    dedupeByKey = go []
      where
        go _ [] = []
        go seen (p : rest)
          | ipKey p `elem` seen = go seen rest
          | otherwise           = p : go (ipKey p : seen) rest
    line p =
      [ "<key>" <> xmlEscape (ipKey p) <> "</key>"
      , "<string>" <> xmlEscape (ipDescription p) <> "</string>" ]

-- | Minimal XML-text escaping for plist string values (the five predefined XML entities). Order
-- matters: @&@ must be replaced first so the @&@ it introduces in the others is not re-escaped.
xmlEscape :: Text -> Text
xmlEscape =
    T.replace "\"" "&quot;"
  . T.replace "'"  "&apos;"
  . T.replace ">"  "&gt;"
  . T.replace "<"  "&lt;"
  . T.replace "&"  "&amp;"

-- | Write the registrant + Gradle fragment + Java view registrant into the host Android tree.
writeAndroidAutolink :: FilePath -> [DiscoveredPackage] -> IO ()
writeAndroidAutolink hostAndroid pkgs = do
  let genDir       = hostAndroid </> "app" </> "src" </> "main" </> "jni" </> "generated"
      registrant   = genDir </> "CanopyGeneratedRegistrant.h"
      fragment     = hostAndroid </> "canopy-autolink.gradle"
      javaGenDir   = hostAndroid </> "app" </> "src" </> "main" </> "java"
                       </> "com" </> "canopyhost" </> "generated"
      viewRegFile  = javaGenDir </> "CanopyGeneratedViews.java"
  createDirectoryIfMissing True genDir
  createDirectoryIfMissing True javaGenDir
  -- Make srcDirs absolute so Gradle resolves them regardless of its working directory.
  absPkgs <- mapM (\p -> (\d -> p { dpDir = d }) <$> makeAbsolute (dpDir p)) pkgs
  TIO.writeFile registrant  (generateAndroidRegistrant absPkgs)
  TIO.writeFile fragment    (generateGradleFragment absPkgs)
  TIO.writeFile viewRegFile (generateAndroidViewRegistrant absPkgs)

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

-- | Write the iOS autolink artifacts into the host iOS tree, mirroring 'writeAndroidAutolink':
--
--   * @CanopyHostCore/Boot/generated/CanopyGeneratedCapsIOS.h@ — the registrant header the boot
--     file @#if __has_include@s (AUTO-B-REG-IOS); SIBLING to CanopyModuleHost.mm so the relative
--     @#import "generated/CanopyGeneratedCapsIOS.h"@ resolves exactly like Android's registrant.
--   * @canopy-autolink.project.yml@ — the XcodeGen fragment the host @project.yml@ @include:@s,
--     folding each package's @native/ios@ + @native/cpp@ sources into @CanopyHostCore@.
--   * @Podfile.canopy-autolink@ — the Podfile include carrying each package's extra CocoaPods.
--   * @CanopyAutolink.Info.plist.fragment@ — the Info.plist permission key/value pairs to merge.
--
-- The CapsIOS header's @CanopyGeneratedCaps()@ routes by CLASS NAME (no paths), so it needs no
-- 'makeAbsolute'. The project.yml fragment DOES carry paths (out-of-tree native source dirs), so —
-- exactly like 'writeAndroidAutolink' — we make each package dir absolute first, so XcodeGen
-- resolves them regardless of the host project.yml's location.
writeIosAutolink :: FilePath -> [DiscoveredPackage] -> IO ()
writeIosAutolink hostIos pkgs = do
  let genDir       = hostIos </> "CanopyHostCore" </> "Boot" </> "generated"
      registrant   = genDir </> "CanopyGeneratedCapsIOS.h"
      projFragment = hostIos </> "canopy-autolink.project.yml"
      podFragment  = hostIos </> "Podfile.canopy-autolink"
      plistFrag    = hostIos </> "CanopyAutolink.Info.plist.fragment"
  createDirectoryIfMissing True genDir
  -- Make package dirs absolute so the project.yml fragment's source paths resolve independent of
  -- where the host project.yml sits (mirrors writeAndroidAutolink's Gradle srcDirs handling).
  absPkgs <- mapM (\p -> (\d -> p { dpDir = d }) <$> makeAbsolute (dpDir p)) pkgs
  TIO.writeFile registrant   (generateIosRegistrant absPkgs)
  TIO.writeFile projFragment (generateIosProjectFragment absPkgs)
  TIO.writeFile podFragment  (generateIosPodfileFragment absPkgs)
  TIO.writeFile plistFrag    (generateIosInfoPlistFragment absPkgs)

-- | Resolve the host iOS project dir for autolink output: @CANOPY_HOST_IOS@ if set, else 'Nothing'.
-- Unlike Android (which can derive its tree from @CANOPY_HOST_ASSETS@ via a stable @app/src/main/
-- assets@ -> @android@ relation), iOS has no fixed assets->ios path, so this gates purely on the
-- explicit @CANOPY_HOST_IOS@ var. A no-op host means 'runAutolink' simply skips the iOS writer.
hostIosFromEnv :: IO (Maybe FilePath)
hostIosFromEnv = lookupEnv "CANOPY_HOST_IOS"
