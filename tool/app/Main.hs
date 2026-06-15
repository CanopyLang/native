-- | The @canopy-native@ CLI: build orchestration, Fabric codegen, scaffolding, and a
-- toolchain doctor. Arg parsing is deliberately dependency-free (the heavy lifting is
-- in the library) so the tool builds with only the Canopy compiler's snapshot.
module Main (main) where

import           Canopy.Native.Build
import           Canopy.Native.CapabilityCodegen
import           Canopy.Native.Doctor
import           Canopy.Native.Scaffold
import           Data.List (isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           System.Environment (getArgs)
import           System.Exit (exitFailure, exitSuccess)
import           System.FilePath ((</>))

main :: IO ()
main = getArgs >>= dispatch

dispatch :: [String] -> IO ()
dispatch args = case args of
  []                 -> usage >> exitSuccess
  ("help" : _)       -> usage >> exitSuccess
  ("--help" : _)     -> usage >> exitSuccess
  ("version" : _)    -> putStrLn "canopy-native 0.1.0"
  ("--version" : _)  -> putStrLn "canopy-native 0.1.0"
  ("doctor" : _)     -> cmdDoctor
  ("codegen" : rest) -> cmdCodegen rest
  ("gen-capability" : rest) -> cmdGenCapability rest
  ("init" : rest)    -> cmdInit rest
  ("build" : rest)   -> cmdBuild rest
  (other : _)        -> putStrLn ("unknown command: " <> other) >> usage >> exitFailure

-- ---------------------------------------------------------------------------

cmdDoctor :: IO ()
cmdDoctor = do
  putStrLn "canopy-native doctor\n"
  checks <- runChecks
  TIO.putStr (renderChecks checks)

cmdCodegen :: [String] -> IO ()
cmdCodegen rest = do
  let out = flagValue "--out" rest `orElse` "generated"
  writeCodegen out
  putStrLn ("wrote Fabric mapping glue to " <> out <> "/ (component-manifest.json, CanopyComponents.h, canopyComponents.ts)")

cmdInit :: [String] -> IO ()
cmdInit rest = do
  case positional rest of
    (name : _) -> do
      let dir      = flagValue "--dir" rest `orElse` name
          bundleId = T.pack (flagValue "--bundle-id" rest `orElse` ("org.canopy." <> name))
      result <- scaffoldApp dir (T.pack name) bundleId
      either failT (const (putStrLn ("scaffolded " <> dir <> " — `cd " <> dir <> " && canopy-native build`"))) result
    [] -> putStrLn "usage: canopy-native init <name> [--dir DIR] [--bundle-id ID]" >> exitFailure

cmdGenCapability :: [String] -> IO ()
cmdGenCapability rest =
  case positional rest of
    (name : _) -> do
      let methods = filter (not . T.null)
                      (maybe [] (T.splitOn "," . T.pack) (flagValue "--methods" rest))
          outDir  = flagValue "--out" rest `orElse` "."
          spec    = CapabilitySpec (T.pack name) methods
          canPath  = outDir </> (name <> ".can")
          javaPath = outDir </> (name <> "Module.java")
      if null methods
        then putStrLn "gen-capability: --methods m1,m2 is required" >> exitFailure
        else do
          TIO.writeFile canPath  (renderCanModule spec)
          TIO.writeFile javaPath (renderJavaModule spec)
          putStrLn ("generated " <> canPath <> "  (place at src/Native/" <> name <> ".can in a package)")
          putStrLn ("generated " <> javaPath <> "  (place at host/android/.../modules/)")
          putStrLn ""
          putStrLn "Boot registration — paste into CanopyHostJni.cpp's registry block:"
          TIO.putStrLn (renderBootLine spec)
          putStrLn ""
          putStrLn "Harness mock — add to harness/mock-native-modules.js:"
          TIO.putStrLn (renderMockEntry spec)
    [] -> putStrLn "usage: canopy-native gen-capability <Name> --methods m1,m2 [--out DIR]" >> exitFailure

cmdBuild :: [String] -> IO ()
cmdBuild rest = do
  let dir     = positional rest `firstOr` "."
      release = "--release" `elem` rest
  result <- runBuild (BuildOptions dir release)
  case result of
    Left err   -> failT err
    Right path -> putStrLn ("built " <> path)

-- ---------------------------------------------------------------------------
-- tiny arg helpers
-- ---------------------------------------------------------------------------

positional :: [String] -> [String]
positional = filter (not . isPrefixOf "--")

firstOr :: [String] -> String -> String
firstOr xs d = case xs of (x : _) -> x; [] -> d

flagValue :: String -> [String] -> Maybe String
flagValue _ [] = Nothing
flagValue flag (x : y : rest)
  | x == flag = Just y
  | otherwise = flagValue flag (y : rest)
flagValue _ [_] = Nothing

orElse :: Maybe a -> a -> a
orElse (Just x) _ = x
orElse Nothing  d = d

failT :: T.Text -> IO ()
failT msg = TIO.putStrLn msg >> exitFailure

usage :: IO ()
usage = do
  putStrLn "canopy-native — build native iOS/Android apps from Canopy view code"
  putStrLn ""
  putStrLn "commands:"
  putStrLn "  init <name> [--dir DIR] [--bundle-id ID]   scaffold a new native app"
  putStrLn "  build [DIR] [--release]                    compile to JS + assemble Hermes bundle + codegen"
  putStrLn "  codegen [--out DIR]                        emit the Fabric mapping glue only"
  putStrLn "  gen-capability <Name> --methods m1,m2      scaffold a native capability (.can + Java + boot line)"
  putStrLn "  doctor                                     report toolchain readiness"
  putStrLn "  version | help"
