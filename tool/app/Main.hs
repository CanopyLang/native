-- | The @canopy-native@ CLI: build orchestration, Fabric codegen, scaffolding, and a
-- toolchain doctor. Arg parsing is deliberately dependency-free (the heavy lifting is
-- in the library) so the tool builds with only the Canopy compiler's snapshot.
module Main (main) where

import           Canopy.Native.Build
import           Canopy.Native.CapabilityCodegen
import           Canopy.Native.DevClient
import           Canopy.Native.Doctor
import           Canopy.Native.Scaffold
import           Canopy.Native.Vendor
import           Control.Monad (forM_)
import qualified Data.ByteString.Lazy as BL
import           Data.List (isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Data.Time.Calendar (toGregorian)
import           Data.Time.Clock (getCurrentTime, utctDay)
import           System.Directory (getCurrentDirectory)
import           System.Environment (getArgs)
import           System.Exit (exitFailure, exitSuccess)
import           System.FilePath ((</>))
import           Text.Printf (printf)

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
  ("run" : rest)     -> cmdRun rest
  ("dev" : rest)     -> cmdRun rest
  ("vendor-lock" : rest)   -> cmdVendorLock rest
  ("vendor-verify" : rest) -> cmdVendorVerify rest
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

-- | @canopy-native run@ / @dev@ (DEV-6): stand up the full dev loop — build, install the debug
-- APK, wire the device to the dev server (adb reverse / setprop), launch the app, and start the
-- watcher+WS-push dev server the on-device CanopyDevClient attaches to.
--
-- The host app's Android package + launcher activity are fixed by the canopy/native host project
-- (the applicationId in host/android/app/build.gradle), matching scripts/dev.sh.
hostPackage, hostActivity :: String
hostPackage  = "org.canopy.echo"
hostActivity = "com.canopyhost.MainActivity"

cmdRun :: [String] -> IO ()
cmdRun rest = case parseRunOptions rest of
  Left err   -> putStrLn err >> putStrLn runUsage >> exitFailure
  Right opts -> do
    result <- executeRun opts hostPackage hostActivity
    either (\msg -> putStrLn msg >> exitFailure) (const (pure ())) result

runUsage :: String
runUsage = unlines
  [ "usage: canopy-native run [APP_DIR] [--port N] [--host IP] [--no-server]"
  , "  APP_DIR       the app directory (default '.')"
  , "  --port N      dev-server port (default 8099)"
  , "  --host IP     a LAN box's IP (DEV-7); skips adb reverse, binds the server to 0.0.0.0"
  , "  --no-server   install+launch+wire only; do not start the dev server"
  ]

-- ---------------------------------------------------------------------------
-- vendor provenance (RNV-1)
-- ---------------------------------------------------------------------------

-- | Path of the committed lockfile relative to the repo root.
vendorLockRel :: FilePath
vendorLockRel = "host" </> "vendor.lock.json"

-- | Resolve the repo root from @--root@ or by walking up from the CWD; abort loudly if not found.
resolveRootOrDie :: [String] -> IO FilePath
resolveRootOrDie rest = do
  cwd <- getCurrentDirectory
  mr  <- resolveRoot (flagValue "--root" rest) cwd
  case mr of
    Just r  -> pure r
    Nothing -> putStrLn "vendor: could not locate the repo root (no ancestor with a host/ dir; pass --root DIR)"
                 >> exitFailure >> pure ""

-- | Current UTC date as @YYYY-MM-DD@ for the generatedAt stamp.
todayStamp :: IO T.Text
todayStamp = do
  (y, m, d) <- toGregorian . utctDay <$> getCurrentTime
  pure (T.pack (printf "%04d-%02d-%02d" y m d))

cmdVendorLock :: [String] -> IO ()
cmdVendorLock rest = do
  root  <- resolveRootOrDie rest
  stamp <- todayStamp
  lock  <- generateLock root stamp vendoredArtifacts
  let out = root </> vendorLockRel
  BL.writeFile out (renderLock lock)
  putStrLn ("wrote " <> out <> " — " <> show (length (lfEntries lock)) <> " artifacts")

cmdVendorVerify :: [String] -> IO ()
cmdVendorVerify rest = do
  root  <- resolveRootOrDie rest
  let lockPath = root </> vendorLockRel
  raw <- BL.readFile lockPath
  case decodeLock raw of
    Left err   -> putStrLn ("vendor: cannot parse " <> lockPath <> ": " <> err) >> exitFailure
    Right lock -> do
      mismatches <- verifyLock root lock
      if null mismatches
        then putStrLn ("vendor OK — " <> show (length (lfEntries lock)) <> " artifacts verified")
        else do
          putStrLn ("vendor DRIFT — " <> show (length mismatches) <> " artifact(s) failed verification:")
          forM_ mismatches $ \m -> do
            putStrLn ("  ✗ " <> T.unpack (mmRelPath m) <> "  (" <> T.unpack (mmReason m) <> ")")
            putStrLn ("      expected: " <> T.unpack (mmExpected m))
            putStrLn ("      actual:   " <> T.unpack (mmActual m))
          exitFailure

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
  putStrLn "  run [DIR] [--port N] [--host IP]           build + install + wire the dev loop + start the dev server (alias: dev)"
  putStrLn "  codegen [--out DIR]                        emit the Fabric mapping glue only"
  putStrLn "  gen-capability <Name> --methods m1,m2      scaffold a native capability (.can + Java + boot line)"
  putStrLn "  vendor-lock [--root DIR]                   regenerate host/vendor.lock.json from the vendored artifacts"
  putStrLn "  vendor-verify [--root DIR]                 recompute checksums + diff the committed lock; non-zero on drift"
  putStrLn "  doctor                                     report toolchain readiness"
  putStrLn "  version | help"
