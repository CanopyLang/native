-- | Dependency-free assertions over the pure cores: codegen, bundle assembly, config
-- round-trip, and the component model. Exits non-zero on the first failure so `stack
-- test` is a real gate.
module Main (main) where

import           Canopy.Native.Bundle
import           Canopy.Native.Codegen
import           Canopy.Native.Component
import           Canopy.Native.Config
import           Control.Monad (unless)
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.IORef
import           Data.List (isInfixOf)
import qualified Data.Text as T
import           System.Exit (exitFailure)

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let ok name cond = do
        putStrLn (("  " <> tick cond <> " ") <> name)
        unless cond (modifyIORef' failures (+ 1))
      tick True = "\x2713"; tick False = "\x2717 FAIL:"

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

  putStrLn "\nconfig round-trip"
  let cfg = defaultConfig "Counter" "org.canopy.counter"
  case decodeConfig (encodeConfig cfg) of
    Right back -> do
      ok "config survives encode/decode" (back == cfg)
      ok "default main module is Main"   (ncMainModule back == "Main")
    Left err -> ok ("config decode failed: " <> err) False

  n <- readIORef failures
  putStrLn ""
  if n == 0
    then putStrLn "ALL PASS"
    else putStrLn (show n <> " FAILED") >> exitFailure
