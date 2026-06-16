-- | Dependency-free assertions over the pure cores: codegen, bundle assembly, config
-- round-trip, and the component model. Exits non-zero on the first failure so `stack
-- test` is a real gate.
module Main (main) where

import           Canopy.Native.Assets (AssetEntry (..), AssetManifest (..), BytecodeInfo (..), renderManifest)
import           Canopy.Native.Autolink
import           Canopy.Native.Build (archiveReleaseMap, compileHbc, findHermesc)
import           Canopy.Native.Bundle
import           Canopy.Native.CapabilityCodegen
import           Canopy.Native.Codegen
import           Canopy.Native.Component
import           Canopy.Native.Config
import           Canopy.Native.DevClient
import           Canopy.Native.Extract
import           Canopy.Native.Vendor
import           Control.Monad (unless)
import           Data.Aeson (decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
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
  -- dev build (False): no map archived, returns Nothing.
  devEntry <- archiveReleaseMap amOut amBundle False
  ok "a dev build (no archive map) records no archived-map entry"
     (devEntry == Nothing)
  -- release build (True): reads the compiler-emitted <bundle>.map sibling, copies it to
  -- canopy.<buildId>.map + returns its entry.
  BS.writeFile (amBundle <> ".map") (TE.encodeUtf8 amMapTxt)
  relEntry <- archiveReleaseMap amOut amBundle True
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
  let mkPkg ts = DiscoveredPackage "/pkg" (NativeManifest [] ts Nothing [] Nothing Nothing [] [] [])
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
  -- Build DiscoveredPackage fixtures in-test (no filesystem). `nm3 name streaming kind` is the
  -- pre-AUTO-D-CPP-STREAMING 3-field shape (no cpp factory); cpp-factory cases use NativeModuleSpec
  -- directly. NativeManifest = (modules, viewTags, androidSrc, gradleDeps, iosSrc, cppSrc, podDeps,
  -- iosPerms, androidPerms).
  let nm3 n s k = NativeModuleSpec n s k Nothing Nothing
      mkModPkg ms = DiscoveredPackage "/pkg" (NativeManifest ms [] Nothing [] Nothing Nothing [] [] [])
      pingPkg     = mkModPkg [nm3 "Ping" [] "jni"]
      pingIos     = T.unpack (generateIosRegistrant [pingPkg])
  ok "plain module emits a [NSNull null] streaming caps entry"
     ("@{ @\"name\": @\"Ping\", @\"streaming\": [NSNull null] }," `isInfixOf` pingIos)

  let streamPkg = mkModPkg [nm3 "Foo" ["barChanges"] "jni"]
      streamIos = T.unpack (generateIosRegistrant [streamPkg])
  ok "single-method streaming module emits an @[ @\"m\" ] streaming array"
     ("@{ @\"name\": @\"Foo\", @\"streaming\": @[ @\"barChanges\" ] }," `isInfixOf` streamIos)

  let multiPkg = mkModPkg [nm3 "Bar" ["a", "b"] "jni"]
      multiIos = T.unpack (generateIosRegistrant [multiPkg])
  ok "multi-method streaming module comma-joins the channel names"
     ("@\"streaming\": @[ @\"a\", @\"b\" ]" `isInfixOf` multiIos)

  let cppPkg = mkModPkg [nm3 "RestoreEngine" [] "cpp"]
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
        [ nm3 "Ping" [] "jni"
        , nm3 "Foo" ["barChanges"] "jni"
        , nm3 "RestoreEngine" [] "cpp" ]
      mixedIos = T.unpack (generateIosRegistrant [mixedPkg])
  ok "mixed manifest emits plain + streaming caps but omits the cpp module"
     (("@{ @\"name\": @\"Ping\"" `isInfixOf` mixedIos)
        && ("@{ @\"name\": @\"Foo\"" `isInfixOf` mixedIos)
        && not ("@{ @\"name\": @\"RestoreEngine\"" `isInfixOf` mixedIos))

  putStrLn "\nautolink — Android C++ + streaming registrant (AUTO-D-CPP-STREAMING)"
  -- A plain JNI module registers via std::make_shared<JniModule>.
  let andPing = T.unpack (generateAndroidRegistrant [pingPkg])
  ok "a plain JNI module registers as std::make_shared<JniModule>(\"Ping\")"
     ("reg.registerModule(std::make_shared<JniModule>(\"Ping\"));" `isInfixOf` andPing)

  -- A streaming JNI module (Lifecycle/AppShell) rides the generic StreamingJniModule by name.
  let andStream = T.unpack (generateAndroidRegistrant
                    [mkModPkg [nm3 "Lifecycle" ["appState", "backPressed"] "jni"]])
  ok "a streaming JNI module registers via globalStreamingModule(name, {channels})"
     ("reg.registerModule(globalStreamingModule(\"Lifecycle\", {\"appState\", \"backPressed\"}));"
        `isInfixOf` andStream)

  -- A C++ module WITH a factory (Billing) registers by CALLING its factory free-function, and the
  -- registrant #includes the declaring header so the call type-checks.
  let billingMod = NativeModuleSpec "Billing" ["entitlementChanges"] "cpp"
                     (Just "globalBillingModule") (Just "BillingModule.h")
      andBilling = T.unpack (generateAndroidRegistrant [mkModPkg [billingMod]])
  ok "a cpp module with a factory registers via reg.registerModule(<factory>())"
     ("reg.registerModule(globalBillingModule());" `isInfixOf` andBilling)
  ok "the registrant #includes the cpp factory module's header"
     ("#include \"BillingModule.h\"" `isInfixOf` andBilling)
  ok "a cpp-with-factory module does NOT also emit a JniModule/streaming registration"
     (not ("JniModule>(\"Billing\")" `isInfixOf` andBilling)
        && not ("globalStreamingModule(\"Billing\"" `isInfixOf` andBilling))

  -- A C++ module with NO factory (RestoreEngine) is host-built: comment only, no register call,
  -- no spurious #include.
  let restoreMod = NativeModuleSpec "RestoreEngine" [] "cpp" Nothing Nothing
      andRestore = T.unpack (generateAndroidRegistrant [mkModPkg [restoreMod]])
  ok "a cpp module with no factory is left to the host (a comment, no register call)"
     (("// \"RestoreEngine\" is a host-built C++ NativeModule" `isInfixOf` andRestore)
        && not ("reg.registerModule" `isInfixOf` andRestore))
  ok "a no-factory cpp module emits no factory #include"
     (not ("#include \"RestoreEngine" `isInfixOf` andRestore))

  -- A mixed app (the real Lumen shape: Billing cpp+factory, navigation streaming, inference cpp
  -- host-built) emits every kind in the one registrant, deduping the factory #include.
  let lumenPkgs = [ mkModPkg [billingMod]
                  , mkModPkg [ nm3 "Lifecycle" ["appState"] "jni", nm3 "AppShell" ["colorScheme"] "jni" ]
                  , mkModPkg [restoreMod] ]
      andLumen  = T.unpack (generateAndroidRegistrant lumenPkgs)
  ok "the mixed Lumen registrant carries billing factory + both streaming + the restore comment"
     (("reg.registerModule(globalBillingModule());" `isInfixOf` andLumen)
        && ("globalStreamingModule(\"Lifecycle\"" `isInfixOf` andLumen)
        && ("globalStreamingModule(\"AppShell\", {\"colorScheme\"}));" `isInfixOf` andLumen)
        && ("// \"RestoreEngine\" is a host-built" `isInfixOf` andLumen))

  let emptyAnd = T.unpack (generateAndroidRegistrant [])
  ok "no modules -> a compilable empty registrant ((void)reg)"
     (("(void)reg;" `isInfixOf` emptyAnd) && ("canopyRegisterGeneratedModules" `isInfixOf` emptyAnd))

  putStrLn "\nautolink — Android C++ CMake fragment (AUTO-D-CPP-STREAMING)"
  -- A cpp package's native/cpp dir is globbed into the canopyhost target + its include path, and
  -- the registrant macro is defined. NativeManifest = (modules, viewTags, androidSrc, gradleDeps,
  -- iosSrc, cppSrc, podDeps, iosPerms, androidPerms).
  let billCppMan = NativeManifest [billingMod] [] (Just "native/android") []
                     (Just "native/ios") (Just "native/cpp") [] [] []
      billCppPkg = DiscoveredPackage "/deps/billing" billCppMan
      cmakeFrag  = T.unpack (generateCmakeFragment [billCppPkg])
  ok "CMake fragment is a GENERATED do-not-commit include"
     (("GENERATED by `canopy-native` autolink" `isInfixOf` cmakeFrag)
        && ("Do not commit" `isInfixOf` cmakeFrag))
  ok "CMake fragment globs the package's native/cpp into CANOPY_AUTOLINK_CPP_SOURCES"
     (("file(GLOB _canopy_pkg_cpp \"/deps/billing/native/cpp/*.cpp\")" `isInfixOf` cmakeFrag)
        && ("list(APPEND CANOPY_AUTOLINK_CPP_SOURCES" `isInfixOf` cmakeFrag))
  ok "CMake fragment puts the cpp dir on the include path (so BillingModule.h resolves by basename)"
     ("list(APPEND CANOPY_AUTOLINK_CPP_INCLUDES \"/deps/billing/native/cpp\")" `isInfixOf` cmakeFrag)
  ok "CMake fragment defines CANOPY_HAS_GENERATED_REGISTRANT for the boot #ifdef"
     ("add_compile_definitions(CANOPY_HAS_GENERATED_REGISTRANT=1)" `isInfixOf` cmakeFrag)
  ok "CMake fragment initializes both autolink vars empty (so an un-autolinked include() is a no-op)"
     (("set(CANOPY_AUTOLINK_CPP_SOURCES \"\")" `isInfixOf` cmakeFrag)
        && ("set(CANOPY_AUTOLINK_CPP_INCLUDES \"\")" `isInfixOf` cmakeFrag))

  -- A package with NO cpp source contributes no glob/source line (only the empty vars + the def).
  let noCppFrag = T.unpack (generateCmakeFragment [pingPkg])
  ok "a package with no native/cpp adds no source glob to the CMake fragment"
     (not ("file(GLOB" `isInfixOf` noCppFrag))

  putStrLn "\nautolink — iOS build includes (AUTO-C-IOS: project.yml + Podfile + Info.plist)"

  -- Full-manifest fixture: a package shipping iOS sources + C++ + a pod + a permission.
  -- NativeManifest = (modules, viewTags, androidSrc, gradleDeps, iosSrc, cppSrc, podDeps, iosPerms, androidPerms)
  let photosMan = NativeManifest
        [nm3 "Photos" [] "jni"] [] Nothing []
        (Just "native/ios") Nothing []
        [IosPermission "NSPhotoLibraryUsageDescription" "Access photos to restore."] []
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
        [nm3 "Restore" [] "cpp"] [] Nothing []
        (Just "native/ios") (Just "native/cpp/Restore.cpp") [] [] []
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
        ["'SomeSDK', '~> 2.0'"] [] []
      podPkg  = DiscoveredPackage "/deps/sdk" podMan
      podFrag = T.unpack (generateIosPodfileFragment [podPkg])
  ok "Podfile fragment emits a pod line for each declared pod dependency"
     ("pod 'SomeSDK', '~> 2.0'" `isInfixOf` podFrag)
  ok "Podfile fragment documents how the host Podfile includes it"
     ("eval_podfile" `isInfixOf` podFrag)

  -- Two packages declaring the SAME pod link once (DoD #5 path-keyed dedup analogue).
  let podDupA   = DiscoveredPackage "/a" (NativeManifest [] [] Nothing [] Nothing Nothing ["'Shared', '1.0'"] [] [])
      podDupB   = DiscoveredPackage "/b" (NativeManifest [] [] Nothing [] Nothing Nothing ["'Shared', '1.0'"] [] [])
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
                   [IosPermission "NSCameraUsageDescription" "Scan & crop <photos>"] []
      escPkg   = DiscoveredPackage "/c" escMan
      escPlist = T.unpack (generateIosInfoPlistFragment [escPkg])
  ok "Info.plist usage strings are XML-escaped (& -> &amp;, < -> &lt;)"
     (("Scan &amp; crop &lt;photos&gt;" `isInfixOf` escPlist)
        && not ("Scan & crop <photos>" `isInfixOf` escPlist))

  -- Same Info.plist key declared by two packages collapses to one entry (first wins).
  let permDupA   = DiscoveredPackage "/a" (NativeManifest [] [] Nothing [] Nothing Nothing []
                     [IosPermission "NSPhotoLibraryUsageDescription" "first"] [])
      permDupB   = DiscoveredPackage "/b" (NativeManifest [] [] Nothing [] Nothing Nothing []
                     [IosPermission "NSPhotoLibraryUsageDescription" "second"] [])
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

  putStrLn "\nautolink — Android permissions (permissions.android -> AndroidManifest fragment)"
  -- FromJSON reads permissions.android into manAndroidPerms (the Android analogue of iosPerms).
  let andManJson = "{\"modules\":[{\"name\":\"Http\"}],\"androidSource\":\"native/android\","
                     <> "\"permissions\":{\"android\":[\"android.permission.INTERNET\"]}}"
  case (decode andManJson :: Maybe NativeManifest) of
    Nothing  -> ok "native.json FromJSON parses permissions.android" False
    Just man -> ok "native.json FromJSON reads permissions.android into manAndroidPerms"
                   (manAndroidPerms man == ["android.permission.INTERNET"])

  -- generateAndroidManifestFragment emits a mergeable secondary manifest with one
  -- <uses-permission> per declared Android permission.
  let httpAndMan = NativeManifest [nm3 "Http" [] "jni"] [] (Just "native/android") []
                     Nothing Nothing [] [] ["android.permission.INTERNET"]
      httpAndPkg = DiscoveredPackage "/deps/http" httpAndMan
      andFrag    = T.unpack (generateAndroidManifestFragment [httpAndPkg])
  ok "Android manifest fragment is a GENERATED do-not-edit secondary manifest"
     (("GENERATED by `canopy-native` autolink" `isInfixOf` andFrag)
        && ("DO NOT EDIT" `isInfixOf` andFrag))
  ok "Android manifest fragment is a complete <manifest> doc with an empty <application/>"
     (("<manifest" `isInfixOf` andFrag) && ("<application />" `isInfixOf` andFrag)
        && ("</manifest>" `isInfixOf` andFrag))
  ok "Android manifest fragment emits a <uses-permission> for the declared permission"
     ("<uses-permission android:name=\"android.permission.INTERNET\" />" `isInfixOf` andFrag)

  -- Two packages declaring the SAME permission collapse to one <uses-permission> (DoD #5 dedup).
  let andDupA   = DiscoveredPackage "/a" (NativeManifest [] [] Nothing [] Nothing Nothing [] []
                    ["android.permission.INTERNET"])
      andDupB   = DiscoveredPackage "/b" (NativeManifest [] [] Nothing [] Nothing Nothing [] []
                    ["android.permission.INTERNET"])
      andDupOut = T.unpack (generateAndroidManifestFragment [andDupA, andDupB])
  ok "the same Android permission from two packages dedupes to one <uses-permission>"
     (countInfix "android:name=\"android.permission.INTERNET\"" andDupOut == 1)

  let emptyAndFrag = T.unpack (generateAndroidManifestFragment [])
  ok "no Android permissions -> a comment, no <uses-permission> element"
     (("no autolinked Android permissions" `isInfixOf` emptyAndFrag)
        && not ("<uses-permission android:name" `isInfixOf` emptyAndFrag))

  putStrLn "\nmodule extraction — native.json codegen (AUTO-D-JNI)"
  -- The pure-JNI spec set is the cleanly-extractable subset: Photos/Billing/Lifecycle/AppShell/
  -- RestoreEngine are intentionally EXCLUDED (host-coupled or C++/streaming).
  let specNames = map esModule pureJniSpecs
  ok "pureJniSpecs covers the 13 cleanly-extractable pure-JNI capabilities"
     (length pureJniSpecs == 13)
  ok "pureJniSpecs includes Http/Image/Vibration but NOT Photos/Billing/Lifecycle"
     (all (`elem` specNames) ["Http", "Image", "Vibration", "Battery", "Brightness"]
        && not (any (`elem` specNames) ["Photos", "Billing", "Lifecycle", "AppShell", "RestoreEngine"]))

  -- The host source file names follow the by-convention naming the autolinker + FindClass use.
  let httpSpec = head [ s | s <- pureJniSpecs, esModule s == "Http" ]
  ok "androidImplFileName is <Name>Module.java (the FindClass convention)"
     (androidImplFileName httpSpec == "HttpModule.java")
  ok "iosImplFileName is Canopy<Name>Module.mm (the iOS by-name convention)"
     (iosImplFileName httpSpec == "CanopyHttpModule.mm")

  -- Every generated native.json must parse back into the SAME NativeManifest the autolinker reads
  -- (the round-trip that guarantees extraction output is consumable by discovery).
  -- decode reads bytes, so encode the rendered Text as UTF-8 (the em-dash in the _comment is
  -- multi-byte; BLC.pack would truncate it). This mirrors how readManifest reads native.json off disk.
  let renderParses es =
        case (decode (BL.fromStrict (TE.encodeUtf8 (renderNativeJson es))) :: Maybe NativeManifest) of
          Nothing  -> False
          Just man -> map nmName (manModules man) == [esModule es]
                        && manAndroidSrc man == Just "native/android"
                        && manIosSrc man == (if esHasIos es then Just "native/ios" else Nothing)
                        && map ipKey (manIosPerms man) == map ipKey (esIosPerms es)
                        && manAndroidPerms man == map apName (esAndroidPerms es)
  ok "every pureJniSpec's native.json round-trips through the autolinker's FromJSON"
     (all renderParses pureJniSpecs)

  -- A capability with an Android permission (Http) surfaces it in the manifest; one without
  -- (Vibration) omits the permissions block. Both ship an iOS twin (the IOS-7 parity set), so both
  -- carry an iosSource key — after AUTO-E-DELETE every pure-JNI capability is package-resident on
  -- BOTH platforms (no android-only capability remains).
  let httpJson = T.unpack (renderNativeJson httpSpec)
      vibSpec  = head [ s | s <- pureJniSpecs, esModule s == "Vibration" ]
      vibJson  = T.unpack (renderNativeJson vibSpec)
  ok "Http's native.json declares its INTERNET android permission + an iosSource key"
     (("android.permission.INTERNET" `isInfixOf` httpJson)
        && ("\"iosSource\"" `isInfixOf` httpJson))
  ok "Vibration's native.json carries an iosSource (iOS twin) but NO permissions block (none declared)"
     (("\"iosSource\"" `isInfixOf` vibJson) && not ("\"permissions\"" `isInfixOf` vibJson))

  -- End-to-end: extractModule copies a host source into the package + writes native.json.
  exTmp <- getTemporaryDirectory
  let exHostMods = exTmp </> "canopy-extract-host-mods"
      exHostIos  = exTmp </> "canopy-extract-host-ios"
      exPkg      = exTmp </> "canopy-extract-pkg"
  createDirectoryIfMissing True exHostMods
  createDirectoryIfMissing True exHostIos
  writeFile (exHostMods </> "HttpModule.java") "// fake HttpModule.java\nclass HttpModule {}\n"
  writeFile (exHostIos  </> "CanopyHttpModule.mm") "// fake CanopyHttpModule.mm\n"
  exRes <- extractModule exHostMods exHostIos exPkg httpSpec
  javaCopied  <- doesFileExist (exPkg </> "native" </> "android" </> "HttpModule.java")
  iosCopied   <- doesFileExist (exPkg </> "native" </> "ios" </> "CanopyHttpModule.mm")
  manWritten  <- doesFileExist (exPkg </> "native.json")
  ok "extractModule copies <Name>Module.java into <pkg>/native/android"   javaCopied
  ok "extractModule copies Canopy<Name>Module.mm into <pkg>/native/ios"   iosCopied
  ok "extractModule writes <pkg>/native.json"                            manWritten
  ok "extractModule reports the copies it made"
     (erAndroidCopied exRes && erIosCopied exRes)
  -- A missing host source is reported (not a crash) and native.json is still written.
  let exPkg2 = exTmp </> "canopy-extract-pkg-missing"
  exRes2 <- extractModule (exTmp </> "no-such-dir") (exTmp </> "no-such-ios") exPkg2 httpSpec
  man2Written <- doesFileExist (exPkg2 </> "native.json")
  ok "extractModule with an absent host source skips the copy but still writes native.json"
     (not (erAndroidCopied exRes2) && man2Written)

  -- L-I5: a capability with an esExtraIos companion (Billing → CanopyBillingStoreKit2.swift) carries
  -- BOTH the .mm and the extra iOS source into native/ios, so the package is self-contained on iOS.
  let billingExtractSpec = head [ s | s <- cppStreamingSpecs, esModule s == "Billing" ]
      exPkg3   = exTmp </> "canopy-extract-pkg-billing"
      exHostCpp = exTmp </> "canopy-extract-host-cpp"
  ok "Billing's spec declares its StoreKit 2 Swift companion as esExtraIos"
     (esExtraIos billingExtractSpec == ["CanopyBillingStoreKit2.swift"])
  createDirectoryIfMissing True exHostCpp
  writeFile (exHostMods </> "BillingModule.java")             "// fake BillingModule.java\n"
  writeFile (exHostIos  </> "CanopyBillingModule.mm")         "// fake CanopyBillingModule.mm\n"
  writeFile (exHostIos  </> "CanopyBillingStoreKit2.swift")   "// fake CanopyBillingStoreKit2.swift\n"
  writeFile (exHostCpp  </> "BillingModule.cpp")              "// fake BillingModule.cpp\n"
  writeFile (exHostCpp  </> "BillingModule.h")                "// fake BillingModule.h\n"
  _exRes3 <- extractModuleInto exHostMods exHostIos exHostCpp exPkg3 [billingExtractSpec] billingExtractSpec
  billMm    <- doesFileExist (exPkg3 </> "native" </> "ios" </> "CanopyBillingModule.mm")
  billSwift <- doesFileExist (exPkg3 </> "native" </> "ios" </> "CanopyBillingStoreKit2.swift")
  ok "extraction copies Billing's CanopyBillingModule.mm into <pkg>/native/ios"     billMm
  ok "extraction copies the StoreKit 2 Swift driver into <pkg>/native/ios (esExtraIos)" billSwift

  putStrLn "\nmodule extraction — C++/streaming (AUTO-D-CPP-STREAMING)"
  -- The C++/streaming set is exactly the capabilities AUTO-D-JNI excluded.
  let cppNames = map esModule cppStreamingSpecs
  ok "cppStreamingSpecs covers Billing/Lifecycle/AppShell/RestoreEngine"
     (cppNames == ["Billing", "Lifecycle", "AppShell", "RestoreEngine"])
  ok "allExtractSpecs is the pure-JNI set plus the C++/streaming set"
     (length allExtractSpecs == length pureJniSpecs + length cppStreamingSpecs)

  -- Billing: a cpp module with a streaming method + a registrable factory + a Java delegate + a
  -- portable-C++ source. Its native.json must carry kind=cpp, the factory + header, streaming, and
  -- a cppSource — and round-trip through the autolinker's FromJSON to the SAME module spec.
  let billingSpec = head [ s | s <- cppStreamingSpecs, esModule s == "Billing" ]
      billingJson = T.unpack (renderNativeJson billingSpec)
  ok "Billing's native.json declares kind=cpp + its factory + factoryHeader"
     (("\"kind\": \"cpp\"" `isInfixOf` billingJson)
        && ("\"factory\": \"globalBillingModule\"" `isInfixOf` billingJson)
        && ("\"factoryHeader\": \"BillingModule.h\"" `isInfixOf` billingJson))
  ok "Billing's native.json declares its entitlementChanges stream + a cppSource"
     (("\"streaming\": [\"entitlementChanges\"]" `isInfixOf` billingJson)
        && ("\"cppSource\": \"native/cpp\"" `isInfixOf` billingJson))
  case (decode (BL.fromStrict (TE.encodeUtf8 (renderNativeJson billingSpec))) :: Maybe NativeManifest) of
    Nothing  -> ok "Billing's native.json round-trips through FromJSON" False
    Just man -> do
      let m = head (manModules man)
      ok "Billing native.json round-trips to a cpp+factory+streaming module spec"
         (nmName m == "Billing" && nmKind m == "cpp"
            && nmFactory m == Just "globalBillingModule"
            && nmFactoryHeader m == Just "BillingModule.h"
            && nmStreaming m == ["entitlementChanges"])
      ok "Billing native.json round-trips its cppSource"
         (manCppSrc man == Just "native/cpp")

  -- RestoreEngine: a host-built cpp module — kind=cpp, NO factory, NO Java side, a cppSource.
  let restoreSpec = head [ s | s <- cppStreamingSpecs, esModule s == "RestoreEngine" ]
      restoreJson = T.unpack (renderNativeJson restoreSpec)
  ok "RestoreEngine's native.json is kind=cpp with NO factory key (host-built)"
     (("\"kind\": \"cpp\"" `isInfixOf` restoreJson) && not ("\"factory\"" `isInfixOf` restoreJson))
  ok "RestoreEngine has no Java side (esHasJava == False)"
     (not (esHasJava restoreSpec))

  -- Navigation is a MULTI-module package (Lifecycle + AppShell) -> ONE native.json listing both,
  -- via renderNativeJsonPackage. Both stream; neither is cpp; the manifest round-trips to 2 modules.
  let navSpecs = [ s | s <- cppStreamingSpecs, esPackageDir s == "navigation" ]
      navJson  = T.unpack (renderNativeJsonPackage navSpecs)
  ok "navigation's specs are Lifecycle + AppShell (one package, two modules)"
     (map esModule navSpecs == ["Lifecycle", "AppShell"])
  ok "navigation's native.json lists BOTH modules with their streaming channels"
     (("\"name\": \"Lifecycle\", \"streaming\": [\"appState\", \"memoryPressure\", \"backPressed\"]"
        `isInfixOf` navJson)
        && ("\"name\": \"AppShell\", \"streaming\": [\"colorScheme\"]" `isInfixOf` navJson))
  case (decode (BL.fromStrict (TE.encodeUtf8 (renderNativeJsonPackage navSpecs))) :: Maybe NativeManifest) of
    Nothing  -> ok "navigation's multi-module native.json round-trips" False
    Just man -> ok "navigation's native.json round-trips to two streaming JNI modules"
                   (map nmName (manModules man) == ["Lifecycle", "AppShell"]
                      && all ((== "jni") . nmKind) (manModules man)
                      && all (not . null . nmStreaming) (manModules man))

  -- End-to-end extractModuleInto for a cpp module: copies the Java delegate, the .mm, AND the
  -- native/cpp source, then writes native.json. Build fake host trees so nothing touches the repo.
  let cxHostMods  = exTmp </> "canopy-cpp-host-mods"
      cxHostIos   = exTmp </> "canopy-cpp-host-ios"
      cxHostCpp   = exTmp </> "canopy-cpp-host-shared-cpp"
      cxPkg       = exTmp </> "canopy-cpp-pkg-billing"
  createDirectoryIfMissing True cxHostMods
  createDirectoryIfMissing True cxHostIos
  createDirectoryIfMissing True cxHostCpp
  writeFile (cxHostMods </> "BillingModule.java")           "// fake BillingModule.java\n"
  writeFile (cxHostIos  </> "CanopyBillingModule.mm")       "// fake CanopyBillingModule.mm\n"
  writeFile (cxHostIos  </> "CanopyBillingStoreKit2.swift") "// fake CanopyBillingStoreKit2.swift\n"
  writeFile (cxHostCpp  </> "BillingModule.cpp")            "// fake BillingModule.cpp\n"
  writeFile (cxHostCpp  </> "BillingModule.h")              "// fake BillingModule.h\n"
  cxRes <- extractModuleInto cxHostMods cxHostIos cxHostCpp cxPkg [billingSpec] billingSpec
  cxJava <- doesFileExist (cxPkg </> "native" </> "android" </> "BillingModule.java")
  cxIos  <- doesFileExist (cxPkg </> "native" </> "ios" </> "CanopyBillingModule.mm")
  cxSwift <- doesFileExist (cxPkg </> "native" </> "ios" </> "CanopyBillingStoreKit2.swift")
  cxCpp  <- doesFileExist (cxPkg </> "native" </> "cpp" </> "BillingModule.cpp")
  cxHdr  <- doesFileExist (cxPkg </> "native" </> "cpp" </> "BillingModule.h")
  cxMan  <- doesFileExist (cxPkg </> "native.json")
  ok "extractModuleInto copies the cpp module's Java delegate into native/android"  cxJava
  ok "extractModuleInto copies the cpp module's .mm into native/ios"                cxIos
  ok "extractModuleInto copies the cpp module's StoreKit 2 Swift companion into native/ios" cxSwift
  ok "extractModuleInto copies the cpp module's .cpp into native/cpp"               cxCpp
  ok "extractModuleInto copies the cpp module's .h into native/cpp"                 cxHdr
  ok "extractModuleInto writes the package native.json"                            cxMan
  ok "extractModuleInto reports the android + ios + cpp copies"
     (erAndroidCopied cxRes && erIosCopied cxRes && erCppCopied cxRes)

  -- A streaming JNI extraction (Lifecycle) shares StreamingBridge.java via esExtraAndroid; verify
  -- the extra file is copied alongside the module's own <Name>Module.java.
  let lcSpec   = head [ s | s <- cppStreamingSpecs, esModule s == "Lifecycle" ]
      lcPkg    = exTmp </> "canopy-cpp-pkg-nav"
  writeFile (cxHostMods </> "LifecycleModule.java") "// fake LifecycleModule.java\n"
  writeFile (cxHostMods </> "StreamingBridge.java") "// fake StreamingBridge.java\n"
  lcRes <- extractModuleInto cxHostMods cxHostIos cxHostCpp lcPkg navSpecs lcSpec
  lcMod    <- doesFileExist (lcPkg </> "native" </> "android" </> "LifecycleModule.java")
  lcBridge <- doesFileExist (lcPkg </> "native" </> "android" </> "StreamingBridge.java")
  ok "extractModuleInto copies the streaming module's own LifecycleModule.java"     lcMod
  ok "extractModuleInto copies the shared StreamingBridge.java (esExtraAndroid)"     lcBridge
  ok "a streaming JNI extraction has no cpp copy (esCppSources is empty)"
     (not (erCppCopied lcRes))

  -- discoverPackages walks the dep graph: both the DIRECT deps and the INDIRECT (transitive) ones
  -- of an app are scanned, so a native capability pulled transitively (e.g. canopy/navigation via a
  -- UI package) still autolinks. Build two fixture apps that depend on the just-materialized
  -- packages, resolved against the real monorepo (CANOPY_MONOREPO, default ~/projects/canopy).
  let discTmp     = exTmp </> "canopy-discover-app"
      discTmpIndir = exTmp </> "canopy-discover-app-indirect"
  createDirectoryIfMissing True discTmp
  createDirectoryIfMissing True discTmpIndir
  writeFile (discTmp </> "canopy.json")
    "{ \"name\": \"d\", \"dependencies\": { \"direct\": { \"canopy/billing\": \"^1\", \"canopy/inference\": \"^1\" } } }"
  writeFile (discTmpIndir </> "canopy.json")
    ("{ \"name\": \"d\", \"dependencies\": { \"direct\": { \"canopy/billing\": \"^1\" }, "
       <> "\"indirect\": { \"canopy/navigation\": \"^1\" } } }")
  discDirect <- discoverPackages discTmp
  discIndir  <- discoverPackages discTmpIndir
  let discNames = concatMap (map nmName . manModules . dpManifest)
  -- These assert ONLY when the real packages were materialized (native.json present). If a fresh
  -- checkout hasn't run `extract-modules`, billing/navigation/inference have no native.json yet, so
  -- discovery is empty — we treat that as a skip (report, don't fail) so the unit test is hermetic.
  if null discDirect
    then putStrLn "  (skipped discoverPackages real-monorepo checks: packages not yet extracted — run `canopy-native extract-modules`)"
    else do
      ok "discoverPackages finds the DIRECT cpp deps (Billing + RestoreEngine)"
         (all (`elem` discNames discDirect) ["Billing", "RestoreEngine"])
      ok "discoverPackages ALSO walks INDIRECT deps (transitive canopy/navigation -> Lifecycle/AppShell)"
         (all (`elem` discNames discIndir) ["Lifecycle", "AppShell"])

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

  putStrLn "\ngen-capability — full self-contained package (AUTO-E-DELETE / plan §5 Phase E)"
  -- packageFiles emits the COMPLETE self-contained package (DoD #1/#6): canopy.json + native.json +
  -- src/<Name>.can + native/android + native/ios + harness mock — so `gen-capability Foo` produces a
  -- package that autolinks with NO host edits, the native analogue of `canopy/http` shipping
  -- external/http.js. We assert the file SET, each artifact's load-bearing shape, and — the key Phase
  -- E guarantee — that the generated native.json is exactly what the autolinker discovers + registers.
  let capSpec   = CapabilitySpec "Flashlight" ["turnOn", "turnOff", "isOn"]
      genFiles  = packageFiles capSpec
      genPaths  = map gfPath genFiles
      contentOf p = maybe "" (T.unpack . gfContent) (lookup p [ (gfPath g, g) | g <- genFiles ])
  ok "packageFiles emits the 6 self-contained-package files (canopy.json/native.json/src/android/ios/mock)"
     (genPaths == [ "canopy.json", "native.json", "src/Flashlight.can"
                  , "native/android/FlashlightModule.java", "native/ios/CanopyFlashlightModule.mm"
                  , "harness/mock.js" ])
  ok "canopy.json is a canopy/<lowercase> package exposing the module + depending on canopy/native"
     (    ("\"name\": \"canopy/flashlight\"" `isInfixOf` contentOf "canopy.json")
       && ("\"Flashlight\"" `isInfixOf` contentOf "canopy.json")
       && ("\"canopy/native\"" `isInfixOf` contentOf "canopy.json"))
  ok "src/<Name>.can is a top-level module (NOT Native.*) routing through Native.Module.call"
     (    ("module Flashlight exposing" `isInfixOf` contentOf "src/Flashlight.can")
       && ("NM.call \"Flashlight\" \"turnOn\"" `isInfixOf` contentOf "src/Flashlight.can"))
  ok "native/android/<Name>Module.java is a JniModule dispatcher in the canopyhost.modules package"
     (    ("package com.canopyhost.modules;" `isInfixOf` contentOf "native/android/FlashlightModule.java")
       && ("public final class FlashlightModule" `isInfixOf` contentOf "native/android/FlashlightModule.java")
       && ("case \"turnOn\":" `isInfixOf` contentOf "native/android/FlashlightModule.java"))
  ok "native/ios/Canopy<Name>Module.mm is a <CanopyModule> twin dispatching every method"
     (    ("@interface CanopyFlashlightModule : NSObject <CanopyModule>" `isInfixOf` contentOf "native/ios/CanopyFlashlightModule.mm")
       && ("return @\"Flashlight\"" `isInfixOf` contentOf "native/ios/CanopyFlashlightModule.mm")
       && ("isEqualToString:@\"isOn\"" `isInfixOf` contentOf "native/ios/CanopyFlashlightModule.mm"))
  -- The generated native.json must parse as a NativeManifest AND drive the autolinker to register the
  -- module on both platforms — the end-to-end DoD #6 proof, done purely over the generated text.
  let genManifest = decode (BL.fromStrict (TE.encodeUtf8 (T.pack (contentOf "native.json")))) :: Maybe NativeManifest
  ok "the generated native.json parses as a NativeManifest declaring the one jni module"
     (case genManifest of
        Just m  -> map nmName (manModules m) == ["Flashlight"]
                     && all ((== "jni") . nmKind) (manModules m)
                     && manAndroidSrc m == Just "native/android"
                     && manIosSrc m == Just "native/ios"
        Nothing -> False)
  let genPkg = [ DiscoveredPackage "/tmp/flashlight" m | Just m <- [genManifest] ]
      genAnd = T.unpack (generateAndroidRegistrant genPkg)
      genIos = T.unpack (generateIosRegistrant genPkg)
  ok "the autolinker registers the gen-capability module on Android (JniModule by name)"
     ("registerModule(std::make_shared<JniModule>(\"Flashlight\"))" `isInfixOf` genAnd)
  ok "the autolinker registers the gen-capability module on iOS (caps[] by name)"
     ("@\"name\": @\"Flashlight\"" `isInfixOf` genIos)

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
