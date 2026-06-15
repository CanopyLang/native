-- | Dependency-free assertions over the pure cores: codegen, bundle assembly, config
-- round-trip, and the component model. Exits non-zero on the first failure so `stack
-- test` is a real gate.
module Main (main) where

import           Canopy.Native.Assets (AssetEntry (..), AssetManifest (..), BytecodeInfo (..), renderManifest)
import           Canopy.Native.Autolink
import           Canopy.Native.Build (archiveReleaseMap, compileHbc, findHermesc)
import           Canopy.Native.Bundle
import           Canopy.Native.Codegen
import           Canopy.Native.Component
import           Canopy.Native.Config
import           Canopy.Native.DevClient
import           Canopy.Native.Vendor
import           Control.Monad (unless)
import           Data.Aeson (decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.IORef
import           Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable, getCurrentDirectory, getTemporaryDirectory)
import           System.Exit (ExitCode (..), exitFailure)
import           System.FilePath ((</>))
import           System.Process (readCreateProcessWithExitCode, proc)

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let ok name cond = do
        putStrLn (("  " <> tick cond <> " ") <> name)
        unless cond (modifyIORef' failures (+ 1))
      tick True = "\x2713"; tick False = "\x2717 FAIL:"
      -- Count non-overlapping occurrences of `needle` in `hay` (used to assert dedup -> 1 line).
      countInfix needle = go
        where go [] = 0
              go hay@(_ : rest)
                | needle `isPrefixOf` hay = 1 + go (drop (length needle) hay)
                | otherwise               = go rest

  putStrLn "component model"
  ok "default set has the six wedge components"
     (length defaultComponents == 6)
  ok "RCTView is present and maps to the View fabric component"
     (maybe False ((== "View") . compFabricName) (lookupComponent "RCTView" defaultComponents))
  ok "fontSize is a float-coerced style on RCTText"
     (("RCTText", "fontSize") `elem` floatStyleKeys defaultComponents)
  ok "press is modelled as an event prop"
     (any ((== PropEvent) . propKind) (concatMap compProps defaultComponents))

  putStrLn "\ncodegen — JSON manifest"
  let json = BLC.unpack (renderManifestJSON defaultComponents)
  ok "manifest mentions every component tag"
     (all (`isInfixOf` json) ["RCTView", "RCTText", "RCTScrollView", "RCTImageView", "RCTSinglelineTextInputView", "RCTRawText"])
  ok "manifest records the float kind"  ("float" `isInfixOf` json)
  ok "manifest records the event kind"  ("event" `isInfixOf` json)
  ok "manifest carries platform classes" ("RCTViewComponentView" `isInfixOf` json)

  putStrLn "\ncodegen — C++ header"
  let cpp = T.unpack (renderCppHeader defaultComponents)
  ok "header guards with pragma once"          ("#pragma once" `isInfixOf` cpp)
  ok "header exposes canopyValidTags()"        ("canopyValidTags" `isInfixOf` cpp)
  ok "header exposes canopyFloatProps()"       ("canopyFloatProps" `isInfixOf` cpp)
  ok "float set uses tag|prop keys"            ("RCTText|fontSize" `isInfixOf` cpp)
  ok "every component tag is in the valid set" (all (`isInfixOf` cpp) (map (T.unpack . compCanopyTag) defaultComponents))

  putStrLn "\ncodegen — TypeScript"
  let ts = T.unpack (renderTypeScript defaultComponents)
  ok "exports the component record"  ("canopyComponents" `isInfixOf` ts)
  ok "declares the prop-kind union"  ("CanopyPropKind" `isInfixOf` ts)

  putStrLn "\nbundle assembly"
  let bundle = T.unpack (assembleBundle (BundleInputs "/*PROGRAM*/globalThis.Elm={Main:{init:function(){}}};" "Main"))
  ok "includes the Hermes preamble"        ("Hermes host preamble" `isInfixOf` bundle)
  ok "shims setTimeout for the scheduler"  ("setTimeout" `isInfixOf` bundle)
  ok "inlines the compiled program"        ("/*PROGRAM*/" `isInfixOf` bundle)
  ok "exposes the __canopy_boot hook"      ("__canopy_boot" `isInfixOf` bundle)
  ok "boot targets the named main module"  ("elm.Main.init" `isInfixOf` bundle)

  putStrLn "\nsource-map alignment (DX M0)"
  -- The compiled program begins this many lines into the bundle; every V3 mapping shifts
  -- past them. Golden value — if the preamble grows, re-verify against a fresh build.
  ok "compiled program starts at the golden preamble offset"
     (compiledLineOffset == 45)
  ok "shiftSourceMap is a no-op at offset 0"
     (shiftSourceMap 0 "{\"version\":3,\"mappings\":\"AAAA\"}" == "{\"version\":3,\"mappings\":\"AAAA\"}")
  ok "shiftSourceMap prepends one ';' per preamble line"
     (shiftSourceMap 3 "{\"mappings\":\"AAAA;CC\"}" == "{\"mappings\":\";;;AAAA;CC\"}")
  ok "shiftSourceMap retitles the file field to the bundle"
     ("\"file\":\"canopy.bundle.js\"" `isInfixOf` T.unpack (shiftSourceMap 1 "{\"file\":\"canopy.js\",\"mappings\":\"AAAA\"}"))
  ok "shiftSourceMap aligns a map with no mappings field unchanged except file"
     (shiftSourceMap 5 "{\"version\":3,\"sources\":[]}" == "{\"version\":3,\"sources\":[]}")
  ok "stripSourceMapRef drops the compiler's sourceMappingURL trailer"
     (not ("sourceMappingURL" `isInfixOf` T.unpack (stripSourceMapRef "code();\n//# sourceMappingURL=app.iife.js.map\n")))
  ok "stripSourceMapRef keeps the real code"
     ("code();" `isInfixOf` T.unpack (stripSourceMapRef "code();\n//# sourceMappingURL=app.iife.js.map\n"))

  putStrLn "\nrelease map archival (AND-10)"
  -- archiveReleaseMap writes the preamble-aligned map under a buildId-keyed name
  -- (canopy.<bundle-sha256>.map) and returns its AssetEntry so the manifest records it.
  -- Build a throwaway bundle + aligned map under the system temp dir.
  amTmp <- getTemporaryDirectory
  let amOut    = amTmp </> "canopy-and10-test"
      amBundle = amOut </> "canopy.bundle.js"
      amMapTxt = T.pack "{\"version\":3,\"file\":\"canopy.bundle.js\",\"sources\":[\"Main.can\"],\"mappings\":\";;AAAA\"}"
  createDirectoryIfMissing True amOut
  -- A deterministic bundle => a deterministic buildId (sha256). Precomputed below.
  BS.writeFile amBundle (BS.pack (map (fromIntegral . fromEnum) "AND10-BUNDLE-BYTES"))
  -- dev build (Nothing): no map archived, returns Nothing.
  devEntry <- archiveReleaseMap amOut amBundle Nothing
  ok "a dev build (no archive map) records no archived-map entry"
     (devEntry == Nothing)
  -- release build (Just map): writes canopy.<buildId>.map + returns its entry.
  relEntry <- archiveReleaseMap amOut amBundle (Just amMapTxt)
  ok "a release build returns an archived-map AssetEntry"
     (relEntry /= Nothing)
  case relEntry of
    Nothing -> ok "archiveReleaseMap returned an entry" False
    Just e  -> do
      ok "the archived map is named by the bundle's content address (canopy.<buildId>.map)"
         (T.isPrefixOf "canopy." (aeName e) && T.isSuffixOf ".map" (aeName e)
            && T.length (aeName e) == T.length "canopy." + 64 + T.length ".map")
      ok "the archived map's sha256 is recorded in its entry"
         (T.length (aeSha e) == 64)
      written <- doesFileExist (amOut </> T.unpack (aeName e))
      ok "the archived map file is actually written to disk under that buildId name"
         written
      -- The archived map bytes are exactly the aligned map text we passed in.
      archived <- BS.readFile (amOut </> T.unpack (aeName e))
      ok "the archived map content is the aligned map text verbatim"
         (archived == TE.encodeUtf8 amMapTxt)

  putStrLn "\nHermes .hbc bytecode (RNV-7)"
  -- The HBC header is a fixed layout: 8-byte LE magic 0x1F1903C103BC1FC6, then a LE uint32 version.
  -- Craft a minimal header and assert the pure parsers read the magic + version correctly. These
  -- are the SAME bytes (same offsets) the C++ load gate (CanopyAbiGate.h) re-reads, so a passing
  -- parser here pins the wire format both readers share.
  ok "the magic constant is the on-disk Hermes bytecode magic"
     (hermesBytecodeMagic == 0x1F1903C103BC1FC6)
  let magicLE   = BS.pack [0xC6, 0x1F, 0xBC, 0x03, 0xC1, 0x03, 0x19, 0x1F]   -- 0x1F1903C103BC1FC6 LE
      hbcV96    = magicLE <> BS.pack [96, 0, 0, 0] <> BS.replicate 20 0       -- version 96 (LE u32)
      hbcV94    = magicLE <> BS.pack [94, 0, 0, 0] <> BS.replicate 20 0       -- a mismatched version
      plainJs   = BS.pack (map (fromIntegral . fromEnum) "(function(){})();")
  ok "isHermesBytecode recognizes a real HBC header"     (isHermesBytecode hbcV96)
  ok "isHermesBytecode rejects plain JS source"          (not (isHermesBytecode plainJs))
  ok "isHermesBytecode rejects bytes shorter than the magic"
     (not (isHermesBytecode (BS.take 4 magicLE)))
  ok "hbcBytecodeVersion reads the version stamped at offset 8"
     (hbcBytecodeVersion hbcV96 == Just 96)
  ok "hbcBytecodeVersion reads a different stamped version"
     (hbcBytecodeVersion hbcV94 == Just 94)
  ok "hbcBytecodeVersion is Nothing for plain JS (no HBC magic)"
     (hbcBytecodeVersion plainJs == Nothing)
  ok "hbcBytecodeVersion is Nothing for a truncated header (magic but no version)"
     (hbcBytecodeVersion magicLE == Nothing)

  -- The manifest serializes a `bytecode` block only when an .hbc was emitted (else it is absent).
  let bcInfo   = BytecodeInfo (AssetEntry "canopy.bundle.hbc" "deadbeef" 1234) 96
      manWith  = BLC.unpack (renderManifest
                   (AssetManifest (AssetEntry "canopy.bundle.js" "abc" 10) [] "1" "abc" (Just bcInfo)))
      manNone  = BLC.unpack (renderManifest
                   (AssetManifest (AssetEntry "canopy.bundle.js" "abc" 10) [] "1" "abc" Nothing))
  ok "manifest with an .hbc carries a bytecode block with the version + sha"
     (all (`isInfixOf` manWith) ["\"bytecode\"", "\"version\":96", "canopy.bundle.hbc", "deadbeef"])
  ok "manifest without an .hbc omits the bytecode block (JS-only build)"
     (not ("\"bytecode\"" `isInfixOf` manNone))

  -- End-to-end: when a hermesc is locatable (CANOPY_HERMESC / PATH / CANOPY_RN_ROOT), compileHbc
  -- ACTUALLY compiles a tiny JS bundle to real bytecode and reports a parseable version that equals
  -- the version stamped in the produced file. Skipped (not failed) if no hermesc is on this box.
  mHermesc <- findHermesc
  case mHermesc of
    Nothing -> putStrLn "  (skipped end-to-end hermesc compile: no hermesc found — set CANOPY_HERMESC)"
    Just hc -> do
      putStrLn ("  (using hermesc: " <> hc <> ")")
      hbcTmp <- getTemporaryDirectory
      let hbcDir = hbcTmp </> "canopy-rnv7-test"
          jsIn   = hbcDir </> "tiny.bundle.js"
          hbcOut = hbcDir </> "tiny.bundle.hbc"
      createDirectoryIfMissing True hbcDir
      BS.writeFile jsIn (BS.pack (map (fromIntegral . fromEnum) "var x = 1 + 2;\n"))
      mBc <- compileHbc jsIn hbcOut
      case mBc of
        Nothing -> ok "compileHbc emitted a BytecodeInfo for a valid JS bundle" False
        Just bc -> do
          ok "compileHbc emitted a .hbc file on disk" =<< doesFileExist hbcOut
          producedBytes <- BS.readFile hbcOut
          ok "the produced .hbc carries the Hermes bytecode magic"
             (isHermesBytecode producedBytes)
          ok "compileHbc's reported version equals the version stamped in the produced .hbc"
             (Just (biVersion bc) == hbcBytecodeVersion producedBytes)
          ok "the .hbc entry is named by the output file's basename with a 64-hex sha256"
             (aeName (biEntry bc) == "tiny.bundle.hbc" && T.length (aeSha (biEntry bc)) == 64)
          ok "the emitted bytecode version is a sensible Hermes HBC version (>= 90)"
             (biVersion bc >= 90)

  putStrLn "\nconfig round-trip"
  let cfg = defaultConfig "Counter" "org.canopy.counter"
  case decodeConfig (encodeConfig cfg) of
    Right back -> do
      ok "config survives encode/decode" (back == cfg)
      ok "default main module is Main"   (ncMainModule back == "Main")
    Left err -> ok ("config decode failed: " <> err) False

  putStrLn "\nautolink — Android view-tag registrant"
  let mkPkg ts = DiscoveredPackage "/pkg" (NativeManifest [] ts Nothing [] Nothing Nothing [] [])
      blurPkg  = mkPkg [ViewTagSpec "BlurView" "com.acme.BlurFactory"]
      blurJava = T.unpack (generateAndroidViewRegistrant [blurPkg])
  ok "registers the declared tag"
     ("CanopyViewRegistry.register(\"BlurView\"" `isInfixOf` blurJava)
  ok "reflects the declared factory FQCN"
     ("com.acme.BlurFactory" `isInfixOf` blurJava)
  ok "guards factory instantiation in try/catch"
     (("Class.forName" `isInfixOf` blurJava) && ("catch (Throwable" `isInfixOf` blurJava))
  ok "emits a package + class + import that compile against the host"
     (all (`isInfixOf` blurJava)
        [ "package com.canopyhost.generated;"
        , "class CanopyGeneratedViews"
        , "import com.canopyhost.CanopyViewRegistry;"
        , "registerAll(Context" ])

  let emptyJava = T.unpack (generateAndroidViewRegistrant [])
  ok "no view tags -> compilable empty registerAll, no register call"
     (("registerAll" `isInfixOf` emptyJava)
        && ("// no autolinked view tags" `isInfixOf` emptyJava)
        && not ("CanopyViewRegistry.register(\"" `isInfixOf` emptyJava))

  let dupA    = mkPkg [ViewTagSpec "Shared" "com.a.Factory"]
      dupB    = mkPkg [ViewTagSpec "Shared" "com.b.Factory"]
      dupJava = T.unpack (generateAndroidViewRegistrant [dupA, dupB])
  ok "two packages declaring the same tag dedupe to one register line"
     (countInfix "CanopyViewRegistry.register(\"Shared\"" dupJava == 1)
  ok "dedup keeps the last declaration (last wins)"
     (("com.b.Factory" `isInfixOf` dupJava) && not ("com.a.Factory" `isInfixOf` dupJava))

  let noFactoryJava = T.unpack (generateAndroidViewRegistrant [mkPkg [ViewTagSpec "Bare" ""]])
  ok "a tag with no factory emits a TODO comment, not a register call"
     (("// TODO: Bare" `isInfixOf` noFactoryJava)
        && not ("CanopyViewRegistry.register(\"" `isInfixOf` noFactoryJava))

  ok "viewTags FromJSON accepts a bare string"
     (decode "[\"Foo\"]" == Just [ViewTagSpec "Foo" ""])
  ok "viewTags FromJSON accepts an object with androidFactory"
     (decode "[{\"tag\":\"Foo\",\"androidFactory\":\"x.Y\"}]" == Just [ViewTagSpec "Foo" "x.Y"])

  putStrLn "\nautolink — iOS caps[] registrant"
  -- Build DiscoveredPackage fixtures in-test (no filesystem). NativeModuleSpec = (name, streaming, kind).
  let mkModPkg ms = DiscoveredPackage "/pkg" (NativeManifest ms [] Nothing [] Nothing Nothing [] [])
      pingPkg     = mkModPkg [NativeModuleSpec "Ping" [] "jni"]
      pingIos     = T.unpack (generateIosRegistrant [pingPkg])
  ok "plain module emits a [NSNull null] streaming caps entry"
     ("@{ @\"name\": @\"Ping\", @\"streaming\": [NSNull null] }," `isInfixOf` pingIos)

  let streamPkg = mkModPkg [NativeModuleSpec "Foo" ["barChanges"] "jni"]
      streamIos = T.unpack (generateIosRegistrant [streamPkg])
  ok "single-method streaming module emits an @[ @\"m\" ] streaming array"
     ("@{ @\"name\": @\"Foo\", @\"streaming\": @[ @\"barChanges\" ] }," `isInfixOf` streamIos)

  let multiPkg = mkModPkg [NativeModuleSpec "Bar" ["a", "b"] "jni"]
      multiIos = T.unpack (generateIosRegistrant [multiPkg])
  ok "multi-method streaming module comma-joins the channel names"
     ("@\"streaming\": @[ @\"a\", @\"b\" ]" `isInfixOf` multiIos)

  let cppPkg = mkModPkg [NativeModuleSpec "RestoreEngine" [] "cpp"]
      cppIos = T.unpack (generateIosRegistrant [cppPkg])
  ok "kind=cpp module is NOT name-registered (no caps[] array element)"
     (not ("@{ @\"name\": @\"RestoreEngine\"" `isInfixOf` cppIos))
  ok "kind=cpp module is documented as a weak-linked C++ NativeModule comment"
     (("// \"RestoreEngine\"" `isInfixOf` cppIos) && ("kind=cpp" `isInfixOf` cppIos))

  let emptyIos = T.unpack (generateIosRegistrant [])
  ok "no modules -> a valid empty caps[] (return @[];), no dangling element"
     (("return @[];" `isInfixOf` emptyIos) && not ("@{ @\"name\"" `isInfixOf` emptyIos))

  ok "header is self-contained: pragma once + Foundation + the generator + GENERATED banner"
     (all (`isInfixOf` pingIos)
        [ "#pragma once"
        , "#import <Foundation/Foundation.h>"
        , "static inline NSArray<NSDictionary *> *CanopyGeneratedCaps(void)"
        , "GENERATED by `canopy-native` autolink" ])

  -- Mixed package: plain + streaming + cpp in one manifest -> both real caps present, cpp skipped.
  let mixedPkg = mkModPkg
        [ NativeModuleSpec "Ping" [] "jni"
        , NativeModuleSpec "Foo" ["barChanges"] "jni"
        , NativeModuleSpec "RestoreEngine" [] "cpp" ]
      mixedIos = T.unpack (generateIosRegistrant [mixedPkg])
  ok "mixed manifest emits plain + streaming caps but omits the cpp module"
     (("@{ @\"name\": @\"Ping\"" `isInfixOf` mixedIos)
        && ("@{ @\"name\": @\"Foo\"" `isInfixOf` mixedIos)
        && not ("@{ @\"name\": @\"RestoreEngine\"" `isInfixOf` mixedIos))

  putStrLn "\nautolink — iOS build includes (AUTO-C-IOS: project.yml + Podfile + Info.plist)"

  -- Full-manifest fixture: a package shipping iOS sources + C++ + a pod + a permission.
  -- NativeManifest = (modules, viewTags, androidSrc, gradleDeps, iosSrc, cppSrc, podDeps, iosPerms)
  let photosMan = NativeManifest
        [NativeModuleSpec "Photos" [] "jni"] [] Nothing []
        (Just "native/ios") Nothing []
        [IosPermission "NSPhotoLibraryUsageDescription" "Access photos to restore."]
      photosPkg = DiscoveredPackage "/deps/photos" photosMan

  -- (a) XcodeGen project.yml fragment — folds native/ios into CanopyHostCore.
  let projYml = T.unpack (generateIosProjectFragment [photosPkg])
  ok "project fragment is a GENERATED do-not-edit XcodeGen include"
     (("GENERATED by `canopy-native` autolink" `isInfixOf` projYml)
        && ("DO NOT EDIT" `isInfixOf` projYml))
  ok "project fragment merges into the CanopyHostCore target's sources"
     (("targets:" `isInfixOf` projYml)
        && ("CanopyHostCore:" `isInfixOf` projYml)
        && ("sources:" `isInfixOf` projYml))
  ok "project fragment adds the package's native/ios dir as a source path"
     ("- path: \"/deps/photos/native/ios\"" `isInfixOf` projYml)
  ok "project fragment groups iOS sources under CanopyAutolinkIos"
     ("group: CanopyAutolinkIos" `isInfixOf` projYml)
  ok "a package with no native/ios contributes no source path"
     (let p = T.unpack (generateIosProjectFragment [pingPkg])
       in not ("- path:" `isInfixOf` p) && ("[]" `isInfixOf` p))

  -- C++ capability: native/cpp is added BY REFERENCE under the SharedCpp group (closes the
  -- "C++ costs a second project.yml edit" gap), exactly like the host's own ../shared/cpp/*.cpp.
  let cppMan = NativeManifest
        [NativeModuleSpec "Restore" [] "cpp"] [] Nothing []
        (Just "native/ios") (Just "native/cpp/Restore.cpp") [] []
      cppPkg2  = DiscoveredPackage "/deps/restore" cppMan
      cppProj  = T.unpack (generateIosProjectFragment [cppPkg2])
  ok "a cpp capability adds its native/cpp source by reference"
     ("- path: \"/deps/restore/native/cpp/Restore.cpp\"" `isInfixOf` cppProj)
  ok "the cpp source is grouped under CanopySharedCpp (mirrors the host's ../shared/cpp refs)"
     ("group: CanopySharedCpp" `isInfixOf` cppProj)

  let emptyProj = T.unpack (generateIosProjectFragment [])
  ok "no native sources -> a valid empty XcodeGen sources list (no dangling entry)"
     (("[]" `isInfixOf` emptyProj) && not ("- path:" `isInfixOf` emptyProj))

  -- (b) Podfile fragment — extra CocoaPods autolinked from the graph.
  let podMan = NativeManifest
        [] [] Nothing [] (Just "native/ios") Nothing
        ["'SomeSDK', '~> 2.0'"] []
      podPkg  = DiscoveredPackage "/deps/sdk" podMan
      podFrag = T.unpack (generateIosPodfileFragment [podPkg])
  ok "Podfile fragment emits a pod line for each declared pod dependency"
     ("pod 'SomeSDK', '~> 2.0'" `isInfixOf` podFrag)
  ok "Podfile fragment documents how the host Podfile includes it"
     ("eval_podfile" `isInfixOf` podFrag)

  -- Two packages declaring the SAME pod link once (DoD #5 path-keyed dedup analogue).
  let podDupA   = DiscoveredPackage "/a" (NativeManifest [] [] Nothing [] Nothing Nothing ["'Shared', '1.0'"] [])
      podDupB   = DiscoveredPackage "/b" (NativeManifest [] [] Nothing [] Nothing Nothing ["'Shared', '1.0'"] [])
      podDupOut = T.unpack (generateIosPodfileFragment [podDupA, podDupB])
  ok "the same pod declared by two packages dedupes to one pod line"
     (countInfix "pod 'Shared', '1.0'" podDupOut == 1)

  let emptyPod = T.unpack (generateIosPodfileFragment [])
  ok "no pod dependencies -> a comment, no pod lines"
     (("no autolinked pod dependencies" `isInfixOf` emptyPod)
        && not ("\npod " `isInfixOf` ("\n" <> emptyPod)))

  -- (c) Info.plist permission fragment — usage strings travel with the package (DoD #5).
  let plistFrag = T.unpack (generateIosInfoPlistFragment [photosPkg])
  ok "Info.plist fragment emits the declared permission key"
     ("<key>NSPhotoLibraryUsageDescription</key>" `isInfixOf` plistFrag)
  ok "Info.plist fragment emits the paired usage-description string"
     ("<string>Access photos to restore.</string>" `isInfixOf` plistFrag)

  -- XML escaping: a description with & and < stays valid plist XML.
  let escMan   = NativeManifest [] [] Nothing [] Nothing Nothing []
                   [IosPermission "NSCameraUsageDescription" "Scan & crop <photos>"]
      escPkg   = DiscoveredPackage "/c" escMan
      escPlist = T.unpack (generateIosInfoPlistFragment [escPkg])
  ok "Info.plist usage strings are XML-escaped (& -> &amp;, < -> &lt;)"
     (("Scan &amp; crop &lt;photos&gt;" `isInfixOf` escPlist)
        && not ("Scan & crop <photos>" `isInfixOf` escPlist))

  -- Same Info.plist key declared by two packages collapses to one entry (first wins).
  let permDupA   = DiscoveredPackage "/a" (NativeManifest [] [] Nothing [] Nothing Nothing []
                     [IosPermission "NSPhotoLibraryUsageDescription" "first"])
      permDupB   = DiscoveredPackage "/b" (NativeManifest [] [] Nothing [] Nothing Nothing []
                     [IosPermission "NSPhotoLibraryUsageDescription" "second"])
      permDupOut = T.unpack (generateIosInfoPlistFragment [permDupA, permDupB])
  ok "the same Info.plist key from two packages dedupes to one entry"
     (countInfix "<key>NSPhotoLibraryUsageDescription</key>" permDupOut == 1)
  ok "Info.plist key dedup keeps the first declaration (first wins)"
     (("<string>first</string>" `isInfixOf` permDupOut)
        && not ("<string>second</string>" `isInfixOf` permDupOut))

  let emptyPlist = T.unpack (generateIosInfoPlistFragment [])
  ok "no permissions -> a comment, no <key> entries"
     (("no autolinked iOS permissions" `isInfixOf` emptyPlist)
        && not ("<key>" `isInfixOf` emptyPlist))
  ok "Info.plist fragment is a plist <dict> body, NOT a full <plist> document (mergeable)"
     (not ("<plist" `isInfixOf` plistFrag) && not ("<dict>" `isInfixOf` plistFrag))

  -- FromJSON: the native.json shape parses iosSource / cppSource / podDependencies / permissions.ios.
  let manJson = "{\"modules\":[{\"name\":\"Photos\"}],\"iosSource\":\"native/ios\","
                  <> "\"cppSource\":\"native/cpp/X.cpp\",\"podDependencies\":[\"'P', '1.0'\"],"
                  <> "\"permissions\":{\"ios\":{\"NSCameraUsageDescription\":\"cam\"}}}"
  case (decode manJson :: Maybe NativeManifest) of
    Nothing  -> ok "native.json FromJSON parses the iOS manifest block" False
    Just man -> do
      ok "native.json FromJSON reads iosSource"
         (manIosSrc man == Just "native/ios")
      ok "native.json FromJSON reads cppSource"
         (manCppSrc man == Just "native/cpp/X.cpp")
      ok "native.json FromJSON reads podDependencies"
         (manPodDeps man == ["'P', '1.0'"])
      ok "native.json FromJSON reads permissions.ios into [IosPermission]"
         (manIosPerms man == [IosPermission "NSCameraUsageDescription" "cam"])

  -- End-to-end: the iOS writer drops all four artifacts under a host iOS tree.
  iosTmp <- getTemporaryDirectory
  let iosHost = iosTmp </> "canopy-auto-c-ios-test"
  writeIosAutolink iosHost [photosPkg, podPkg]
  let capsPath  = iosHost </> "CanopyHostCore" </> "Boot" </> "generated" </> "CanopyGeneratedCapsIOS.h"
      projPath  = iosHost </> "canopy-autolink.project.yml"
      podPath   = iosHost </> "Podfile.canopy-autolink"
      plistPath = iosHost </> "CanopyAutolink.Info.plist.fragment"
  capsW  <- doesFileExist capsPath
  projW  <- doesFileExist projPath
  podW   <- doesFileExist podPath
  plistW <- doesFileExist plistPath
  ok "writeIosAutolink writes the registrant header under Boot/generated/"  capsW
  ok "writeIosAutolink writes the XcodeGen project fragment"                projW
  ok "writeIosAutolink writes the Podfile fragment"                         podW
  ok "writeIosAutolink writes the Info.plist permission fragment"          plistW

  putStrLn "\nvendor lock — generate / verify / corrupt-byte (RNV-1)"
  -- Build a throwaway repo root under the system temp: one binary artifact + one header tree.
  -- generateLock/verifyLock resolve every relPath under this root, so nothing touches the repo.
  sysTmp <- getTemporaryDirectory
  let root    = sysTmp </> "canopy-vendor-test"
      binRel   = "host/android/vendor/lib/x86_64/libfbjni.so"   -- mirrors a real relPath shape
      treeRel  = "host/shared/third_party/jsi/jsi"
      binAbs   = root </> binRel
      treeAbs  = root </> treeRel
      specs    = [ ArtifactSpec (T.pack binRel)  KindBinary "test" "0.0.0" "2026-06-15"
                 , ArtifactSpec (T.pack treeRel) KindTree   "test" "0.0.0" "2026-06-15"
                 ]
  createDirectoryIfMissing True (root </> "host/android/vendor/lib/x86_64")
  createDirectoryIfMissing True treeAbs
  createDirectoryIfMissing True (treeAbs </> "sub")
  BS.writeFile binAbs (BS.pack [0,1,2,3,4,5,6,7,8,9])
  BS.writeFile (treeAbs </> "a.h") (BS.pack [10,20,30])
  BS.writeFile (treeAbs </> "sub" </> "b.h") (BS.pack [40,50,60])

  lock0 <- generateLock root "FIXED-STAMP" specs
  ok "generated lock covers both fixture artifacts"
     (length (lfEntries lock0) == 2)
  ok "binary entry records a sha256 + size"
     (any (\e -> leRelPath e == T.pack binRel
                 && maybe False (not . T.null) (leSha e)
                 && leSize e == Just 10) (lfEntries lock0))
  ok "tree entry records an order-independent digest"
     (any (\e -> leRelPath e == T.pack treeRel
                 && maybe False (not . T.null) (leSha e)) (lfEntries lock0))

  clean <- verifyLock root lock0
  ok "verify of an untouched fixture returns NO mismatches"
     (null clean)

  -- Corrupt exactly one byte of the binary and assert verify FAILS LOUD: names the file,
  -- reports a sha256 drift with expected != actual.
  BS.writeFile binAbs (BS.pack [0,1,2,3,99,5,6,7,8,9])   -- flipped byte at index 4
  drifted <- verifyLock root lock0
  let binMm = filter ((== T.pack binRel) . mmRelPath) drifted
  ok "one flipped byte makes verify return a non-empty mismatch list"
     (not (null drifted))
  ok "the mismatch names the corrupted file"
     (not (null binMm))
  ok "the mismatch reports a sha256 drift with expected != actual"
     (case binMm of
        (m : _) -> "sha256" `isInfixOf` T.unpack (mmReason m)
                   && mmExpected m /= mmActual m
                   && not (T.null (mmActual m))
        []      -> False)

  -- A flipped byte inside the header TREE must also be caught (order-independent digest).
  BS.writeFile (treeAbs </> "sub" </> "b.h") (BS.pack [40,50,61])
  treeDrift <- verifyLock root lock0
  ok "corrupting a file inside a header tree also fails loud"
     (any ((== T.pack treeRel) . mmRelPath) treeDrift)

  -- Missing file is a loud mismatch too.
  let missingSpecs = [ ArtifactSpec "host/does-not-exist.so" KindBinary "t" "0" "2026-06-15" ]
  missLock <- generateLock root "FIXED-STAMP" missingSpecs
  ok "generateLock skips an artifact that is absent on disk"
     (null (lfEntries missLock))

  -- Determinism: two generates with the SAME stamp produce byte-identical JSON
  -- (restore the tree first so the digest is stable across the two runs).
  BS.writeFile (treeAbs </> "sub" </> "b.h") (BS.pack [40,50,60])
  lockA <- generateLock root "STAMP-A" specs
  lockB <- generateLock root "STAMP-A" specs
  ok "two generates with the same stamp are byte-identical (tree digest is order-independent)"
     (renderLock lockA == renderLock lockB)

  -- LockFile encode/decode round-trip (mirrors the config round-trip test).
  case decodeLock (renderLock lock0) of
    Right back -> ok "LockFile survives encode/decode" (back == lock0)
    Left err   -> ok ("LockFile decode failed: " <> err) False

  -- DEV-6 — the tool-side dev-client glue (`canopy-native run`): the PURE decision layer (what
  -- host the on-device client dials, whether to adb-reverse, and the exact ordered command plan).
  -- No device/adb/node touched — these pin the orchestration contract the IO driver executes.
  putStrLn "\ndev-client glue — canopy-native run plan (DEV-6)"
  do
    -- arg parsing
    ok "parseRunOptions defaults to '.' app dir + port 8099, server on"
       (case parseRunOptions [] of
          Right o -> roAppDir o == "." && roPort o == 8099 && roLanHost o == Nothing && not (roNoServer o)
          Left _  -> False)
    ok "parseRunOptions reads APP_DIR + --port + --host + --no-server"
       (case parseRunOptions ["examples/lumen", "--port", "9001", "--host", "192.168.1.20", "--no-server"] of
          Right o -> roAppDir o == "examples/lumen" && roPort o == 9001
                       && roLanHost o == Just "192.168.1.20" && roNoServer o
          Left _  -> False)
    ok "parseRunOptions rejects a bad --port"
       (case parseRunOptions ["--port", "0"] of Left _ -> True; Right _ -> False)
    ok "parseRunOptions rejects an unknown flag"
       (case parseRunOptions ["--nope"] of Left _ -> True; Right _ -> False)

    -- devClientHost: emulator/USB (adb-reverse loopback) vs LAN (DEV-7)
    let dhDefault = devClientHost (defaultRunOptions ".")
    ok "default (no --host) → adb-reverse, client dials 10.0.2.2, server binds loopback"
       (dhAdbReverse dhDefault && dhHostPort dhDefault == "10.0.2.2:8099" && dhServerBind dhDefault == "127.0.0.1")
    let dhLan = devClientHost (defaultRunOptions ".") { roLanHost = Just "192.168.1.20", roPort = 8099 }
    ok "--host IP (DEV-7) → no adb-reverse, client dials the LAN IP, server binds 0.0.0.0"
       (not (dhAdbReverse dhLan) && dhHostPort dhLan == "192.168.1.20:8099" && dhServerBind dhLan == "0.0.0.0")

    -- runPlan: the ordered command list
    let optsLoop = defaultRunOptions "examples/lumen"
        planLoop = runPlan optsLoop (devClientHost optsLoop)
                     "host/android/gradlew" "org.canopy.echo" "com.canopyhost.MainActivity"
                     "tool/canopy-dev-server.js"
        progs = map stepProg planLoop
    ok "the default plan is build → installDebug → adb reverse → setprop → launch → dev server"
       (progs == ["canopy-native", "host/android/gradlew", "adb", "adb", "adb", "node"])
    ok "installDebug targets the android project dir via -p"
       (any (\s -> stepProg s == "host/android/gradlew" && stepArgs s == ["-p", "host/android", "installDebug"]) planLoop)
    ok "the setprop step bakes debug.canopy.devhost = the resolved host:port"
       (any (\s -> stepArgs s == ["shell", "setprop", "debug.canopy.devhost", "10.0.2.2:8099"]) planLoop)
    ok "the dev-server step passes the app dir + --port"
       (any (\s -> stepProg s == "node"
                    && ["tool/canopy-dev-server.js", "examples/lumen", "--port", "8099"] `isPrefixOf` stepArgs s) planLoop)

    -- LAN plan: no adb-reverse step, server bound to 0.0.0.0
    let optsLan = (defaultRunOptions "examples/lumen") { roLanHost = Just "192.168.1.20" }
        planLan = runPlan optsLan (devClientHost optsLan)
                    "host/android/gradlew" "org.canopy.echo" "com.canopyhost.MainActivity"
                    "tool/canopy-dev-server.js"
    ok "a --host LAN plan OMITS the adb reverse step"
       (not (any (\s -> case stepArgs s of ("reverse" : _) -> True; _ -> False) planLan))
    ok "a --host LAN plan binds the dev server to 0.0.0.0"
       (any (\s -> stepProg s == "node" && "0.0.0.0" `elem` stepArgs s) planLan)

    -- --no-server omits the long-running server step
    let optsNoSrv = (defaultRunOptions ".") { roNoServer = True }
        planNoSrv = runPlan optsNoSrv (devClientHost optsNoSrv)
                      "host/android/gradlew" "org.canopy.echo" "com.canopyhost.MainActivity"
                      "tool/canopy-dev-server.js"
    ok "--no-server omits the dev-server (node) step"
       (not (any ((== "node") . stepProg) planNoSrv))

  -- DEV-5 — the dev server (watcher + incremental rebuild + WS push) is JS (node v22 built-ins
  -- only; no chokidar/ws). Run its headless harness as part of `stack test` so the tool's single
  -- test gate covers the dev loop too. Skipped (not failed) if node is unavailable.
  putStrLn "\ndev server — watcher + rebuild + WS push (DEV-5, tool/test/dev-server.test.js)"
  mNode <- findExecutable "node"
  case mNode of
    Nothing -> putStrLn "  (skipped: node not on PATH)"
    Just _  -> do
      testJs <- resolveDevServerTest
      (ec, sout, serr) <- readCreateProcessWithExitCode (proc "node" [testJs]) ""
      case ec of
        ExitSuccess   -> ok "node tool/test/dev-server.test.js — all assertions pass" True
        ExitFailure c -> do
          putStrLn sout
          putStrLn serr
          ok ("node dev-server.test.js failed (exit " <> show c <> ")") False

  n <- readIORef failures
  putStrLn ""
  if n == 0
    then putStrLn "ALL PASS"
    else putStrLn (show n <> " FAILED") >> exitFailure

-- | Locate tool/test/dev-server.test.js relative to wherever @stack test@ is invoked from.
-- @stack test@ runs with the cwd at the package root (tool/), but a user might run the binary
-- from the repo root; cover both by probing the two conventional spots.
resolveDevServerTest :: IO FilePath
resolveDevServerTest = do
  cwd <- getCurrentDirectory
  let candidates =
        [ cwd </> "test" </> "dev-server.test.js"               -- cwd == tool/
        , cwd </> "tool" </> "test" </> "dev-server.test.js"    -- cwd == repo root
        ]
  firstExisting candidates
  where
    firstExisting [] = pure "test/dev-server.test.js"  -- last resort; node will error loudly
    firstExisting (p : rest) = do
      e <- doesFileExist p
      if e then pure p else firstExisting rest
