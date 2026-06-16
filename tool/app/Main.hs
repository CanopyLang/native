-- | The @canopy-native@ CLI: build orchestration, Fabric codegen, scaffolding, and a
-- toolchain doctor. Arg parsing is deliberately dependency-free (the heavy lifting is
-- in the library) so the tool builds with only the Canopy compiler's snapshot.
module Main (main) where

import           Canopy.Native.Build
import           Canopy.Native.CapabilityCodegen
import           Canopy.Native.DevClient
import           Canopy.Native.Doctor
import           Canopy.Native.Extract
import           Canopy.Native.Scaffold
import           Canopy.Native.Vendor
import           Control.Monad (forM_)
import qualified Data.ByteString.Lazy as BL
import           Data.List (isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Data.Time.Calendar (toGregorian)
import           Data.Time.Clock (getCurrentTime, utctDay)
import           Data.Char (toLower)
import           System.Directory (createDirectoryIfMissing, getCurrentDirectory, getHomeDirectory)
import           System.Environment (getArgs)
import           System.Exit (exitFailure, exitSuccess)
import           System.FilePath ((</>), takeDirectory, takeFileName)
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
  ("extract-modules" : rest) -> cmdExtractModules rest
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

-- | @canopy-native gen-capability \<Name\> --methods m1,m2 [--out DIR]@ (AUTO-E-DELETE / plan §5
-- Phase E): generate a FULL SELF-CONTAINED capability package — the native analogue of a web package
-- shipping its own @external/*.js@. Emits @canopy/\<name\>/@ with @canopy.json@ + @native.json@ +
-- @src/\<Name\>.can@ + @native/android/\<Name\>Module.java@ + @native/ios/Canopy\<Name\>Module.mm@ +
-- @harness/mock.js@, so adding the capability to an app is "add a dependency" with NO host edits
-- (the autolinker registers it from the package's native.json — there is no boot line to paste).
--
-- @--out DIR@ roots where the @canopy/\<name\>@ package dir is created (default the CWD).
cmdGenCapability :: [String] -> IO ()
cmdGenCapability rest =
  case positional rest of
    (name : _) -> do
      let methods = filter (not . T.null)
                      (maybe [] (T.splitOn "," . T.pack) (flagValue "--methods" rest))
          outDir  = flagValue "--out" rest `orElse` "."
          spec    = CapabilitySpec (T.pack name) methods
          pkgDir  = outDir </> "canopy" </> map toLower name
      if null methods
        then putStrLn "gen-capability: --methods m1,m2 is required" >> exitFailure
        else do
          forM_ (packageFiles spec) $ \gf -> do
            let dest = pkgDir </> gfPath gf
            createDirectoryIfMissing True (takeDirectory dest)
            TIO.writeFile dest (gfContent gf)
            putStrLn ("  generated " <> dest)
          putStrLn ""
          putStrLn ("Self-contained package written to " <> pkgDir <> "/")
          putStrLn "It autolinks from its native.json — add it to an app's canopy.json dependencies"
          putStrLn ("and `import " <> name <> "`; run `canopy-native build` (NO host/boot edits).")
          putStrLn "Fill in the method bodies in src/, native/android/, and native/ios/."
    [] -> putStrLn "usage: canopy-native gen-capability <Name> --methods m1,m2 [--out DIR]" >> exitFailure

-- | @canopy-native extract-modules@ (AUTO-D-JNI, plan §5 Phase D): make every pure-JNI capability
-- PACKAGE-RESIDENT. For each known capability it copies the host's @<Name>Module.java@ (+ iOS
-- @Canopy<Name>Module.mm@) into the package's @native/android@ (+ @native/ios@) and writes the
-- package's @native.json@ manifest — so @canopy-native build@ autolinks the capability from the
-- dependency graph with zero host edits, exactly like @canopy/ping@.
--
-- @--monorepo DIR@ overrides the package-tree root (default @CANOPY_MONOREPO@, else ~/projects/canopy);
-- @--host DIR@ overrides the canopy/native host dir (default the repo's @host/@, resolved from CWD).
-- @--only jni@ / @--only cpp@ restrict to one half; the default extracts BOTH the pure-JNI set
-- (AUTO-D-JNI) and the C++/streaming set (AUTO-D-CPP-STREAMING: Billing, Lifecycle, AppShell,
-- RestoreEngine).
cmdExtractModules :: [String] -> IO ()
cmdExtractModules rest = do
  home <- getHomeDirectory
  cwd  <- getCurrentDirectory
  let monorepo = flagValue "--monorepo" rest `orElse` (home </> "projects" </> "canopy")
      hostDir  = flagValue "--host" rest `orElse` defaultHost cwd
      only     = flagValue "--only" rest
      doJni    = only /= Just "cpp"
      doCpp    = only /= Just "jni"
  jniResults <- if doJni then extractAll monorepo hostDir else pure []
  cppResults <- if doCpp then extractAllCppStreaming monorepo hostDir else pure []
  let results = jniResults ++ cppResults
  putStrLn ("canopy-native extract-modules — " <> show (length jniResults) <> " pure-JNI + "
              <> show (length cppResults) <> " C++/streaming capabilities")
  putStrLn ("  monorepo root: " <> monorepo)
  putStrLn ("  host dir:      " <> hostDir)
  putStrLn ""
  forM_ results $ \r ->
    putStrLn $ "  " <> okMark (erAndroidCopied r || erCppCopied r) <> " "
                 <> T.unpack (erModule r) <> " -> canopy/" <> erPackageDir' r
                 <> "  (android " <> copied (erAndroidCopied r)
                 <> ", ios " <> copied (erIosCopied r)
                 <> ", cpp " <> copied (erCppCopied r)
                 <> ", native.json written)"
  where
    -- Default host dir: the repo's host/ resolved from CWD (works when run inside canopy/native).
    defaultHost cwd = cwd </> "host"
    okMark True  = "\x2713"
    okMark False = "\x2717"
    copied True  = "copied"
    copied False = "skipped"
    erPackageDir' = takeFileName . erPackageDir

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
  putStrLn "  extract-modules [--monorepo DIR] [--only jni|cpp]  extract the in-host modules (pure-JNI + C++/streaming) into self-contained canopy/* packages"
  putStrLn "  vendor-lock [--root DIR]                   regenerate host/vendor.lock.json from the vendored artifacts"
  putStrLn "  vendor-verify [--root DIR]                 recompute checksums + diff the committed lock; non-zero on drift"
  putStrLn "  doctor                                     report toolchain readiness"
  putStrLn "  version | help"
