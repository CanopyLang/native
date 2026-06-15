-- | @canopy-native run@ / @dev@ — DEV-6 tool-side dev-client glue.
--
-- The host half of the dev loop is CanopyDevClient.java (src/debug); this is the orchestration that
-- stands the loop up end to end, mirroring @react-native run-android@ + Metro:
--
--   1. build the app's JS bundle (@canopy-native build@);
--   2. install the DEBUG APK on the device/emulator (gradle @installDebug@);
--   3. wire the device to the dev server:
--        - emulator / USB (default): @adb reverse tcp:PORT tcp:PORT@ so the device's 127.0.0.1:PORT
--          reaches the host's dev server, and point the client at the emulator host-loopback alias
--          (10.0.2.2) or 127.0.0.1;
--        - LAN box (@--host IP@, DEV-7): SKIP @adb reverse@ and point the client straight at the
--          box's LAN IP, with the dev server bound to 0.0.0.0;
--      the device-facing host:port is pushed to the client via @adb shell setprop
--      debug.canopy.devhost HOST:PORT@ (CanopyDevBootstrap reads it first);
--   4. launch the app;
--   5. start the dev server (@node tool/canopy-dev-server.js APP --port PORT [--host 0.0.0.0]@),
--      which watches sources, rebuilds, and pushes bundles the client applies in-process.
--
-- The decision layer — what host the client should dial, whether to @adb reverse@, and the exact
-- ordered command plan — is PURE (devClientHost, runPlan) so Spec.hs pins it with no device, no
-- adb, no node. The IO driver (executeRun) is the thin shell that runs the plan.
module Canopy.Native.DevClient
  ( RunOptions (..)
  , defaultRunOptions
  , parseRunOptions
  , DevHost (..)
  , devClientHost
  , Step (..)
  , runPlan
  , renderStep
  , executeRun
  ) where

import           Data.List (isPrefixOf)
import           System.Directory (doesFileExist, findExecutable, getCurrentDirectory)
import           System.Exit (ExitCode (..))
import           System.FilePath ((</>))
import           System.Process (createProcess, proc, waitForProcess)
import           Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

-- | Inputs to @canopy-native run@.
data RunOptions = RunOptions
  { roAppDir   :: !FilePath        -- ^ the app directory (native.config.json lives here)
  , roPort     :: !Int             -- ^ dev-server port (default 8099)
  , roLanHost  :: !(Maybe String)  -- ^ @--host IP@: a LAN box's IP (DEV-7); 'Nothing' ⇒ adb-reverse loopback
  , roNoServer :: !Bool            -- ^ @--no-server@: install+launch+wire only, don't start the server
  , roBuildCmd :: !String          -- ^ build program (default "canopy-native")
  } deriving (Eq, Show)

-- | Defaults for @canopy-native run APP@.
defaultRunOptions :: FilePath -> RunOptions
defaultRunOptions dir = RunOptions
  { roAppDir = dir, roPort = 8099, roLanHost = Nothing, roNoServer = False
  , roBuildCmd = "canopy-native" }

-- | Parse @run@/@dev@ args: a positional app dir (default ".") + @--port N@ / @--host IP@ /
-- @--no-server@. A bad @--port@ value or an unknown @--flag@ is a 'Left' usage error.
parseRunOptions :: [String] -> Either String RunOptions
parseRunOptions = go (defaultRunOptions ".") False
  where
    -- `sawDir` tracks whether the single positional app dir has been consumed yet.
    go :: RunOptions -> Bool -> [String] -> Either String RunOptions
    go acc _ [] = Right acc
    go acc sawDir (a : rest)
      | a == "--no-server" = go acc { roNoServer = True } sawDir rest
      | a == "--port" = case rest of
          (p : more) -> case readMaybe p of
            Just n | n > 0 && n <= 65535 -> go acc { roPort = n } sawDir more
            _                            -> Left ("run: invalid --port value: " <> p)
          [] -> Left "run: --port needs a value"
      | a == "--host" = case rest of
          (h : more) -> go acc { roLanHost = Just h } sawDir more
          []         -> Left "run: --host needs a value"
      | "--" `isPrefixOf` a = Left ("run: unknown flag: " <> a)
      | sawDir = Left ("run: unexpected extra argument: " <> a)
      | otherwise = go acc { roAppDir = a } True rest

-- ---------------------------------------------------------------------------
-- Dev-server host the client should dial (PURE)
-- ---------------------------------------------------------------------------

-- | Where the on-device client should connect, and whether the loop needs an @adb reverse@.
data DevHost = DevHost
  { dhHostPort   :: !String  -- ^ the @host:port@ baked into @debug.canopy.devhost@
  , dhAdbReverse :: !Bool    -- ^ True ⇒ run @adb reverse tcp:PORT tcp:PORT@ (loopback path)
  , dhServerBind :: !String  -- ^ the address the dev server binds (@127.0.0.1@ or @0.0.0.0@)
  } deriving (Eq, Show)

-- | Decide the client endpoint from the run options.
--
--   * No @--host@ (emulator/USB): the device reaches the host via @adb reverse@, so the client
--     dials the emulator host-loopback alias @10.0.2.2:PORT@ (which also works on a USB device once
--     the reverse tunnel maps 127.0.0.1); the server binds loopback.
--   * @--host IP@ (LAN, DEV-7): the client dials the box's @IP:PORT@ directly — no reverse tunnel —
--     and the server binds @0.0.0.0@ so the device can reach it over the network.
devClientHost :: RunOptions -> DevHost
devClientHost o = case roLanHost o of
  Nothing ->
    DevHost { dhHostPort = "10.0.2.2:" <> show (roPort o)
            , dhAdbReverse = True
            , dhServerBind = "127.0.0.1" }
  Just ip ->
    DevHost { dhHostPort = ip <> ":" <> show (roPort o)
            , dhAdbReverse = False
            , dhServerBind = "0.0.0.0" }

-- ---------------------------------------------------------------------------
-- The ordered command plan (PURE)
-- ---------------------------------------------------------------------------

-- | One step of the run plan: a program + its args (rendered/asserted by tests, executed by the
-- IO driver). Modeled as data so the whole orchestration is inspectable without running anything.
data Step = Step
  { stepProg :: !String
  , stepArgs :: ![String]
  , stepDesc :: !String   -- ^ a human label for the progress log
  } deriving (Eq, Show)

-- | The ordered steps of @canopy-native run@, given the options + the resolved 'DevHost' + the
-- gradlew path + the app's package/activity + the dev-server.js path. Pure: the IO driver just
-- executes these in order.
--
-- The server step is the LAST one (and omitted when @--no-server@) because it is long-running
-- (it blocks watching files); everything before it is one-shot setup.
runPlan :: RunOptions -> DevHost -> FilePath -> String -> String -> FilePath -> [Step]
runPlan o dh gradlew pkg activity devServerJs =
  concat
    [ [ Step (roBuildCmd o) ["build", roAppDir o] "build the JS bundle" ]
    , [ Step gradlew ["-p", androidProjectDir gradlew, "installDebug"] "install the debug APK" ]
    , [ Step "adb" ["reverse", tcp, tcp] "adb reverse (device 127.0.0.1 → host dev server)"
      | dhAdbReverse dh ]
    , [ Step "adb" ["shell", "setprop", "debug.canopy.devhost", dhHostPort dh]
          "point the dev client at the dev server" ]
    , [ Step "adb" ["shell", "am", "start", "-n", pkg <> "/" <> activity] "launch the app" ]
    , [ Step "node" devServerArgs "start the dev server (watch + rebuild + WS push)"
      | not (roNoServer o) ]
    ]
  where
    tcp = "tcp:" <> show (roPort o)
    devServerArgs =
      [ devServerJs, roAppDir o, "--port", show (roPort o) ]
      <> (if dhServerBind dh == "0.0.0.0" then ["--host", "0.0.0.0"] else [])

-- | The android project dir gradlew lives in (its parent), so @gradlew -p DIR installDebug@ targets
-- the right Gradle project regardless of where the tool is invoked from. Falls back to "." if the
-- path does not end in @/gradlew@.
androidProjectDir :: FilePath -> FilePath
androidProjectDir gw
  | sfx `isSuffixOf'` gw = take (length gw - length sfx) gw
  | otherwise            = "."
  where
    sfx = "/gradlew"
    isSuffixOf' s xs = reverse s `isPrefixOf` reverse xs

-- | Render a step as the shell line it stands for (for the progress log / tests).
renderStep :: Step -> String
renderStep (Step prog args desc) =
  "  - " <> desc <> "\n      $ " <> unwords (prog : map quoteArg args)
  where
    quoteArg a = if ' ' `elem` a then "'" <> a <> "'" else a

-- ---------------------------------------------------------------------------
-- IO driver
-- ---------------------------------------------------------------------------

-- | Execute @canopy-native run@: resolve the gradlew + dev-server.js, build the plan, and run each
-- step. The final (server) step inherits stdio and blocks (Ctrl-C stops the loop). Returns 'Left'
-- with a message if a prerequisite (gradlew / node / dev-server.js / adb) is missing.
executeRun :: RunOptions -> String -> String -> IO (Either String ())
executeRun o pkg activity = do
  gw <- resolveGradlew
  ds <- resolveDevServerJs
  case (gw, ds) of
    (Nothing, _) -> pure (Left "run: could not find host/android/gradlew (set CANOPY_HOST_ANDROID)")
    (_, Nothing) -> pure (Left "run: could not find tool/canopy-dev-server.js")
    (Just gradlew, Just devServerJs) -> do
      mNode <- findExecutable "node"
      mAdb  <- findExecutable "adb"
      case (mNode, mAdb) of
        (Nothing, _) -> pure (Left "run: node is required (install Node.js — see `canopy-native doctor`)")
        (_, Nothing) -> pure (Left "run: adb is required (Android platform-tools — see `canopy-native doctor`)")
        _ -> do
          let dh    = devClientHost o
              steps = runPlan o dh gradlew pkg activity devServerJs
          putStrLn ("canopy-native run — " <> roAppDir o <> "\n")
          mapM_ (putStrLn . renderStep) steps
          putStrLn ""
          runSteps steps
          pure (Right ())

-- | Run each step in order; a non-fatal failure (e.g. an @adb reverse@ already present) does not
-- abort the loop. The last step (the dev server) blocks until the developer stops it.
runSteps :: [Step] -> IO ()
runSteps = mapM_ runStep

runStep :: Step -> IO ()
runStep (Step prog args _) = do
  (_, _, _, ph) <- createProcess (proc prog args)
  ec <- waitForProcess ph
  case ec of
    ExitSuccess   -> pure ()
    ExitFailure _ -> pure ()  -- tolerate a non-fatal step; the loop continues

-- | Find @host/android/gradlew@: walk the conventional spots from cwd (repo root / android dir).
resolveGradlew :: IO (Maybe FilePath)
resolveGradlew = do
  cwd <- getCurrentDirectory
  firstExisting
    [ cwd </> "host" </> "android" </> "gradlew"
    , cwd </> "android" </> "gradlew"
    ]

-- | Find @tool/canopy-dev-server.js@ relative to the cwd (repo root or tool/).
resolveDevServerJs :: IO (Maybe FilePath)
resolveDevServerJs = do
  cwd <- getCurrentDirectory
  firstExisting
    [ cwd </> "tool" </> "canopy-dev-server.js"
    , cwd </> "canopy-dev-server.js"
    ]

firstExisting :: [FilePath] -> IO (Maybe FilePath)
firstExisting []       = pure Nothing
firstExisting (p : ps) = do
  e <- doesFileExist p
  if e then pure (Just p) else firstExisting ps
