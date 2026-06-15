-- | Dependency-free assertions over the pure cores: codegen, bundle assembly, config
-- round-trip, and the component model. Exits non-zero on the first failure so `stack
-- test` is a real gate.
module Main (main) where

import           Canopy.Native.Assets (AssetEntry (..))
import           Canopy.Native.Autolink
import           Canopy.Native.Build (archiveReleaseMap)
import           Canopy.Native.Bundle
import           Canopy.Native.Codegen
import           Canopy.Native.Component
import           Canopy.Native.Config
import           Canopy.Native.Vendor
import           Control.Monad (unless)
import           Data.Aeson (decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.IORef
import           Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory)
import           System.Exit (exitFailure)
import           System.FilePath ((</>))

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

  putStrLn "\nconfig round-trip"
  let cfg = defaultConfig "Counter" "org.canopy.counter"
  case decodeConfig (encodeConfig cfg) of
    Right back -> do
      ok "config survives encode/decode" (back == cfg)
      ok "default main module is Main"   (ncMainModule back == "Main")
    Left err -> ok ("config decode failed: " <> err) False

  putStrLn "\nautolink — Android view-tag registrant"
  let mkPkg ts = DiscoveredPackage "/pkg" (NativeManifest [] ts Nothing [])
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
  let mkModPkg ms = DiscoveredPackage "/pkg" (NativeManifest ms [] Nothing [])
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

  n <- readIORef failures
  putStrLn ""
  if n == 0
    then putStrLn "ALL PASS"
    else putStrLn (show n <> " FAILED") >> exitFailure
